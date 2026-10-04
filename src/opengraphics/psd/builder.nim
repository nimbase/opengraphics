## Builds PSD and PSB files from pixel buffers.
##
## The builder never composites. Supply the flattened image with `composite`;
## otherwise a white placeholder is written and image resource 1057 records
## `hasRealMergedData = false` so a reader can tell.
##
## Layers are pushed bottom-to-top, and `beginGroup` / `endGroup` nest them.
## Both must be balanced by `build`, which raises otherwise.

import std/options
import std/strutils

import ./compression
import ./span
import ./error
import ./file
import ./header
import ./io
import ./layers
import ./pixeldata
import ./resources
import ./tagged

type
  MaskSpec* = object
    ## A layer mask given as 8-bit samples.
    rect*: Rect          ## in document coordinates
    data*: seq[uint8]    ## `rect.width * rect.height` samples, 0 hidden, 255 shown
    defaultColor*: uint8 ## value outside the rectangle
    disabled*: bool

  LayerSpec* = object
    ## A raster layer.
    name*: string
    left*, top*: int32
    width*, height*: uint32
    pixels*: PixelData    ## must match the document's colour mode and depth
    blendMode*: string    ## the 4-byte key, e.g. "norm" or "mul "
    opacity*: uint8       ## 0..255
    fillOpacity*: Option[uint8] ## written as `iOpa` when set
    visible*: bool
    clipping*: bool       ## clipped to the layer below
    mask*: Option[MaskSpec]
    extraBlocks*: seq[TaggedBlock] ## appended verbatim

  GroupSpec* = object
    ## A group (folder). The closing `lsct` record carries the blend mode, so a
    ## group's mode lives here rather than on a layer.
    name*: string
    blendMode*: string
    opacity*: uint8
    visible*: bool
    open*: bool           ## expanded in the layers panel

  BuilderEntryKind* {.pure.} = enum
    beLayer, beGroupStart, beGroupEnd

  BuilderEntry* = object
    ## One pushed item. `spec` is set for layers; `group` for group ends.
    case kind*: BuilderEntryKind
    of beLayer: layerSpec*: LayerSpec
    of beGroupStart: discard
    of beGroupEnd: group*: GroupSpec

  PsdBuilder* = object
    ## Builds `PsdFile`s. See the module docs for the compositing rule.
    width*, height*: uint32
    colorMode*: ColorMode
    depth*: int
    version*: Version
    compression*: Compression
    entries*: seq[BuilderEntry]
    openGroups*: seq[GroupSpec]   ## groups still awaiting `endGroup`
    composite*: Option[PixelData]
    resources*: seq[ImageResource]

const
  GroupName* = "</Layer group>"
    ## The fixed placeholder name Photoshop uses on a group's opening record.

proc newMaskSpec*(rect: Rect, data: seq[uint8], defaultColor = 0'u8,
    disabled = false): MaskSpec {.inline.} =
  MaskSpec(rect: rect, data: data, defaultColor: defaultColor,
    disabled: disabled)

proc newLayerSpec*(name: string, left, top: int32, width, height: uint32,
    pixels: PixelData): LayerSpec =
  ## A visible, normal-blend layer at full opacity.
  LayerSpec(name: name, left: left, top: top, width: width, height: height,
    pixels: pixels, blendMode: "norm", opacity: 255'u8, visible: true,
    clipping: false, mask: none(MaskSpec), extraBlocks: @[])

proc newGroupSpec*(name: string): GroupSpec =
  ## A visible, open, pass-through group.
  GroupSpec(name: name, blendMode: "pass", opacity: 255'u8, visible: true,
    open: true)

proc initPsdBuilder*(width, height: uint32): PsdBuilder {.inline.} =
  ## An 8-bit RGB PSD using RLE compression.
  PsdBuilder(width: width, height: height, colorMode: ColorMode(kind: cmRgb),
    depth: 8, version: Version.Psd, compression: Rle, entries: @[],
    openGroups: @[], composite: none(PixelData), resources: @[])

proc initPsbBuilder*(width, height: uint32): PsdBuilder =
  ## Like `initPsdBuilder` but in the large-document format.
  result = initPsdBuilder(width, height)
  result.version = Version.Psb

proc setColorMode*(b: var PsdBuilder, mode: ColorMode) {.inline.} =
  b.colorMode = mode

proc setDepth*(b: var PsdBuilder, depth: int) {.inline.} =
  b.depth = depth

proc setCompression*(b: var PsdBuilder, c: Compression) {.inline.} =
  b.compression = c

proc addResolution*(b: var PsdBuilder, dpi: float64) =
  ## Adds resource 1005 at `dpi`, all units per inch.
  var w = initWriter()
  writeResolution(w, resolutionFromDpi(dpi))
  b.resources.add(newImageResource(ResolutionInfoId, w.toString()))

proc addIccProfile*(b: var PsdBuilder, icc: string) =
  ## Adds resource 1039.
  b.resources.add(newImageResource(IccProfileId, icc))

proc addResource*(b: var PsdBuilder, res: ImageResource) {.inline.} =
  b.resources.add(res)

proc pushLayer*(b: var PsdBuilder, spec: LayerSpec) {.inline.} =
  ## Pushes a layer above the previous one.
  b.entries.add(BuilderEntry(kind: beLayer, layerSpec: spec))

proc beginGroup*(b: var PsdBuilder, spec: GroupSpec) {.inline.} =
  ## Opens a group; later layers land inside until `endGroup`.
  b.entries.add(BuilderEntry(kind: beGroupStart))
  b.openGroups.add(spec)

proc endGroup*(b: var PsdBuilder) =
  ## Closes the innermost open group. Raises when none is open.
  if b.openGroups.len == 0:
    invalid("endGroup without beginGroup")
  let g = b.openGroups[^1]
  b.openGroups.setLen(b.openGroups.len - 1)
  b.entries.add(BuilderEntry(kind: beGroupEnd, group: g))

proc setComposite*(b: var PsdBuilder, pixels: PixelData) {.inline.} =
  ## Supplies the flattened image, full canvas, same pixel format as layers.
  b.composite = some(pixels)

# --- assembly ---------------------------------------------------------------

proc channel*(b: PsdBuilder, id: int16, plane: string, w, h: int): ChannelData
    {.inline.} =
  encodeChannel(id, b.compression, plane, w, h, b.depth, b.version)

proc emptyChannels*(b: PsdBuilder, colorChannels: int): seq[ChannelData] =
  ## Channels for a group divider: alpha plus one per colour plane, each with
  ## a stored length of zero meaning "no data".
  let empty = Span(src: newStringSource(""), start: 0, stop: 0)
  result = @[ChannelData(id: ChannelTransparency, compression: none(Compression),
    data: empty)]
  for c in 0 ..< colorChannels:
    result.add(ChannelData(id: int16(c), compression: none(Compression),
      data: empty))

proc layerRecord*(b: PsdBuilder, spec: LayerSpec, colorChannels: int,
    id: uint32): LayerRecord =
  let (w, h) = (int(spec.width), int(spec.height))
  let n = w * h
  checkPixels(spec.pixels, w, h, b.colorMode, b.depth)
  result = LayerRecord(
    rect: Rect(top: spec.top, left: spec.left, bottom: spec.top + int32(h),
      right: spec.left + int32(w)),
    blendMode: spec.blendMode,
    opacity: int(spec.opacity),
    clipping: (if spec.clipping: 1 else: 0),
    flags: LayerFlags(hidden: not spec.visible),
    mask: MaskData(kind: mdNone),
    blendingRanges: fullBlendingRanges(colorChannels),
    name: encodeLegacyName(spec.name),
    blocks: @[unicodeNameBlock(spec.name), layerIdBlock(id)],
    extraTrailing: emptySpan())
  if spec.fillOpacity.isSome:
    result.blocks.add(fillOpacityBlock(spec.fillOpacity.get()))
  result.blocks.add(spec.extraBlocks)

  # Alpha first, then the colour planes in file order.
  result.channels = @[b.channel(ChannelTransparency, spec.pixels.plane(colorChannels, n), w, h)]
  for c in 0 ..< colorChannels:
    result.channels.add(b.channel(int16(c), spec.pixels.plane(c, n), w, h))

  if spec.mask.isSome:
    let m = spec.mask.get()
    let (mw, mh) = (m.rect.width(), m.rect.height())
    if m.data.len != mw * mh:
      invalid("mask holds " & $m.data.len & " samples, expected " &
        $(mw * mh) & " for " & $mw & "x" & $mh)
    # Masks are always 8-bit in the spec; at depth 16 scale 0..255 up to
    # 0..65535 so the stored sample matches the document.
    var plane = newString(mw * mh * (b.depth div 8))
    if b.depth == 16:
      for i, s in m.data:
        let v = uint16(s) * 257'u16
        plane[i * 2] = char(byte(v shr 8))
        plane[i * 2 + 1] = char(byte(v and 0xFF'u16))
    else:
      for i, s in m.data:
        plane[i] = char(s)
    result.channels.add(b.channel(ChannelUserMask, plane, mw, mh))
    # `newLayerMask` is the 20-byte form, which is what `parseLayerMask`
    # requires; a bare 18-byte record would come back as `mdRaw`.
    result.mask = MaskData(kind: mdMask, mask: newLayerMask(m.rect,
      m.defaultColor, MaskFlags(disabled: m.disabled)))

proc build*(b: PsdBuilder): PsdFile =
  ## Builds the file model. Raises on an unclosed group, an unsupported depth
  ## or colour mode, or a pixel buffer that does not match the document.
  if b.openGroups.len > 0:
    invalid($b.openGroups.len & " unclosed group(s)")
  if b.depth != 8 and b.depth != 16:
    unsupported("builder depth " & $b.depth)
  let colorChannels = colorChannels(b.colorMode)

  var layers: seq[LayerRecord] = @[]
  for i, e in b.entries:
    let id = uint32(i + 1)
    case e.kind
    of beLayer:
      layers.add(b.layerRecord(e.layerSpec, colorChannels, id))
    of beGroupStart:
      layers.add(LayerRecord(
        rect: Rect(), channels: b.emptyChannels(colorChannels),
        blendMode: "norm", opacity: 255, clipping: 0,
        flags: LayerFlags(), filler: 0'u8, mask: MaskData(kind: mdNone),
        blendingRanges: fullBlendingRanges(colorChannels),
        name: GroupName,
        blocks: @[unicodeNameBlock(GroupName), layerIdBlock(id),
          sectionDividerBlock(SectionType(kind: stBoundingDivider))],
        extraTrailing: emptySpan()))
    of beGroupEnd:
      let g = e.group
      let kind = if g.open: SectionType(kind: stOpenFolder)
                 else: SectionType(kind: stClosedFolder)
      layers.add(LayerRecord(
        rect: Rect(), channels: b.emptyChannels(colorChannels),
        blendMode: g.blendMode, opacity: int(g.opacity), clipping: 0,
        flags: LayerFlags(hidden: not g.visible), filler: 0'u8,
        mask: MaskData(kind: mdNone),
        blendingRanges: fullBlendingRanges(colorChannels), name: g.name,
        blocks: @[unicodeNameBlock(g.name), layerIdBlock(id),
          sectionDividerBlock(kind, g.blendMode)],
        extraTrailing: emptySpan()))

  # The merged image: the supplied composite, or a white placeholder.
  let (w, h) = (int(b.width), int(b.height))
  let n = w * h
  let bps = b.depth div 8
  var withAlpha = false
  var planes: seq[string] = @[]
  if b.composite.isSome:
    let p = b.composite.get()
    checkPixels(p, w, h, b.colorMode, b.depth)
    withAlpha = not p.alphaIsOpaque(n)
    for c in 0 ..< colorChannels + (if withAlpha: 1 else: 0):
      planes.add(p.plane(c, n))
  else:
    # White in RGB and grayscale; in CMYK, no ink, which is stored inverted
    # as 0xff.
    planes = newSeq[string](colorChannels)
    for c in 0 ..< colorChannels:
      planes[c] = repeat(char(0xFF'u8), n * bps)

  let header = Header(version: b.version, channels: colorChannels +
      (if withAlpha: 1 else: 0), height: h, width: w, depth: b.depth,
      colorMode: b.colorMode)
  header.validate()
  let layout = newPlaneLayout(header.channels, w, h, b.depth, b.version)
  var decoded = newStringOfCap(n * bps * header.channels)
  for p in planes:
    decoded.add(p)
  let imageData = MergedImage(compression: b.compression,
    data: spanOf(encodePlanes(b.compression, decoded, layout)))

  var resources = b.resources
  resources.add(versionInfoResource(b.composite.isSome))

  let hasLayers = layers.len > 0
  result = PsdFile(
    header: header,
    colorModeData: emptySpan(),
    resources: resources,
    layerInfoPlacement: (if hasLayers and b.depth == 16:
      # 16-bit documents normally keep their layer info in an `Lr16` global
      # block rather than in the section.
      LayerInfoPlacement(kind: pkGlobalBlock, index: 0, signature: "8BIM",
        key: "Lr16", padding: none(Span))
      else: LayerInfoPlacement(kind: pkSection)),
    globalBlocks: @[],
    layerMaskTrailing: emptySpan(),
    imageData: imageData)
  if hasLayers:
    result.layerInfo = some(LayerInfo(mergedAlpha: withAlpha, layers: layers,
      padding: none(Span)))
    # 20 bytes of zeros is the global layer mask block Photoshop writes: a
    # length of 0 for both the overlay colour space and the sections.
    result.globalLayerMask = some(GlobalLayerMask(data: spanOf(newString(20))))

proc toBytes*(b: PsdBuilder): string =
  ## Builds and serializes.
  writePsd(b.build())