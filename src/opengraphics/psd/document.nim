## High-level Document API.

import ./types
import ./reader
import ./header
import ./colormode
import ./resources
import ./layers
import ./imagedata
import ./pixels

export types
export pixels

type
  Document* = object
    header*: Header
    colorData*: ColorModeData
    resources*: ImageResources
    layerInfo*: LayerInfo
    composite*: ImageBuf
    hasComposite*: bool
    compositeCompression*: Compression

proc width*(d: Document): int {.inline.} = d.header.width
proc height*(d: Document): int {.inline.} = d.header.height
proc layerCount*(d: Document): int {.inline.} = d.layerInfo.layers.len

proc layers*(d: Document): seq[Layer] {.inline.} = d.layerInfo.layers

proc layerByName*(d: Document, name: string): int =
  for i, l in d.layerInfo.layers:
    if l.name == name or l.unicodeName == name:
      return i
  return -1

proc visibleLayers*(d: Document): seq[Layer] =
  result = @[]
  for l in d.layerInfo.layers:
    if l.isVisible() and l.kind == Pixel:
      result.add(l)

proc layerTree*(d: Document): seq[LayerNode] =
  ## Hierarchy of groups and layers in file order (bottom first).
  ## See buildLayerTree for divider semantics.
  buildLayerTree(d.layerInfo.layers)

proc readPsdBytes*(data: seq[byte], opts = ReadOptions(),
    limits = defaultLimits()): Document =
  var r = initReader(data)
  let hdr = parseHeader(r)
  limits.checkDimensions(hdr.width, hdr.height, "document")
  if hdr.depth != 8:
    raise newException(PsdError,
      "unsupported depth " & $hdr.depth & " (v1 supports 8-bit only)")
  if hdr.colorMode != Rgb and hdr.colorMode != Grayscale:
    raise newException(PsdError,
      "unsupported color mode " & $hdr.colorMode & " (v1 supports RGB and Grayscale)")
  let cdata = parseColorModeData(r)
  var res = parseResources(r)
  if opts.skipThumbnail:
    for b in res.blocks.mitems:
      if b.id == ThumbnailRgbId or b.id == ThumbnailBgrId:
        b.data = @[]
  let li = parseLayerInfo(r, opts.skipLayerImageData, limits)
  var comp = Raw
  var img = ImageBuf(width: 0, height: 0, data: @[])
  var hasComp = false
  if not opts.skipCompositeImageData:
    if not r.atEnd():
      limits.checkDimensions(hdr.width, hdr.height, "composite")
      let isRgb = hdr.colorMode == Rgb
      let decoded = decodeComposite(r, hdr.width, hdr.height, hdr.channels, isRgb)
      img = decoded.img
      comp = decoded.compression
      hasComp = true
  result = Document(header: hdr, colorData: cdata, resources: res,
    layerInfo: li, composite: img, hasComposite: hasComp,
    compositeCompression: comp)

proc readPsdBytes*(data: string, opts = ReadOptions(),
    limits = defaultLimits()): Document =
  var s = newSeq[byte](data.len)
  for i, c in data:
    s[i] = byte(c)
  readPsdBytes(s, opts, limits)

proc openPsd*(path: string, opts = ReadOptions(),
    limits = defaultLimits()): Document =
  let raw = readFile(path)
  readPsdBytes(raw, opts, limits)
