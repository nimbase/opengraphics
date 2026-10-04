## The top-level file: parse order, and writing it back.
##
## Parse order matters, because a length prefix must be consumed at the point
## it appears and each section is scoped by its own length:
##   1. 26-byte header
##   2. color mode data        u32 length, raw bytes
##   3. image resources        u32 length, blocks to the end
##   4. layer and mask section length field (u32, or u64 in PSB)
##      4a. layer info length, then the layer info body
##      4b. global layer mask   u32 length, raw bytes
##      4c. global tagged blocks to the end of the section
##   5. merged image data      u16 compression, then to EOF
##
## Two structural details are load-bearing for round-trip:
##
## * 16- and 32-bit documents often carry their layer info in a `Lr16` or
##   `Lr32` global block instead of the section's own layer info field. When
##   the section is empty we lift that block into `layerInfo` and remember
##   where it came from, re-inserting it at the same index on write.
## * Bytes at the end of a region that do not form a block are recorded
##   verbatim instead of being discarded or guessed at.

import std/options
import std/sequtils

import ./compression
import ./error
import ./header
import ./patterns
import ./io
import ./layers
import ./resources
import ./tagged

type
  PlacementKind* {.pure.} = enum
    pkSection, pkGlobalBlock

  LayerInfoPlacement* = object
    ## Where the layer info actually lives, so writing puts it back where it
    ## was found.
    case kind*: PlacementKind
    of pkSection: discard
    of pkGlobalBlock:
      index*: int
      signature*: string
      key*: string
      padding*: Option[Span]

  GlobalLayerMask* = object
    ## Raw, with typed accessors. The full structure is 28+ bytes and only
    ## these few fields are interpreted.
    data*: Span

  MergedImage* = object
    compression*: Compression
    data*: Span   ## encoded bytes, verbatim, to end of file

  PsdFile* = object
    header*: Header
    colorModeData*: Span   ## palette for Indexed, duotone ink for Duotone
    resources*: seq[ImageResource]
    layerInfo*: Option[LayerInfo]
    layerInfoPlacement*: LayerInfoPlacement
    globalLayerMask*: Option[GlobalLayerMask]
    globalBlocks*: seq[TaggedBlock]
    layerMaskTrailing*: Span
    imageData*: MergedImage

proc width*(f: PsdFile): int {.inline.} = f.header.width

proc source*(f: PsdFile): Source {.inline.} =
  ## The buffer this file was parsed from: a string the caller shared, or a
  ## memory mapping. Every payload in the tree is a window into it, so holding
  ## on to this is what keeps the file's bytes alive and mapped.
  f.imageData.data.source
proc height*(f: PsdFile): int {.inline.} = f.header.height

proc layers*(f: PsdFile): seq[LayerRecord] {.inline.} =
  ## File order, bottom-most first. Empty when the file has no layers.
  if f.layerInfo.isSome: f.layerInfo.get().layers else: @[]

proc ensureLayerInfo*(f: var PsdFile) =
  ## Create an empty `LayerInfo` when absent, so callers can add layers
  ## without a separate "does it exist" check.
  if f.layerInfo.isNone:
    f.layerInfo = some(LayerInfo(mergedAlpha: false, layers: @[],
      padding: none(Span)))

proc addLayer*(f: var PsdFile, l: LayerRecord) =
  ensureLayerInfo(f)
  f.layerInfo.get().layers.add(l)

proc setLayers*(f: var PsdFile, layers: seq[LayerRecord]) =
  ensureLayerInfo(f)
  f.layerInfo.get().layers = layers

proc layerAt*(f: var PsdFile, i: int): var LayerRecord =
  ## Mutable access to one layer. Needed because a `PsdFile` is a value
  ## type: mutating through a by-value accessor would edit a copy and be
  ## silently lost. The layer list must already exist; call `ensureLayerInfo`
  ## first when building a file from scratch.
  f.layerInfo.get().layers[i]

proc overlayColorSpace*(m: GlobalLayerMask): Option[int] =
  if m.data.len < 2:
    return none(int)
  var r = initReader(m.data)
  some(int(r.readU16BE()))

proc colorComponents*(m: GlobalLayerMask): Option[array[4, int]] =
  if m.data.len < 10:
    return none(array[4, int])
  var r = initReader(m.data)
  r.skip(2)
  var comps: array[4, int]
  for i in 0 ..< 4:
    comps[i] = int(r.readU16BE())
  some(comps)

proc opacity*(m: GlobalLayerMask): Option[int] =
  ## 0..100, as Photoshop stores it.
  if m.data.len < 12:
    return none(int)
  var r = initReader(m.data)
  r.skip(10)
  some(int(r.readU16BE()))

proc kind*(m: GlobalLayerMask): Option[int] {.inline.} =
  ## 0 colour selected, 1 colour protected, 128 per layer.
  if m.data.len >= 13: some(int(m.data.byteAt(12))) else: none(int)

proc mergedLayout*(f: PsdFile): PlaneLayout {.inline.} =
  ## Geometry of the merged image planes.
  newPlaneLayout(f.header.channels, f.header.width, f.header.height,
    f.header.depth, f.header.version)

proc readPsd*(src: Source, limits = defaultLimits()): PsdFile =
  ## Parse a whole buffer. Raises `PsdError` on any structural problem;
  ## truncation is reported as `PsdErrorKind.UnexpectedEof`.
  ##
  ## The real entry point: `src` may be a memory-mapped file, and every payload
  ## the returned `PsdFile` holds is a window into it rather than a copy. A
  ## `Source` is immutable, so the result stays valid and safe to share across
  ## threads for as long as `src` is alive.
  var r = initReaderFrom(src)
  result.header = readHeader(r)
  limits.checkDimensions(result.header.width, result.header.height, "document")
  # Dimensions alone are not enough: 30000x30000 passes but 56 channels of it
  # is 50 GB of decoded samples, so the cap has to be channel-aware.
  limits.checkSamples(result.header.width, result.header.height,
    result.header.channels, "document")
  let psb = result.header.version.isPsb()

  # 2. color mode data: always a 32-bit length, even in PSB
  let cmdLen = r.lenField(false)
  limits.checkSection(cmdLen, "color mode data")
  result.colorModeData = r.bytes(int(cmdLen))

  # 3. image resources
  result.resources = readResourceSection(r, limits)

  # 4. layer and mask section
  if r.remaining() >= (if psb: 8 else: 4):
    let lmLen = r.lenField(psb)
    limits.checkSection(lmLen, "layer and mask section")
    if lmLen > r.remaining:
      eof(int(lmLen - r.remaining), r.pos)
    var sec = r.sub(lmLen)
    if sec.remaining() >= (if psb: 8 else: 4):
      let liLen = sec.lenField(psb)
      limits.checkSection(liLen, "layer info")
      if liLen > sec.remaining:
        eof(int(liLen - sec.remaining), sec.pos)
      if liLen > 0:
        var body = sec.sub(liLen)
        result.layerInfo = some(readLayerInfoBody(body, result.header.version,
          limits))
    if sec.remaining() >= 4:
      let gmLen = sec.lenField(false)
      limits.checkSection(gmLen, "global layer mask")
      if gmLen > sec.remaining:
        eof(int(gmLen - sec.remaining), sec.pos)
      let gm = sec.bytes(int(gmLen))
      if gmLen > 0:
        result.globalLayerMask = some(GlobalLayerMask(data: gm))
    if sec.remaining() > 0:
      let got = readBlocks(sec, result.header.version, limits)
      result.globalBlocks = got.blocks
      result.layerMaskTrailing = got.trailing

  # lift Lr16 / Lr32 / Layr out of the global blocks when the section had no
  # layer info of its own
  if result.layerInfo.isNone:
    for key in ["Lr16", "Lr32", "Layr"]:
      let i = findBlock(result.globalBlocks, key)
      if i >= 0:
        let b = result.globalBlocks[i]
        var body = initReader(b.data)
        try:
          let info = readLayerInfoBody(body, result.header.version, limits)
          result.layerInfo = some(info)
          result.globalBlocks.delete(i)
          result.layerInfoPlacement = LayerInfoPlacement(kind: pkGlobalBlock,
            index: i, signature: b.signature, key: b.key, padding: b.padding)
          break
        except PsdError:
          discard # not a layer info body after all; leave it as a block

  # 5. merged image data runs to end of file
  if r.remaining() < 2:
    eof(2 - r.remaining, r.pos)
  let compRaw = r.readU16BE()
  result.imageData.compression = compressionFromU16(compRaw)
  result.imageData.data = r.peekRest()
  # Validate here rather than at decode time so a truncated or corrupt
  # composite is reported where it lives. For ZIP this streams the stream
  # through a fixed scratch buffer rather than materialising the decoded
  # planes, so opening a large file stays O(1) in extra memory.
  if result.imageData.compression.kind != cUnknown:
    validatePlanes(result.imageData.compression, result.imageData.data,
      result.mergedLayout(), limits)

proc estimatedLayerInfoSize(f: PsdFile): int =
  ## Rough upper bound on the layer-and-mask section, used only as a capacity
  ## hint. Over-reserving costs nothing but address space; under-reserving just
  ## falls back to the geometric growth the writer already does.
  var n = 4096 + f.layerMaskTrailing.len + f.colorModeData.len
  for res in f.resources:
    n += res.name.len + 16
  if f.globalLayerMask.isSome:
    n += f.globalLayerMask.get().data.len + 4
  for b in f.globalBlocks:
    n += b.key.len + 12 + b.data.len
  if f.layerInfo.isSome:
    for l in f.layerInfo.get().layers:
      n += 400 + l.name.len + l.extraTrailing.len
      for c in l.channels:
        n += c.data.len + 8
  n

proc readPsd*(data: string, limits = defaultLimits()): PsdFile =
  ## `readPsd` over the caller's own buffer, which is shared rather than copied.
  readPsd(newStringSource(data), limits)

proc readPsdFile*(path: string, limits = defaultLimits()): PsdFile =
  ## Parse a PSD or PSB from disk, memory-mapped.
  ##
  ## Nothing of the file is read into the heap: the parse tree holds windows
  ## into the mapping, so opening a 500 MB file costs the tree alone. Falls
  ## back to a heap read if the file cannot be mapped.
  readPsd(mapSourceOrRead(path), limits)

proc writePsd*(f: PsdFile, limits = defaultLimits()): string =
  ## Inverse of `readPsd`. An unmodified file must come back byte for byte,
  ## with the two documented exceptions: Pascal-name pad bytes are written as
  ## zeros, and a layer-and-mask section holding only a zero layer-info
  ## length is normalised to an empty section.
  # Reserve for the bulk payloads up front. The composite alone is usually the
  # single largest thing written, and growing a buffer by doubling memcpies
  # everything already written each time it fills.
  let sectionHint = estimatedLayerInfoSize(f)
  var w = initWriter(f.imageData.data.len + sectionHint)
  w.writeHeader(f.header)
  # color mode data
  w.putU32(uint32(f.colorModeData.len))
  w.put(f.colorModeData)
  # image resources
  writeResourceSection(w, f.resources)

  let psb = f.header.version.isPsb()
  # layer info may live in the section or in a global block; find where
  var sectionBlocks = f.globalBlocks
  var inSection = true
  if f.layerInfoPlacement.kind == pkGlobalBlock:
    let p = f.layerInfoPlacement
    var inner = initWriter(sectionHint)
    if f.layerInfo.isSome:
      writeLayerInfoBody(inner, f.layerInfo.get(), f.header.version)
    let innerBytes = inner.toString()
    let blk = TaggedBlock(signature: p.signature, key: p.key,
      data: Span(src: newStringSource(innerBytes), start: 0,
        stop: innerBytes.len),
      padding: p.padding)
    sectionBlocks.insert(blk, p.index)
    inSection = false

  # The section is built separately so a wholly empty one can be written as a
  # zero length, which is the documented normalisation: a section holding only
  # a zero layer-info length comes back as an empty section. A section with
  # any content keeps both its layer-info and global-mask length fields, since
  # the parser always expects to find them.
  let hasContent = (inSection and f.layerInfo.isSome) or
    f.layerInfoPlacement.kind == pkGlobalBlock or
    f.globalLayerMask.isSome or sectionBlocks.len > 0 or
    f.layerMaskTrailing.len > 0
  if not hasContent:
    w.putLen(0, psb)
  else:
    var sec = initWriter(sectionHint)
    # The layer-info length field is always present in a non-empty section,
    # even when the body was lifted into a global block, in which case it is
    # zero.
    let liAt = sec.beginLen(psb)
    if inSection and f.layerInfo.isSome:
      writeLayerInfoBody(sec, f.layerInfo.get(), f.header.version)
    sec.endLen(liAt, psb)
    let gmAt = sec.beginLen(false)
    if f.globalLayerMask.isSome:
      sec.put(f.globalLayerMask.get().data)
    sec.endLen(gmAt, false)
    writeBlocks(sec, sectionBlocks, f.header.version)
    sec.put(f.layerMaskTrailing)
    w.putLen(int64(sec.len), psb)
    w.put(sec.toString())

  # merged image data
  w.putU16(f.imageData.compression.toU16)
  w.put(f.imageData.data)
  result = w.toString()

proc decodeMerged*(f: PsdFile): string =
  ## All merged planes, planar and big-endian, at the file's own bit depth.
  decodePlanes(f.imageData.compression, f.imageData.data, f.mergedLayout())

proc mergedHasAlpha*(f: PsdFile): bool {.inline.} =
  ## Whether the merged image carries an alpha channel: the header's channel
  ## count exceeds what the colour mode needs, or the layer info flagged it.
  let needed = f.header.colorMode.colorChannelCount()
  f.header.channels > needed or
    (f.layerInfo.isSome and f.layerInfo.get().mergedAlpha)

proc validate*(f: PsdFile) =
  ## Model-level checks that need more than the header.
  f.header.validate(f.colorModeData.len)
  if f.header.width <= 0 or f.header.height <= 0:
    invalid("image dimensions must be positive")

proc layerTree*(f: PsdFile): seq[LayerNode] =
  ## Nested groups, children bottom-to-top.
  buildLayerTree(f.layers)

proc iterLayers*(f: PsdFile): seq[LayerRecord] {.inline.} = f.layers()

proc resource*(f: PsdFile, id: int): Option[ImageResource] =
  getResource(f.resources, id)

proc globalBlock*(f: PsdFile, key: string): Option[TaggedBlock] =
  ## The first global tagged block with `key`. Note that a lifted `Lr16`
  ## block is no longer among them; see `layerInfoPlacement`.
  getBlock(f.globalBlocks, key)

proc iccProfile*(f: PsdFile): string {.inline.} = iccProfile(f.resources)

proc resolution*(f: PsdFile): Option[ResolutionInfo] {.inline.} =
  resolution(f.resources)

proc hasRealMergedData*(f: PsdFile): bool {.inline.} =
  hasRealMergedData(f.resources)

# --- phase 4 extended resources --------------------------------------------

proc globalPatterns*(f: PsdFile,
    limits = defaultLimits()): Option[seq[PsdPattern]] =
  ## The document's pattern block, resolved from its depth: `Patt` at 8 bits,
  ## `Pat2` at 16, `Pat3` at 32. `none` when the document carries none, or when
  ## the block does not parse.
  let b = globalBlock(f, patternBlockKey(uint16(f.header.depth)))
  if b.isNone:
    return none(seq[PsdPattern])
  try:
    some(parsePatternBlock(b.get().data, limits))
  except PsdError:
    none(seq[PsdPattern])
