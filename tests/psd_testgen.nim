## Deterministic synthetic PSD/PSB generator for tests (stdlib only).
##
## Works at the model level rather than through `PsdBuilder`, because the
## builder is deliberately narrow: it takes interleaved RGBA / GrayA / CMYKA
## buffers at 8 or 16 bits. The corpus has to reach the colour modes and bit
## depths the *parser* accepts but the builder will not produce -- Bitmap,
## Indexed, Lab, Multichannel, Duotone, and 1 / 32 bits -- because those are
## exactly the paths that most need coverage.
##
## Every generator is a pure function of its arguments, so a failing case can
## be reproduced by calling the same proc with the same inputs.

import std/options
import std/strutils
import ../src/opengraphics/psd

type
  TestCase* = object
    ## One generated file: a name for the test output and the model itself.
    name*: string
    file*: PsdFile

type
  LayeredCase* = object
    ## A layered corpus file plus what it was built from, so a test can verify
    ## the decoded planes without re-deriving the generator's internal counter.
    file*: PsdFile
    alphaSeeds*: seq[uint32]  ## per raster layer, file order
    colorSeeds*: seq[seq[uint32]] ## per raster layer, per colour plane

const
  MergedSeedBase* = 50'u32
    ## Plane seeds for a merged image start here, well clear of the per-layer
    ## seeds so the two ranges cannot collide and hide a mistake.

  AllModes* = [
    ColorMode(kind: cmBitmap),
    ColorMode(kind: cmGrayscale),
    ColorMode(kind: cmIndexed),
    ColorMode(kind: cmRgb),
    ColorMode(kind: cmCmyk),
    ColorMode(kind: cmLab),
    ColorMode(kind: cmMultichannel),
    ColorMode(kind: cmDuotone)]
    ## Every colour mode the corpus covers.

  AllCompressions* = [Raw, Rle, Zip, ZipPrediction]
    ## Every compression the writer and parser support.

  AllVersions* = [Version.Psd, Version.Psb]
    ## Both container formats.

proc rectOf*(x, y, w, h: int32): Rect {.inline.} =
  ## A rect from an origin and a size. `bottom`/`right` are exclusive, which is
  ## what makes a negative offset expressible: origin (-5,-3), size 10x7.
  Rect(top: y, left: x, bottom: y + h, right: x + w)

proc resolutionResource*(dpi: float64): ImageResource =
  ## Resource 1005, serialized through the same writer the file writer uses.
  var w = initWriter()
  writeResolution(w, resolutionFromDpi(dpi))
  newImageResource(ResolutionInfoId, w.toString())

proc modeChannels*(m: ColorMode): int {.inline.} =
  ## Colour planes a generated file stores. Multichannel has no defined
  ## mapping, so the corpus pins it to two named spots rather than deriving
  ## zero, which would make for a file with no planes at all.
  if m.kind == cmMultichannel: 2 else: m.colorChannelCount()

proc modeDepths*(m: ColorMode): seq[int] =
  ## The bit depths that are meaningful for a mode, mirroring the reference
  ## corpus: Bitmap is 1-bit by definition, Indexed and Duotone are 8, and
  ## everything else spans the depths Photoshop writes.
  case m.kind
  of cmBitmap: @[1]
  of cmIndexed, cmDuotone: @[8]
  of cmMultichannel, cmCmyk, cmLab: @[8, 16]
  else: @[8, 16, 32]

proc colorModeData*(m: ColorMode): string =
  ## Colour mode data: the 768-byte palette Indexed requires, arbitrary
  ## preserved bytes for Duotone's undocumented ink, nothing otherwise.
  case m.kind
  of cmIndexed:
    result = newString(768)
    for i in 0 ..< 768:
      result[i] = char((i * 7) and 0xFF)
  of cmDuotone:
    result = newString(24)
    for i in 0 ..< 24:
      result[i] = char(i)
  else:
    result = ""

proc patternPlane*(w, h, depth: int, seed: uint32): string =
  ## Deterministic planar samples for one `w x h` plane at `depth`.
  ##
  ## Shaped so RLE sees both of its cases: 8-bit mixes flat runs with
  ## gradients. At depth 1 the row is `ceil(w/8)` bytes, not `w` bytes, so the
  ## length is derived from `rowBytes` rather than from the pixel count.
  let s = int(seed)
  result = newStringOfCap(rowBytes(w, depth) * h)
  for y in 0 ..< h:
    case depth
    of 1:
      for bx in 0 ..< rowBytes(w, 1):
        result.add(char(((bx * 37 + y * 11 + s) and 0xFF) xor 0x5A))
    of 8:
      for x in 0 ..< w:
        let v = if (x div 4 + y) mod 3 == 0: (s * 17) and 0xFF
                else: (x * 3 + y * 7 + s) and 0xFF
        result.add(char(v and 0xFF))
    of 16:
      for x in 0 ..< w:
        let v = (x * 997 + y * 131 + s * 7919) and 0xFFFF
        result.add(char((v shr 8) and 0xFF))
        result.add(char(v and 0xFF))
    of 32:
      for x in 0 ..< w:
        let bits = cast[uint32](float32(((x + y + s) mod 17)) / 16.0'f32)
        for shift in [24'u32, 16, 8, 0]:
          result.add(char((bits shr shift) and 0xFF))
    else:
      raise newException(ValueError, "no pattern for depth " & $depth)

proc encodePlanesFor*(comp: Compression, planes: seq[string], w, h, depth: int,
    version: Version): string =
  ## `comp` plus the compressed form of `planes` concatenated, which is the
  ## merged-image section's on-disk shape.
  var flat = newStringOfCap(planes.len * rowBytes(w, depth) * h)
  for p in planes:
    flat.add(p)
  result = encodePlanes(comp, flat,
    newPlaneLayout(planes.len, w, h, depth, version))

proc baseResources*(): seq[ImageResource] =
  ## A resource block covering the typed accessors: resolution, the two
  ## globals, an ICC profile, XMP, a *named* resource (which carries a Pascal
  ## name as well as an id), and the version-info flag that marks a composite
  ## as real rather than absent.
  var named = newImageResource(2000, "\x01\x02\x03")
  named.name = "Path 1"
  result = @[
    resolutionResource(72.0),
    newImageResource(GlobalAngleId, "\x00\x00\x00\x1E"),
    newImageResource(GlobalAltitudeId, "\x00\x00\x00\x1E"),
    newImageResource(IccProfileId, repeat('B', 13)),
    newImageResource(XmpId, "<x:xmpmeta xmlns:x='adobe:ns:meta/'/>"),
    named,
    versionInfoResource(true)]


proc mergedOnly*(version: Version, mode: ColorMode, depth: int,
    comp: Compression, w, h: int): PsdFile =
  ## A flattened file: no layer section, just a patterned composite.
  let channels = modeChannels(mode)
  var planes: seq[string] = @[]
  for c in 0 ..< channels:
    planes.add(patternPlane(w, h, depth, MergedSeedBase + uint32(c)))
  result = PsdFile(
    header: Header(version: version, channels: channels, height: h, width: w,
      depth: depth, colorMode: mode),
    colorModeData: spanOf(colorModeData(mode)),
    resources: baseResources(),
    layerInfo: none(LayerInfo),
    layerInfoPlacement: LayerInfoPlacement(kind: pkSection),
    globalLayerMask: none(GlobalLayerMask),
    globalBlocks: @[],
    layerMaskTrailing: emptySpan(),
    imageData: MergedImage(compression: comp,
      data: spanOf(encodePlanesFor(comp, planes, w, h, depth, version))))

type
  PlanItemKind* = enum
    ## A plan entry is either a raster layer or a group divider. Group records
    ## carry no pixels, which is why they are a separate kind rather than an
    ## empty `LayerSpecIn`.
    pikRaster, pikGroup

  PlanItem* = object
    ## One entry in the corpus plan: a raster layer's spec, or a divider's
    ## section type and the group's own name, blend mode and id.
    kind*: PlanItemKind
    spec*: LayerSpecIn
    section*: SectionType
    groupName*: string
    groupBlend*: string
    groupId*: uint32

  LayerSpecIn* = object
    ## One raster layer the corpus wants. Collected as data first and turned
    ## into a record afterwards: a nested proc closing over the accumulator
    ## trips a Nim 2.2 codegen bug, and a declarative list also makes the
    ## corpus readable as a specification of what it covers.
    rect*: Rect
    name*: string
    blend*: string
    mask*: Option[LayerMask]
    realMask*: Option[RealMask]

proc seededChannel*(id: int16, comp: Compression, depth: int,
    version: Version, w, h: int, seed: uint32): ChannelData =
  ## One encoded channel plane. Zero geometry gives an empty plane, which is
  ## what a channel on a zero-size layer holds.
  if w <= 0 or h <= 0:
    return encodeChannel(id, comp, "", 0, 0, depth, version)
  encodeChannel(id, comp, patternPlane(w, h, depth, seed), w, h, depth, version)

proc extraBlocks*(seed: uint32): seq[TaggedBlock] =
  ## Tagged blocks the parser must preserve but not interpret, including two
  ## that exercise the padding logic: an odd-length payload needing one pad
  ## byte, and an empty payload with an explicit empty padding run.
  result = @[
    newTaggedBlock("clyr", "\x01"),
    newTaggedBlock("clbl", "\x00"),
    newTaggedBlock("fxrp", repeat('\x00', 16)),
    newTaggedBlock("zOdd", "\x01\x02\x03"),
    newTaggedBlock("zNop", "\x09")]
  result[0].padding = some(spanOf("\x00\x00\x00"))
  result[4].padding = some(spanOf(""))


proc rasterLayer*(sp: LayerSpecIn, seed: uint32, colorChannels: int,
    comp: Compression, depth: int, version: Version): LayerRecord =
  ## Turn one collected spec into a record, encoding every channel from `seed`.
  # A zero-size rect is legal on disk -- Photoshop writes one for an empty
  # layer -- but `size()` raises on it by design, since its job is to stop a
  # bogus rect driving an allocation. The geometry is derived without it.
  let lw = max(int(sp.rect.right - sp.rect.left), 0)
  let lh = max(int(sp.rect.bottom - sp.rect.top), 0)
  result = LayerRecord(
    rect: sp.rect,
    blendMode: sp.blend,
    opacity: int(255 - (seed * 13) mod 128),
    clipping: (if seed mod 7 == 3: 1 else: 0),
    # Every fifth layer is hidden, so the corpus always carries a mix.
    flags: newLayerFlags(if seed mod 5 == 4: 2'u8 else: 0'u8),
    filler: 0'u8,
    mask: (if sp.mask.isSome: MaskData(kind: mdMask, mask: sp.mask.get())
           else: MaskData(kind: mdNone)),
    blendingRanges: fullBlendingRanges(colorChannels),
    name: encodeLegacyName(sp.name),
    blocks: @[unicodeNameBlock(sp.name), layerIdBlock(seed + 1)],
    extraTrailing: emptySpan())
  # Alpha first, then the colour planes in file order. Group dividers are the
  # one record type with no pixels.
  if lw > 0 and lh > 0:
    result.channels = @[seededChannel(ChannelTransparency, comp, depth, version,
      lw, lh, seed)]
    for c in 0 ..< colorChannels:
      result.channels.add(seededChannel(int16(c), comp, depth, version, lw, lh,
        seed + uint32(c) + 1))
  if sp.mask.isSome:
    let mw = max(int(sp.mask.get().rect.right - sp.mask.get().rect.left), 0)
    let mh = max(int(sp.mask.get().rect.bottom - sp.mask.get().rect.top), 0)
    result.channels.add(seededChannel(ChannelUserMask, comp, depth, version,
      mw, mh, seed + 99))
    if sp.realMask.isSome:
      let rw = max(int(sp.realMask.get().rect.right - sp.realMask.get().rect.left), 0)
      let rh = max(int(sp.realMask.get().rect.bottom - sp.realMask.get().rect.top), 0)
      result.channels.add(seededChannel(ChannelRealUserMask, comp, depth,
        version, rw, rh, seed + 7))
  if seed mod 3 == 0:
    result.blocks.add(extraBlocks(seed))

proc groupRecord*(mode: ColorMode, name: string, kind: SectionType,
    blend: string, id: uint32): LayerRecord =
  ## A group divider. `kind` is `stBoundingDivider` for the record *below* a
  ## group's children, and an open or closed folder for the record *above*
  ## them. Only the folder record carries the group's blend mode, which is
  ## what `layerTree` and the renderer read.
  let cc = modeChannels(mode)
  result = LayerRecord(
    rect: Rect(), channels: @[], blendMode: blend, opacity: 255, clipping: 0,
    flags: newLayerFlags(0), filler: 0'u8, mask: MaskData(kind: mdNone),
    blendingRanges: fullBlendingRanges(cc),
    name: encodeLegacyName(name),
    blocks: @[unicodeNameBlock(name), layerIdBlock(id)],
    extraTrailing: emptySpan())
  if kind.kind == stBoundingDivider:
    result.blendMode = "norm"
    result.blocks.add(sectionDividerBlock(kind))
  else:
    result.blocks.add(sectionDividerBlock(kind, blend))
  # Divider records declare one channel per colour plane plus alpha, each with
  # a stored length of zero: a divider has no pixels.
  result.channels = @[ChannelData(id: ChannelTransparency,
    compression: none(Compression), data: emptySpan())]
  for c in 0 ..< cc:
    result.channels.add(ChannelData(id: int16(c), compression: none(Compression),
      data: emptySpan()))


proc layeredSeeded*(version: Version, mode: ColorMode, depth: int,
    comp: Compression): LayeredCase =
  ## A layered file exercising masks, nested groups, every blend mode,
  ## Unicode names, an empty layer, negative offsets and bounds past the
  ## canvas.
  let (w, h) = (24, 16)
  let colorChannels = modeChannels(mode)
  let channels = colorChannels + 1 # plus a merged alpha

  let params = MaskParameters(flags: 3'u8, userDensity: some(200'u8),
    userFeather: some(1.5), vectorDensity: none(uint8),
    vectorFeather: none(float64))
  let innerMask = LayerMask(rect: rectOf(1, 1, 5, 4), defaultColor: 255'u8,
    flags: newMaskFlags(16'u8), parameters: some(params),
    real: some(RealMask(flags: 0'u8, background: 255'u8,
      rect: rectOf(0, 0, 3, 3))), trailing: spanOf(""))

  # Every blend key the parser may meet, plus one it cannot interpret, which
  # must be preserved verbatim rather than mapped to a default.
  let blendKeys = [
    "norm", "dark", "mul ", "idiv", "brn ", "lin ", "lite", "scrn", "ovrl",
    "sLit", "vLit", "hLit", "dCol", "lddg", "hsl ", "diff", "smud", "div ",
    "dCol", "idiv", "lght", "dark", "smud", "pass", "diss", "hue ", "sat ",
    "colr", "lum ", "zzzz"]

  var plan: seq[PlanItem] = @[]
  proc raster(rect: Rect, name: string, blend: string,
      mask: Option[LayerMask] = none(LayerMask),
      realMask: Option[RealMask] = none(RealMask)) =
    plan.add(PlanItem(kind: pikRaster, spec: LayerSpecIn(rect: rect, name: name, blend: blend,
      mask: mask, realMask: realMask), section: SectionType(kind: stOther)))
  proc divider(id: uint32) =
    plan.add(PlanItem(kind: pikGroup, section: SectionType(kind: stBoundingDivider),
      groupName: GroupName, groupBlend: "norm", groupId: id))
  proc folder(name: string, blend: string, id: uint32, open: bool) =
    plan.add(PlanItem(kind: pikGroup,
      section: SectionType(kind: (if open: stOpenFolder else: stClosedFolder)),
      groupName: name, groupBlend: blend, groupId: id))

  raster(rectOf(0'i32, 0'i32, int32(w), int32(h)), "Background", "norm")
  raster(rectOf(-5, -3, 5, 4), "Neg offset \xF0\x9F\x98\x80", "mul ",
    some(newLayerMask(rectOf(-2, -2, 4, 3), 0'u8, newMaskFlags(1'u8))))
  # An empty layer: a degenerate rect and no usable pixels.
  raster(rectOf(0, 0, 0, 0), "Empty", "scrn")
  # Bounds well past the canvas, so clipping matters.
  raster(rectOf(-100, 5, 300, 7), "Wide", "over")

  # Nested groups: Outer [ layer, Inner [ masked layer with a real mask ] ].
  divider(1000)
  raster(rectOf(2, 2, 7, 7), "In outer", "dark")
  divider(1001)
  raster(rectOf(3, 3, 9, 7), "Gr\xC3\xBC\xC3\x9F\x65", "div ",
    some(innerMask), some(innerMask.real.get()))
  folder("Inner", "norm", 1002, false)
  folder("Outer", "pass", 1003, true)

  for i, key in blendKeys:
    raster(rectOf(int32(i mod 20), int32(i mod 12), int32(i mod 20 + 3),
      int32(i mod 12 + 2)), "blend " & $i, key)

  var layers: seq[LayerRecord] = @[]
  var alphaSeeds: seq[uint32] = @[]
  var colorSeeds: seq[seq[uint32]] = @[]
  var seed = 0'u32
  for item in plan:
    if item.kind == pikGroup:
      layers.add(groupRecord(mode, item.groupName, item.section, item.groupBlend,
        item.groupId))
      continue
    inc seed
    layers.add(rasterLayer(item.spec, seed, colorChannels, comp, depth, version))
    # Publish a seed only for a record that actually got planes, so the lists
    # line up with what a test finds in the parsed file. A zero-size layer
    # encodes no channels at all, and skipping it here keeps the two in step.
    let lw = max(int(item.spec.rect.right - item.spec.rect.left), 0)
    let lh = max(int(item.spec.rect.bottom - item.spec.rect.top), 0)
    if lw > 0 and lh > 0:
      alphaSeeds.add(seed)
      var perLayer: seq[uint32] = @[]
      for c in 0 ..< colorChannels:
        perLayer.add(seed + uint32(c) + 1)
      colorSeeds.add(perLayer)

  var planes: seq[string] = @[]
  for c in 0 ..< channels:
    planes.add(patternPlane(w, h, depth, MergedSeedBase + uint32(c)))
  let placement =
    if depth == 16:
      # 16-bit documents keep their layer info in an `Lr16` global block.
      LayerInfoPlacement(kind: pkGlobalBlock, index: 1, signature: "8BIM",
        key: "Lr16", padding: none(Span))
    else:
      LayerInfoPlacement(kind: pkSection)
  let blocks =
    if depth == 16: @[newTaggedBlock("Patt", ""), newTaggedBlock("Txt2", "\x00\x01\x02\x03")]
    else: @[newTaggedBlock("Patt", ""), newTaggedBlock("FMsk", repeat('\x00', 10))]
  # Built into a local first: assigning a field of the named `result` directly
  # trips a Nim 2.2 C-codegen bug on this shape of object constructor.
  var f = PsdFile(
    header: Header(version: version, channels: channels, height: h, width: w,
      depth: depth, colorMode: mode),
    colorModeData: spanOf(colorModeData(mode)),
    resources: baseResources(),
    layerInfo: some(LayerInfo(mergedAlpha: true, layers: layers,
      padding: none(Span))),
    layerInfoPlacement: placement,
    # A global layer mask with a real overlay colour space and a non-trivial
    # opacity, so the typed accessors have something to return.
    globalLayerMask: some(GlobalLayerMask(data: spanOf(
      # overlay colour space 0, components 0/0/0/50, opacity 50%, kind 128
      "\x00\x00" & "\x00\x00\x00\x00\x00\x00\x00\x32" &
      "\x00\x32" & "\x80"))),
    globalBlocks: blocks,
    layerMaskTrailing: emptySpan(),
    imageData: MergedImage(compression: comp,
      data: spanOf(encodePlanesFor(comp, planes, w, h, depth, version))))
  result.file = f
  result.alphaSeeds = alphaSeeds
  result.colorSeeds = colorSeeds


proc layered*(version: Version, mode: ColorMode, depth: int,
    comp: Compression): PsdFile {.inline.} =
  ## `layered` with the seeds discarded; use `layeredSeeded` to check payloads.
  let c = layeredSeeded(version, mode, depth, comp)
  c.file

proc small*(version: Version, comp: Compression): PsdFile =
  ## A genuinely tiny layered RGB file: a 4x3 canvas, three layers, a group and
  ## a mask, in a few hundred bytes.
  ##
  ## Built standalone rather than by resizing `layered`, for two reasons. The
  ## truncation sweep parses *every* prefix, so the file has to be small or the
  ## sweep is quadratic in a large body of mostly-redundant work; and resizing
  ## a layered file by rewriting the header alone would leave the composite and
  ## every layer encoded for a different geometry, which is not a valid file.
  ##
  ## One layer still extends past the canvas, so clipping is exercised.
  let mode = ColorMode(kind: cmRgb)
  let colorChannels = modeChannels(mode)
  let (w, h) = (4, 3)
  let mask = newLayerMask(rectOf(0, 0, 2, 2), 0'u8, newMaskFlags(0'u8))
  var plan: seq[PlanItem] = @[]
  plan.add(PlanItem(kind: pikRaster, spec: LayerSpecIn(
    rect: rectOf(0, 0, 4, 3), name: "a", blend: "norm", mask: some(mask))))
  plan.add(PlanItem(kind: pikGroup,
    section: SectionType(kind: stBoundingDivider), groupName: GroupName,
    groupBlend: "norm", groupId: 9))
  plan.add(PlanItem(kind: pikRaster, spec: LayerSpecIn(
    rect: rectOf(-1, 1, 3, 3), name: "b", blend: "scrn")))
  plan.add(PlanItem(kind: pikGroup,
    section: SectionType(kind: stOpenFolder), groupName: "g",
    groupBlend: "pass", groupId: 10))

  var layers: seq[LayerRecord] = @[]
  var seed = 0'u32
  for item in plan:
    if item.kind == pikGroup:
      layers.add(groupRecord(mode, item.groupName, item.section, item.groupBlend,
        item.groupId))
      continue
    inc seed
    layers.add(rasterLayer(item.spec, seed, colorChannels, comp, 8, version))

  var planes: seq[string] = @[]
  for c in 0 ..< colorChannels + 1:
    planes.add(patternPlane(w, h, 8, MergedSeedBase + uint32(c)))
  result = PsdFile(
    header: Header(version: version, channels: colorChannels + 1, height: h,
      width: w, depth: 8, colorMode: mode),
    colorModeData: emptySpan(),
    resources: @[resolutionResource(72.0)],
    layerInfo: some(LayerInfo(mergedAlpha: true, layers: layers,
      padding: none(Span))),
    layerInfoPlacement: LayerInfoPlacement(kind: pkSection),
    globalLayerMask: some(GlobalLayerMask(data: emptySpan())),
    globalBlocks: @[newTaggedBlock("Patt", "\x01\x02")],
    layerMaskTrailing: emptySpan(),
    imageData: MergedImage(compression: comp,
      data: spanOf(encodePlanesFor(comp, planes, w, h, 8, version))))

proc allCases*(): seq[TestCase] =
  ## The whole corpus: every mode at every meaningful depth, for every
  ## compression, in both container formats.
  result = @[]
  for version in AllVersions:
    for mode in AllModes:
      for depth in modeDepths(mode):
        for comp in AllCompressions:
          result.add(TestCase(name: "merged " & $version & " " & $mode & " " &
            $depth & "bit " & $comp,
            file: mergedOnly(version, mode, depth, comp, 13, 7)))
    for mode in [ColorMode(kind: cmGrayscale), ColorMode(kind: cmRgb),
                 ColorMode(kind: cmCmyk), ColorMode(kind: cmLab)]:
      for depth in modeDepths(mode):
        if depth < 8: continue
        for comp in AllCompressions:
          result.add(TestCase(name: "layered " & $version & " " & $mode & " " &
            $depth & "bit " & $comp,
            file: layered(version, mode, depth, comp)))
    for comp in AllCompressions:
      result.add(TestCase(name: "small " & $version & " " & $comp,
        file: small(version, comp)))