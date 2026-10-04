## Compatibility layer: the older, higher-level PSD API on top of the core
## reader.
##
## The core (`PsdFile` and friends) is byte-exact and lossless. This module
## keeps the surface existing callers depend on — `Document`, `readPsdBytes`,
## `openPsd`, `layerTree`, `layerText`, `placedLayer`, `vectorMask`,
## `fillContent` — and adds the conveniences that need decoded pixels, such as
## `compositeImage` and `layerImage`.
##
## Two things here are deliberately not lossless and cannot be:
##
## - `Document.layers` flattens every channel to 8 bits via `planeToU8`, so
##   16- and 32-bit documents lose precision. Compositing is an 8-bit
##   operation; see the plan.
## - `Document` exposes the composite eagerly as an `ImageBuf`, which means a
##   full-canvas allocation per document. Use `PsdFile` directly for large
##   files.

import std/options
import std/sequtils

import ./compression
import ./error
import ./file
import ./header
import ./io
import ./layers
import ./pixels
import ./span
import ./resources
import ./samples
import ./semantic

export error
export header
export layers
export pixels
export resources
export semantic

type
  ReadOptions* = object
    ## Toggles to skip expensive or unneeded sections. `skipThumbnail` clears
    ## the embedded preview payload at read time rather than after parsing.
    skipThumbnail*: bool
    skipCompositeImageData*: bool

  Document* = object
    ## The whole file, eagerly decoded. `file` is the lossless model; the
    ## other fields are views built from it.
    file*: PsdFile
    ## The stored flattened image, empty when skipped or absent.
    composite*: ImageBuf
    hasComposite*: bool

  LayerImage* = object
    ## A layer's pixels, flattened to 8-bit straight-alpha RGBA over the
    ## layer's own rect.
    img*: ImageBuf
    rect*: Rect

proc width*(d: Document): int {.inline.} = d.file.width

proc height*(d: Document): int {.inline.} = d.file.height

proc layerCount*(d: Document): int {.inline.} = d.file.layers().len

proc layers*(d: Document): seq[LayerRecord] {.inline.} = d.file.layers()

proc layerByName*(d: Document, name: string): int =
  ## Index of the first layer whose display or legacy name is `name`, or -1.
  for i, l in d.file.layers():
    if l.name() == name or l.name == name:
      return i
  -1

proc visibleLayers*(d: Document): seq[LayerRecord] =
  ## Visible layers that are not group markers.
  for l in d.file.layers():
    if l.isVisible() and not l.isFolder() and not l.isDivider():
      result.add(l)

proc layerTree*(d: Document): seq[LayerNode] {.inline.} =
  ## Nested groups and layers, bottom first.
  d.file.layerTree()

# --- decoded pixels ---------------------------------------------------------

proc rowBytesForPlane*(width, height, depth: int): int {.inline.} =
  ## Bytes one decoded plane occupies. At depth 8 that is one byte per pixel,
  ## which is what `planeToU8` always produces.
  width * height

proc colorChannelCount*(f: PsdFile): int =
  let n = f.header.colorMode.colorChannelCount()
  if n <= 0:
    invalid("colour mode " & $f.header.colorMode.kind & " has no colour planes")
  n

proc planesToImage*(planes: seq[string], width, height, depth: int,
    colorCount: int): ImageBuf =
  ## Assemble planes into RGBA. Alpha comes from the plane after the colour
  ## planes when one is present, and defaults to opaque otherwise. Grayscale
  ## and CMYK are mapped the way Photoshop previews them.
  result = initImageBuf(width, height, Rgba(r: 0, g: 0, b: 0, a: 0))
  if width <= 0 or height <= 0 or colorCount <= 0:
    return
  # A header can promise more colour planes than the payload delivers, e.g. an
  # RGB file with a one-channel merged image. Raise rather than index past the
  # end, so an odd file is reported instead of crashing.
  if planes.len < colorCount:
    invalid("image needs " & $colorCount & " colour planes but only " &
      $planes.len & " were decoded")
  let n = width * height
  var u8: seq[string] = @[]
  for i in 0 ..< min(colorCount + 1, planes.len):
    u8.add(planeToU8(planes[i], depth, width, height))
  let hasAlpha = u8.len > colorCount
  for i in 0 ..< n:
    var r = 0
    var g = 0
    var b = 0
    if colorCount == 1:
      r = ord(u8[0][i])
      g = r
      b = r
    elif colorCount == 4:
      # CMYK stored inverted; the preview is the naive subtractive mix.
      let c = 255 - ord(u8[0][i])
      let m = 255 - ord(u8[1][i])
      let y = 255 - ord(u8[2][i])
      let k = 255 - ord(u8[3][i])
      r = 255 - min(255, c + k)
      g = 255 - min(255, m + k)
      b = 255 - min(255, y + k)
    else:
      r = ord(u8[0][i])
      g = ord(u8[1][i])
      b = ord(u8[2][i])
    let a = if hasAlpha: ord(u8[colorCount][i]) else: 255
    result.data[i] = Rgba(r: uint8(r), g: uint8(g), b: uint8(b), a: uint8(a))

proc compositeImage*(d: Document): ImageBuf =
  ## The stored flattened image. Empty when the file has none or when
  ## `skipCompositeImageData` was set.
  if d.hasComposite:
    return d.composite

proc decodeCompositeImage*(f: PsdFile): ImageBuf =
  ## Decode the merged image into an `ImageBuf`.
  let (w, h) = (f.width, f.height)
  let cc = colorChannelCount(f)
  let layout = f.mergedLayout()
  let all = decodePlanes(f.imageData.compression, f.imageData.data, layout)
  let planeLen = rowBytesForPlane(w, h, f.header.depth)
  var planes: seq[string] = @[]
  for i in 0 ..< f.header.channels:
    planes.add(all[i * planeLen ..< (i + 1) * planeLen])
  planesToImage(planes, w, h, f.header.depth, cc)

proc layerPlane*(d: Document, index: int, channelId: int16): string =
  ## One channel of one layer as 8-bit samples over the channel's own rect.
  ## Empty when the layer does not carry it or it could not be decoded.
  let layers = d.file.layers()
  if index < 0 or index >= layers.len:
    return ""
  let l = layers[index]
  let idx = l.channelIndex(channelId)
  if idx < 0:
    return ""
  let r = l.channelRect(channelId)
  let (w, h) = (r.width(), r.height())
  if w <= 0 or h <= 0:
    return ""
  try:
    planeToU8(l.channels[idx].decode(w, h, d.file.header.depth,
      d.file.header.version), d.file.header.depth, w, h)
  except PsdError:
    ""

proc layerImage*(d: Document, index: int): LayerImage =
  ## One layer's pixels, 8-bit straight alpha, over its own rect. Channels the
  ## layer does not carry read as zero (transparent).
  let layers = d.file.layers()
  if index < 0 or index >= layers.len:
    invalid("layer index " & $index & " out of range 0.." & $(layers.len - 1))
  let l = layers[index]
  let r = l.rect
  result.rect = r
  let (w, h) = (r.width(), r.height())
  if w <= 0 or h <= 0:
    result.img = initImageBuf(max(w, 0), max(h, 0))
    return
  let n = w * h
  let cc = colorChannelCount(d.file)
  # Colour planes, then alpha only when the layer actually carries one. A layer
  # with no -1 channel is fully opaque, not fully transparent.
  var planes: seq[string] = @[]
  for c in 0 ..< cc:
    planes.add(d.layerPlane(index, int16(c)))
  if l.channelIndex(ChannelTransparency) >= 0:
    planes.add(d.layerPlane(index, ChannelTransparency))
  result.img = planesToImage(planes, w, h, d.file.header.depth, cc)

proc layerImage*(l: LayerRecord, f: PsdFile): LayerImage =
  ## Same as the `Document` overload, but for a record already in hand.
  var d = Document(file: f)
  let idx = f.layers().findIt(it.rect == l.rect and it.name == l.name)
  if idx < 0:
    invalid("layer is not part of this file")
  d.layerImage(idx)

# --- reading ----------------------------------------------------------------

proc readPsdDocument*(src: Source, opts = ReadOptions(),
    limits = defaultLimits()): Document =
  var f = readPsd(src, limits)
  if opts.skipThumbnail:
    for res in f.resources.mitems:
      if res.id == ThumbnailId or res.id == ThumbnailPs4Id:
        res.data = emptySpan()
  result.file = f
  if not opts.skipCompositeImageData:
    try:
      result.composite = decodeCompositeImage(f)
      result.hasComposite = not result.composite.isEmpty()
    except PsdError:
      # A file with no usable merged image is still readable; the layer stack
      # is the source of truth.
      result.composite = ImageBuf()
      result.hasComposite = false

proc readPsdBytes*(data: string, opts = ReadOptions(),
    limits = defaultLimits()): Document {.inline.} =
  readPsdDocument(newStringSource(data), opts, limits)

proc readPsdBytes*(src: Source, opts = ReadOptions(),
    limits = defaultLimits()): Document {.inline.} =
  readPsdDocument(src, opts, limits)

proc readPsdBytes*(data: seq[byte], opts = ReadOptions(),
    limits = defaultLimits()): Document =
  if data.len == 0:
    return readPsdDocument(newStringSource(""), opts, limits)
  readPsdDocument(newBytesSource(data), opts, limits)

proc openPsd*(path: string, opts = ReadOptions(),
    limits = defaultLimits()): Document =
  ## Read a PSD or PSB file from disk, memory-mapped.
  ##
  ## The mapping is owned by the `Source` the document holds, so it stays valid
  ## until the last reference to it goes away -- including after this call
  ## returns, which is why the `Document` keeps the `PsdFile` rather than a copy
  ## of its parts. Use `openPsdRead` when concurrent truncation is a concern.
  readPsdDocument(mapSourceOrRead(path), opts, limits)

proc openPsdRead*(path: string, opts = ReadOptions(),
    limits = defaultLimits()): Document =
  ## `openPsd` with the file slurped into memory instead of mapped.
  ##
  ## Slower and heavier, but immune to the one failure mode mapping has: a file
  ## truncated by another process while mapped raises SIGBUS on access, which
  ## no exception handler can catch.
  readPsdDocument(newStringSource(readFile(path)), opts, limits)

# --- thumbnails -------------------------------------------------------------

type
  Thumbnail* = object
    ## The embedded preview: a 28-byte header plus a JFIF payload. The JPEG is
    ## not decoded, so `jpeg` can be written straight to a `.jpg` file.
    format*: uint32   ## 1 = kJpegRGB
    width*, height*: int
    bitsPerPixel*: uint16
    planes*: uint16
    jpeg*: string

proc parseThumbnail*(data: Span): Thumbnail =
  ## Parse resource 1036 (or 1033). Raises `PsdError` on a short or
  ## implausible payload.
  if data.len < 28:
    invalid("short thumbnail resource (" & $data.len & " bytes)")
  var r = initReader(data)
  result.format = r.readU32BE()
  result.width = int(r.readU32BE())
  result.height = int(r.readU32BE())
  discard r.readU32BE() # widthBytes, the padded row size
  discard r.readU32BE() # totalSize, uncompressed
  let compSize = int(r.readU32BE())
  result.bitsPerPixel = r.readU16BE()
  result.planes = r.readU16BE()
  result.jpeg = r.peekRest().clone
  if result.jpeg.len != compSize:
    invalid("thumbnail payload is " & $result.jpeg.len & " bytes, header says " &
      $compSize)
  if result.width <= 0 or result.height <= 0 or result.width > 4096 or
      result.height > 4096:
    invalid("implausible thumbnail dimensions " & $result.width & "x" &
      $result.height)

proc thumbnailOf*(d: Document): Option[Thumbnail] =
  ## The document's preview, preferring 1036 over 1033. `none` when absent or
  ## when `skipThumbnail` cleared it.
  for id in [ThumbnailId, ThumbnailPs4Id]:
    let res = getResource(d.file.resources, id)
    if res.isSome and res.get().data.len > 0:
      try:
        return some(parseThumbnail(res.get().data))
      except PsdError:
        return none(Thumbnail)
  none(Thumbnail)

proc hasThumbnail*(d: Document): bool {.inline.} =
  d.thumbnailOf().isSome

proc iccProfile*(d: Document): string {.inline.} =
  ## Raw ICC bytes, or "" when absent.
  iccProfile(d.file.resources)

proc hasIccProfile*(d: Document): bool {.inline.} =
  findResource(d.file.resources, IccProfileId) >= 0 or
    findResource(d.file.resources, IccUntaggedId) >= 0

proc saveThumbnailJpeg*(t: Thumbnail, path: string) =
  ## Write the embedded JFIF payload verbatim. Opens in any image viewer.
  if t.jpeg.len == 0:
    invalid("cannot write thumbnail: empty JPEG payload")
  var f = open(path, fmWrite)
  defer: f.close()
  f.write(t.jpeg)

proc saveThumbnailJpeg*(d: Document, path: string) =
  ## Write the document's own preview to `path`.
  let t = d.thumbnailOf()
  if t.isNone:
    invalid("cannot write thumbnail: file has none")
  saveThumbnailJpeg(t.get(), path)

proc parseThumbnail*(data: string): Thumbnail =
  parseThumbnail(toSpan(data))
