## Layer records, their channels, masks and the layer-and-mask section.
##
## The decisive design point here is that a channel keeps its **encoded**
## bytes. `ChannelData.data` is whatever the file held, and `compression`
## records how to interpret it; `decode` inflates on demand. Nothing is
## expanded at parse time, which is what lets an unmodified file be written
## back byte for byte.
##
## Wire layout of one record:
##   rect (4 x i32) | channel count u16 | per channel: id i16 + length
##   "8BIM" | blend key[4] | opacity u8 | clipping u8 | flags u8 | filler u8
##   extra length u32 (always 32-bit, even in PSB)
##     mask length u32 + mask bytes
##     blending ranges length u32 + bytes
##     Pascal name, padded to 4
##     tagged blocks
##
## Per-channel data lives *after* all the records, in the same order, and in
## PSB the per-channel length is 64-bit.

import std/options

import ./compression
import ./error
import ./header
import ./io
import ./tagged

type
  Rect* = object
    ## Layer and mask bounds. `bottom` and `right` are exclusive.
    top*, left*, bottom*, right*: int32

  MaskFlags* = object
    relative*: bool   ## mask position is relative to the layer
    disabled*: bool   ## do not apply the mask
    invert*: bool     ## invert when blending (obsolete but still written)
    parameters*: bool ## mask parameters follow

  MaskParameters* = object
    ## Present when MaskFlags.parameters is set. Each field is only read when
    ## its bit is set in `flags`.
    flags*: uint8
    userDensity*: Option[uint8]
    userFeather*: Option[float64]
    vectorDensity*: Option[uint8]
    vectorFeather*: Option[float64]

  RealMask* = object
    ## The 36-byte form's second rect, used for the vector-mask combined mask.
    flags*: uint8
    background*: uint8
    rect*: Rect

  LayerMask* = object
    rect*: Rect
    defaultColor*: uint8 ## 0 or 255
    flags*: MaskFlags
    parameters*: Option[MaskParameters]
    real*: Option[RealMask]
    trailing*: Span   ## bytes after the known prefix, e.g. the 20-byte pad

  MaskDataKind* {.pure.} = enum
    mdNone, mdMask, mdRaw

  MaskData* = object
    ## `mdRaw` keeps a mask we could not parse, so its bytes are never lost.
    case kind*: MaskDataKind
    of mdNone: discard
    of mdMask: mask*: LayerMask
    of mdRaw: raw*: Span

  BlendingRanges* = object
    ## Kept raw. The record is (channels+1) pairs of four bytes: source range
    ## then destination range, composite-gray first.
    data*: Span

  BlendRange* = object
    source*: array[4, byte]
    dest*: array[4, byte]

  LayerFlags* = object
    ## Bits 0-4 of the layer record's flags byte. Only those are defined by
    ## the spec.
    transparencyProtected*: bool
    hidden*: bool
    obsolete*: bool
    bit4Useful*: bool
    pixelDataIrrelevant*: bool
    reserved*: uint8
      ## Bits 5-7, which the spec leaves undefined. Photoshop writes bit 5 in
      ## real files, so they are carried through verbatim: without this a
      ## read/write cycle silently drops them and the file no longer round-trips
      ## byte for byte.

  ChannelData* = object
    id*: int16
      ## 0.. are colour planes in file order, then -1 alpha,
      ## -2 user mask, -3 "real" user mask
    compression*: Option[Compression]
      ## `none` when the stored length was zero, meaning there is no data at
      ## all (group dividers and empty layers)
    data*: Span   ## encoded bytes, verbatim, as a window into the file. This
                  ## is the single largest thing a PSD holds, so it must not be
                  ## copied at parse time.

  LayerRecord* = object
    rect*: Rect
    channels*: seq[ChannelData]
    blendMode*: string
    opacity*: int
    clipping*: int ## 0 base, non-zero clipped to the layer below
    flags*: LayerFlags
    filler*: uint8
    mask*: MaskData
    blendingRanges*: BlendingRanges
    name*: string ## legacy Pascal name bytes, decoded lossily
    blocks*: seq[TaggedBlock]
    extraTrailing*: Span   ## bytes at the end of extra data that are not a block
    channelLengths*: seq[int64]
      ## Per-channel stored lengths, read with the record and used to frame
      ## the channel data area. Parallel to `channels`; not part of the model
      ## a caller edits, so `writeLayerRecord` recomputes it from the data.

  LayerInfo* = object
    mergedAlpha*: bool ## the layer count was stored negative
    layers*: seq[LayerRecord] ## file order, bottom-most first
    padding*: Option[Span]
      ## `none` means "zero-pad to even"; the parser yields `none` whenever
      ## the file used that default

  LayerNodeKind* {.pure.} = enum
    lnLayer, lnGroup

  LayerNode* = ref object
    ## One node of the layer hierarchy. Leaves wrap a pixel layer; groups wrap
    ## the folder record and own the layers nested inside it.
    layer*: LayerRecord
    kind*: LayerNodeKind
    opened*: bool ## only meaningful for a group
    children*: seq[LayerNode]

const
  ## Minimum bytes one layer record can occupy: rect 16 + count 2 +
  ## signature 4 + blend key 4 + four flag bytes + extra length 4.
  MinLayerRecordBytes* = 34
  MaxLayerChannels* = 64
  MaxLayerCount* = 8_000

  ChannelTransparency* = -1'i16
  ChannelUserMask* = -2'i16
  ChannelRealUserMask* = -3'i16

proc width*(r: Rect): int {.inline.} = int(r.right - r.left)
proc height*(r: Rect): int {.inline.} = int(r.bottom - r.top)
proc isEmpty*(r: Rect): bool {.inline.} = r.width() <= 0 or r.height() <= 0

proc size*(r: Rect): tuple[w, h: int] =
  ## Raise on a negative or implausible rect rather than allocating from it.
  if r.isEmpty():
    invalid("layer rect is empty or inverted (" & $r.top & "," & $r.left &
      ")-(" & $r.bottom & "," & $r.right & ")")
  let w = r.width()
  let h = r.height()
  if w > MaxDimension or h > MaxDimension:
    limitExceeded("layer rect " & $w & "x" & $h & " exceeds " & $MaxDimension)
  (w, h)

proc newMaskFlags*(raw: uint8): MaskFlags {.inline.} =
  MaskFlags(relative: (raw and 1'u8) != 0,
    disabled: (raw and 2'u8) != 0,
    invert: (raw and 4'u8) != 0,
    parameters: (raw and 16'u8) != 0)

proc rawFlags*(m: MaskFlags): uint8 {.inline.} =
  var v = 0'u8
  if m.relative: v = v or 1'u8
  if m.disabled: v = v or 2'u8
  if m.invert: v = v or 4'u8
  if m.parameters: v = v or 16'u8
  v

proc newLayerFlags*(raw: uint8): LayerFlags {.inline.} =
  LayerFlags(transparencyProtected: (raw and 1'u8) != 0,
    hidden: (raw and 2'u8) != 0,
    obsolete: (raw and 4'u8) != 0,
    bit4Useful: (raw and 8'u8) != 0,
    pixelDataIrrelevant: (raw and 16'u8) != 0,
    reserved: raw and 0xE0'u8)

proc rawFlags*(f: LayerFlags): uint8 {.inline.} =
  var v = f.reserved and 0xE0'u8
  if f.transparencyProtected: v = v or 1'u8
  if f.hidden: v = v or 2'u8
  if f.obsolete: v = v or 4'u8
  if f.bit4Useful: v = v or 8'u8
  if f.pixelDataIrrelevant: v = v or 16'u8
  v

proc isHidden*(f: LayerFlags): bool {.inline.} = f.hidden

proc setHidden*(f: var LayerFlags, v: bool) {.inline.} =
  ## Setting pixel-data-irrelevant also sets bit 3, matching Photoshop.
  f.hidden = v
  if v: f.pixelDataIrrelevant = true

proc spanOf*(s: string): Span {.inline.} =
  ## A window over bytes we just made. For the constructors and tests; parsed
  ## values keep a window into the file instead of copying out of it.
  Span(src: newStringSource(s), start: 0, stop: s.len)

proc newLayerMask*(rect: Rect, defaultColor: uint8, flags: MaskFlags): LayerMask =
  ## The 20-byte form: no parameters, no real rect, two pad bytes.
  LayerMask(rect: rect, defaultColor: defaultColor, flags: flags,
    parameters: none(MaskParameters), real: none(RealMask),
    trailing: spanOf("\x00\x00"))

proc parseLayerMask*(raw: Span): MaskData =
  ## Parse a mask-data field. Anything unparseable is kept as `mdRaw` so no
  ## bytes are lost.
  ##
  ## Order: rect, default colour, flags, parameters when flag bit 4 is set,
  ## then the real flags/background/rect whenever at least 18 bytes remain.
  ## Everything left over (the 2 pad bytes of the 20-byte form, say) is kept
  ## in `trailing`.
  if raw.len == 0:
    return MaskData(kind: mdNone)
  if raw.len < 20:
    return MaskData(kind: mdRaw, raw: raw)
  try:
    var r = initReader(raw)
    let rect = Rect(top: r.readI32BE(), left: r.readI32BE(),
      bottom: r.readI32BE(), right: r.readI32BE())
    let defaultColor = r.readU8()
    var m = newLayerMask(rect, defaultColor, newMaskFlags(r.readU8()))
    if m.flags.parameters and r.remaining() > 0:
      var p = MaskParameters(flags: r.readU8())
      if (p.flags and 1'u8) != 0 and r.remaining() >= 1:
        p.userDensity = some(r.readU8())
      if (p.flags and 2'u8) != 0 and r.remaining() >= 8:
        p.userFeather = some(r.readF64BE())
      if (p.flags and 4'u8) != 0 and r.remaining() >= 1:
        p.vectorDensity = some(r.readU8())
      if (p.flags and 8'u8) != 0 and r.remaining() >= 8:
        p.vectorFeather = some(r.readF64BE())
      m.parameters = some(p)
    if r.remaining() >= 18:
      m.real = some(RealMask(flags: r.readU8(), background: r.readU8(),
        rect: Rect(top: r.readI32BE(), left: r.readI32BE(),
          bottom: r.readI32BE(), right: r.readI32BE())))
    m.trailing = r.peekRest()
    MaskData(kind: mdMask, mask: m)
  except PsdError:
    MaskData(kind: mdRaw, raw: raw)

proc writeLayerMask*(w: var Writer, m: MaskData) =
  ## Inverse of `parseLayerMask`. `mdRaw` is written back verbatim.
  case m.kind
  of mdNone:
    discard
  of mdRaw:
    w.put(m.raw)
  of mdMask:
    let mm = m.mask
    w.putI32(mm.rect.top)
    w.putI32(mm.rect.left)
    w.putI32(mm.rect.bottom)
    w.putI32(mm.rect.right)
    w.putU8(mm.defaultColor)
    w.putU8(mm.flags.rawFlags)
    if mm.parameters.isSome:
      let p = mm.parameters.get()
      w.putU8(p.flags)
      if p.userDensity.isSome: w.putU8(p.userDensity.get())
      if p.userFeather.isSome: w.putF64(p.userFeather.get())
      if p.vectorDensity.isSome: w.putU8(p.vectorDensity.get())
      if p.vectorFeather.isSome: w.putF64(p.vectorFeather.get())
    if mm.real.isSome:
      let rm = mm.real.get()
      w.putU8(rm.flags)
      w.putU8(rm.background)
      w.putI32(rm.rect.top)
      w.putI32(rm.rect.left)
      w.putI32(rm.rect.bottom)
      w.putI32(rm.rect.right)
    w.put(mm.trailing)

proc maskRect*(m: MaskData): Rect =
  ## The rect a -2 channel is sized by; an empty rect when there is no mask.
  if m.kind == mdMask:
    let mm = m.mask
    return mm.rect
  Rect()

proc fullBlendingRanges*(channelCount: int): BlendingRanges =
  ## The "no restriction" ranges Photoshop writes by default: one entry per
  ## channel plus a composite entry, each 0,0,255,255 twice.
  var w = initWriter()
  for _ in 0 .. channelCount:
    for _ in 0 .. 1:
      w.putU8(0); w.putU8(0); w.putU8(255); w.putU8(255)
  BlendingRanges(data: spanOf(w.toString()))

proc ranges*(b: BlendingRanges): seq[BlendRange] =
  ## Split the raw bytes into per-channel source/destination ranges. The
  ## record count is not validated against the layer, matching the reference.
  result = @[]
  var i = 0
  while i + 8 <= b.data.len:
    var src: array[4, byte]
    var dst: array[4, byte]
    for k in 0 ..< 4:
      src[k] = b.data.byteAt(i + k)
      dst[k] = b.data.byteAt(i + 4 + k)
    result.add(BlendRange(source: src, dest: dst))
    i += 8

proc storedLen*(c: ChannelData): int64 {.inline.} =
  ## Bytes this channel occupies in the channel data area.
  if c.compression.isSome: 2'i64 + int64(c.data.len) else: 0'i64

proc decode*(c: ChannelData, width, height, depth: int,
    version: Version): string =
  ## Inflate one channel to planar big-endian samples. A channel with no
  ## stored data decodes to empty only when the geometry is degenerate.
  if c.compression.isNone:
    if width <= 0 or height <= 0:
      return ""
    invalid("channel " & $c.id & " has no data")
  let l = newPlaneLayout(1, width, height, depth, version)
  decodePlanes(c.compression.get(), c.data, l)

proc encodeChannel*(id: int16, comp: Compression, decoded: string,
    width, height, depth: int, version: Version): ChannelData =
  ## Inverse of `decode`: re-encode a decoded plane for writing.
  let l = newPlaneLayout(1, width, height, depth, version)
  ChannelData(id: id, compression: some(comp),
    data: spanOf(encodePlanes(comp, decoded, l)))

proc channel*(l: LayerRecord, id: int16): Option[ChannelData] =
  for c in l.channels:
    if c.id == id:
      return some(c)
  none(ChannelData)

proc channelIndex*(l: LayerRecord, id: int16): int =
  for i, c in l.channels:
    if c.id == id:
      return i
  -1

proc channelRect*(l: LayerRecord, id: int16): Rect =
  ## The rect a channel is sized by. -2 uses the mask rect and -3 the real
  ## mask rect, falling back to the layer rect when either is absent.
  if id == ChannelUserMask:
    if l.mask.kind == mdMask:
      return l.mask.mask.rect
  elif id == ChannelRealUserMask:
    if l.mask.kind == mdMask and l.mask.mask.real.isSome:
      return l.mask.mask.real.get().rect
    if l.mask.kind == mdMask:
      return l.mask.mask.rect
  l.rect

proc getBlock*(l: LayerRecord, key: string): Option[TaggedBlock] =
  let i = findBlock(l.blocks, key)
  if i < 0: none(TaggedBlock) else: some(l.blocks[i])

proc name*(l: LayerRecord): string =
  ## `luni` when present, else the legacy name. Both are kept on the record;
  ## this is the display name.
  let u = l.getBlock("luni")
  if u.isSome:
    let d = u.get().parsed()
    if d.isSome:
      let bd = d.get()
      if bd.kind == bdUnicodeName and bd.name.len > 0:
        return bd.name
  decodeLegacyName(l.name)

proc sectionDivider*(l: LayerRecord): Option[SectionDivider] =
  ## `lsct` first, then `lsdk`. `lsdk` marks a layer nested inside a group
  ## and wins when both are present.
  for key in ["lsct", "lsdk"]:
    let b = l.getBlock(key)
    if b.isSome:
      let d = b.get().parsed()
      if d.isSome:
        let bd = d.get()
        if bd.kind == bdSectionDivider:
          return some(bd.divider)
  none(SectionDivider)

proc sectionType*(l: LayerRecord): SectionType =
  let sd = l.sectionDivider()
  if sd.isSome: sd.get().sectionType() else: SectionType(kind: stOther)

proc layerId*(l: LayerRecord): Option[int32] =
  let b = l.getBlock("lyid")
  if b.isNone:
    return none(int32)
  let d = b.get().parsed()
  if d.isSome:
    let bd = d.get()
    if bd.kind == bdLayerId:
      return some(int32(bd.layerId))
  none(int32)

proc fillOpacity*(l: LayerRecord): int =
  ## `iOpa`, defaulting to 255.
  let b = l.getBlock("iOpa")
  if b.isNone:
    return 255
  let d = b.get().parsed()
  if d.isSome:
    let bd = d.get()
    if bd.kind == bdFillOpacity:
      return int(bd.fillOpacity)
  255

proc isVisible*(l: LayerRecord): bool {.inline.} = not l.flags.hidden

proc isFolder*(l: LayerRecord): bool {.inline.} = l.sectionType().isFolder()

proc isDivider*(l: LayerRecord): bool {.inline.} = l.sectionType().isDivider()

proc layerMask*(l: LayerRecord): Option[LayerMask] =
  if l.mask.kind == mdMask:
    let m = l.mask.mask
    return some(m)
  none(LayerMask)

proc readLayerRecord*(r: var Reader, version: Version,
    limits = defaultLimits()): LayerRecord =
  ## One record. Channel *data* is not read here; it comes later, after every
  ## record, which is why channel lengths are remembered on the record.
  result.rect = Rect(top: r.readI32BE(), left: r.readI32BE(),
    bottom: r.readI32BE(), right: r.readI32BE())
  let channelCount = int(r.readU16BE())
  if channelCount > MaxLayerChannels:
    limitExceeded("layer channel count " & $channelCount & " exceeds " &
      $MaxLayerChannels)
  result.channels = newSeq[ChannelData](channelCount)
  result.channelLengths = newSeq[int64](channelCount)
  for i in 0 ..< channelCount:
    result.channels[i].id = r.readI16BE()
    result.channelLengths[i] = r.lenField(version.isPsb())
    if result.channelLengths[i] > r.remaining:
      eof(int(result.channelLengths[i] - r.remaining), r.pos)
  let sigPos = r.pos
  let sig = r.readStr4()
  if sig != "8BIM":
    badSignature("8BIM", sig, sigPos)
  result.blendMode = r.readStr4()
  result.opacity = int(r.readU8())
  result.clipping = int(r.readU8())
  result.flags = newLayerFlags(r.readU8())
  result.filler = r.readU8()
  let extraLen = r.lenField(false) # always 32-bit, even in PSB
  if extraLen > r.remaining:
    eof(int(extraLen - r.remaining), r.pos)
  var extra = r.sub(extraLen)
  let maskLen = extra.lenField(false)
  if maskLen > extra.remaining:
    eof(int(maskLen - extra.remaining), extra.pos)
  let maskRaw = extra.bytes(int(maskLen))
  result.mask = parseLayerMask(maskRaw)
  let rangeLen = extra.lenField(false)
  if rangeLen > extra.remaining:
    eof(int(rangeLen - extra.remaining), extra.pos)
  result.blendingRanges = BlendingRanges(data: extra.bytes(int(rangeLen)))
  result.name = extra.readPascal(4)
  let got = readBlocks(extra, version, limits)
  result.blocks = got.blocks
  result.extraTrailing = got.trailing

proc writeLayerRecord*(w: var Writer, l: LayerRecord, version: Version) =
  ## Inverse of `readLayerRecord`. Channel data is written separately.
  w.putI32(l.rect.top)
  w.putI32(l.rect.left)
  w.putI32(l.rect.bottom)
  w.putI32(l.rect.right)
  w.putU16(uint16(l.channels.len))
  for c in l.channels:
    w.putI16(c.id)
    w.putLen(c.storedLen(), version.isPsb())
  w.putStr4("8BIM")
  w.putStr4(l.blendMode)
  w.putU8(uint8(l.opacity))
  w.putU8(uint8(l.clipping))
  w.putU8(l.flags.rawFlags)
  w.putU8(l.filler)
  let extraAt = w.beginLen(false)
  let maskAt = w.beginLen(false)
  writeLayerMask(w, l.mask)
  w.endLen(maskAt, false)
  let rangeAt = w.beginLen(false)
  w.put(l.blendingRanges.data)
  w.endLen(rangeAt, false)
  w.writePascal(l.name, 4)
  writeBlocks(w, l.blocks, version)
  w.put(l.extraTrailing)
  w.endLen(extraAt, false)

proc readLayerChannels*(r: var Reader, layers: var seq[LayerRecord],
    version: Version) =
  ## Read the channel data area, which follows every record in order.
  for i in 0 ..< layers.len:
    for j in 0 ..< layers[i].channels.len:
      let stored = layers[i].channelLengths[j]
      if stored == 0:
        layers[i].channels[j].compression = none(Compression)
        layers[i].channels[j].data = Span(src: r.root, start: r.pos, stop: r.pos)
        continue
      if stored == 1:
        invalid("channel data length 1")
      let compRaw = r.readU16BE()
      let remaining = stored - 2
      if remaining > r.remaining:
        eof(int(remaining - r.remaining), r.pos)
      let payload = r.bytes(int(remaining))
      layers[i].channels[j].compression = some(compressionFromU16(compRaw))
      layers[i].channels[j].data = payload

proc readLayerInfoBody*(r: var Reader, version: Version,
    limits = defaultLimits()): LayerInfo =
  ## The layer info body: an i16 count (negative means the merged image has
  ## alpha), that many records, then the channel data area.
  result.mergedAlpha = false
  result.layers = @[]
  result.padding = none(Span)
  if r.remaining() < 2:
    result.padding = some(r.peekRest())
    return
  let countRaw = r.readI16BE()
  var count = int(countRaw)
  if count < 0:
    result.mergedAlpha = true
    count = -count
  if count > MaxLayerCount:
    limitExceeded("layer count " & $count & " exceeds " & $MaxLayerCount)
  # every record needs at least MinLayerRecordBytes
  if int64(count) * MinLayerRecordBytes > r.remaining:
    limitExceeded("layer count " & $count & " does not fit in " &
      $r.remaining & " remaining bytes")
  for _ in 0 ..< count:
    result.layers.add(readLayerRecord(r, version, limits))
  readLayerChannels(r, result.layers, version)
  # trailing bytes: the canonical form is a single zero pad byte, so only a
  # deviation needs recording
  let rest = r.peekRest()
  if rest.len == 1 and rest.byteAt(0) == 0'u8:
    r.skip(1)
    result.padding = none(Span)
  elif rest.len == 0:
    result.padding = none(Span)
  else:
    r.skip(rest.len)
    result.padding = some(rest)

proc writeLayerInfoBody*(w: var Writer, info: LayerInfo,
    version: Version) =
  ## Inverse of `readLayerInfoBody`. The pad byte is decided from the body's
  ## own length, not the writer's, since this body sits at a file offset.
  let bodyStart = w.len
  var count = info.layers.len
  if info.mergedAlpha:
    count = -count
  w.putI16(int16(count))
  for l in info.layers:
    writeLayerRecord(w, l, version)
  for l in info.layers:
    for c in l.channels:
      if c.compression.isSome:
        w.putU16(c.compression.get().toU16())
        w.put(c.data)
  if info.padding.isSome:
    w.put(info.padding.get())
  elif ((w.len - bodyStart) and 1) != 0:
    w.putU8(0)

proc buildLayerTree*(layers: seq[LayerRecord]): seq[LayerNode] =
  ## Nest the flat, bottom-first file order into a hierarchy.
  ##
  ## A bounding divider (section type 3) opens a group and the matching folder
  ## record (1 open or 2 closed) closes it, supplying the group's properties,
  ## so one bottom-to-top pass suffices. Dividers are dropped. `lsdk` wins
  ## over `lsct`, and type 0 is an ordinary layer.
  ##
  ## Malformed nesting degrades rather than failing: a stray folder becomes an
  ## empty group and unclosed groups are flushed to the top level.
  var stack: seq[LayerNode] = @[]
  var top: seq[LayerNode] = @[]
  for l in layers:
    let st = l.sectionType()
    if st.isDivider():
      stack.add(LayerNode(layer: l, kind: lnGroup, opened: true, children: @[]))
    elif st.isFolder():
      var node =
        if stack.len > 0: stack.pop()
        else: LayerNode(layer: l, kind: lnGroup, opened: true, children: @[])
      node.layer = l
      node.kind = lnGroup
      node.opened = st.kind == stOpenFolder
      if stack.len > 0:
        stack[^1].children.add(node)
      else:
        top.add(node)
    else:
      let node = LayerNode(layer: l, kind: lnLayer, opened: false,
        children: @[])
      if stack.len > 0:
        stack[^1].children.add(node)
      else:
        top.add(node)
  while stack.len > 0:
    let node = stack.pop()
    if stack.len > 0:
      stack[^1].children.add(node)
    else:
      top.add(node)
  result = top

proc flattenTree*(nodes: seq[LayerNode]): seq[LayerRecord] =
  ## Pre-order walk back to flat records: groups included, dividers not.
  for n in nodes:
    if not n.layer.sectionType().isDivider():
      result.add(n.layer)
    for l in flattenTree(n.children):
      result.add(l)

proc parseLayerMask*(raw: string): MaskData =
  ## `parseLayerMask` over bytes the caller already holds.
  parseLayerMask(toSpan(raw))
