import std/options
import unittest
import ../src/opengraphics/psd



proc rect(t, l, b, r: int32): Rect = Rect(top: t, left: l, bottom: b, right: r)

suite "layers: rect":
  test "width and height are the differences":
    let r = rect(10, 20, 30, 45)
    check r.width() == 25
    check r.height() == 20

  test "bottom and right are exclusive, so an empty rect has zero size":
    let r = rect(0, 0, 0, 0)
    check r.width() == 0
    check r.height() == 0
    check r.isEmpty()

  test "an inverted rect is empty":
    check rect(30, 45, 10, 20).isEmpty()

  test "negative offsets are legal and still sized":
    let r = rect(-5, -7, 5, 8)
    check not r.isEmpty()
    check r.width() == 15
    check r.height() == 10

  test "size rejects an inverted rect":
    expect(PsdError):
      discard rect(30, 45, 10, 20).size()

  test "size rejects an implausible rect":
    expect(PsdError):
      discard rect(0, 0, 400_000, 1).size()

suite "layers: flags":
  test "layer flags round-trip through their raw byte":
    var f = newLayerFlags(0'u8)
    f.transparencyProtected = true
    f.hidden = true
    f.obsolete = true
    f.bit4Useful = true
    f.pixelDataIrrelevant = true
    check f.rawFlags() == 0x1F'u8
    let g = newLayerFlags(f.rawFlags())
    check g.transparencyProtected and g.hidden and g.obsolete
    check g.bit4Useful and g.pixelDataIrrelevant

  test "setting hidden also sets pixel-data-irrelevant":
    var f = newLayerFlags(0'u8)
    f.setHidden(true)
    check f.rawFlags() == 0x12'u8

  test "mask flags round-trip":
    var m = newMaskFlags(0'u8)
    m.relative = true
    m.disabled = true
    m.invert = true
    m.parameters = true
    check m.rawFlags() == 0x17'u8
    let n = newMaskFlags(m.rawFlags())
    check n.relative and n.disabled and n.invert and n.parameters

suite "layers: masks":
  proc maskBytes(rect: Rect, defaultColor: uint8, flags: uint8,
      trailing = "\x00\x00"): string =
    var w = initWriter()
    w.putI32(rect.top); w.putI32(rect.left)
    w.putI32(rect.bottom); w.putI32(rect.right)
    w.putU8(defaultColor)
    w.putU8(flags)
    w.put(trailing)
    w.toString()

  test "no mask bytes means mdNone":
    check parseLayerMask("").kind == mdNone

  test "a short payload is kept raw rather than rejected":
    let m = parseLayerMask("\x00\x01\x02")
    check m.kind == mdRaw

  test "the 20-byte form parses with no real rect":
    let m = parseLayerMask(maskBytes(rect(0, 0, 4, 4), 255, 0))
    check m.kind == mdMask
    check m.mask.rect == rect(0, 0, 4, 4)
    check m.mask.defaultColor == 255'u8
    check m.mask.real.isNone
    check m.mask.parameters.isNone
    check m.mask.trailing == "\x00\x00"

  test "the 36-byte form carries a real rect":
    var w = initWriter()
    w.put(maskBytes(rect(0, 0, 4, 4), 0, 0, ""))
    w.putU8(0x04)      # real flags: invert
    w.putU8(128)       # background
    w.putI32(1); w.putI32(2); w.putI32(5); w.putI32(6)
    let m = parseLayerMask(w.toString())
    check m.kind == mdMask
    check m.mask.real.isSome
    let rm = m.mask.real.get()
    check rm.background == 128'u8
    check rm.rect == rect(1, 2, 5, 6)

  test "flag bit 4 introduces mask parameters":
    var w = initWriter()
    w.put(maskBytes(rect(0, 0, 2, 2), 0, 0x10, ""))
    w.putU8(0x03) # user density + user feather
    w.putU8(200)
    w.putF64(1.5)
    let m = parseLayerMask(w.toString())
    check m.kind == mdMask
    check m.mask.parameters.isSome
    let p = m.mask.parameters.get()
    check p.userDensity.get() == 200'u8
    check p.userFeather.get() == 1.5
    check p.vectorDensity.isNone

  test "a mask round-trips through the writer":
    for raw in [maskBytes(rect(0, 0, 4, 4), 255, 0),
        maskBytes(rect(-2, -3, 6, 7), 0, 0x04)]:
      let m = parseLayerMask(raw)
      var w = initWriter()
      writeLayerMask(w, m)
      check w.toString() == raw

  test "a raw mask is written back verbatim":
    let raw = "\x00\x01\x02"
    var w = initWriter()
    writeLayerMask(w, parseLayerMask(raw))
    check w.toString() == raw

  test "mdNone writes nothing":
    var w = initWriter()
    writeLayerMask(w, parseLayerMask(""))
    check w.len == 0

suite "layers: blending ranges":
  test "full() writes one entry per channel plus a composite entry":
    let b = fullBlendingRanges(3)
    check b.data.len == 4 * 8

  test "ranges splits into source/destination pairs":
    let rs = fullBlendingRanges(1).ranges()
    check rs.len == 2
    check rs[0].source == [0'u8, 0, 255, 255]
    check rs[0].dest == [0'u8, 0, 255, 255]

  test "a short payload yields fewer entries rather than failing":
    check BlendingRanges(data: toSpan("abc")).ranges().len == 0
    check BlendingRanges(data: toSpan("12345678")).ranges().len == 1

suite "layers: channel rects":
  proc layerWithChannels(ids: openArray[int16]): LayerRecord =
    result.channels = newSeq[ChannelData](ids.len)
    for i, id in ids:
      result.channels[i] = ChannelData(id: id, compression: some(Raw), data: toSpan("x"))

  test "a colour channel uses the layer rect":
    var l = layerWithChannels([0'i16, 1, 2])
    l.rect = rect(4, 5, 10, 12)
    check l.channelRect(0'i16) == l.rect
    check l.channelRect(2'i16) == l.rect

  test "channel -2 uses the mask rect":
    var l = layerWithChannels([0'i16, -2'i16])
    l.rect = rect(0, 0, 10, 10)
    var w = initWriter()
    w.putI32(1); w.putI32(2); w.putI32(3); w.putI32(4)
    w.putU8(0); w.putU8(0)
    w.putU8(0); w.putU8(0)
    l.mask = parseLayerMask(w.toString())
    check l.channelRect(-2'i16) == rect(1, 2, 3, 4)

  test "channel -3 uses the real mask rect":
    var l = layerWithChannels([-3'i16])
    l.rect = rect(0, 0, 10, 10)
    var w = initWriter()
    w.putI32(0); w.putI32(0); w.putI32(4); w.putI32(4)
    w.putU8(0); w.putU8(0)
    w.putU8(0); w.putU8(0)
    w.putI32(5); w.putI32(6); w.putI32(9); w.putI32(8)
    l.mask = parseLayerMask(w.toString())
    check l.channelRect(-3'i16) == rect(5, 6, 9, 8)

  test "with no mask, -2 and -3 fall back to the layer rect":
    var l = layerWithChannels([-2'i16, -3'i16])
    l.rect = rect(1, 2, 3, 4)
    check l.channelRect(-2'i16) == l.rect
    check l.channelRect(-3'i16) == l.rect

  test "channel lookup by id":
    let l = layerWithChannels([0'i16, -1'i16, -2'i16])
    check l.channelIndex(-1'i16) == 1
    check l.channelIndex(-2'i16) == 2
    check l.channelIndex(9'i16) == -1
    check l.channel(-1'i16).get().id == -1'i16
    check l.channel(9'i16).isNone

suite "layers: channel data":
  test "a channel with no compression decodes to empty only when degenerate":
    let c = ChannelData(id: 0'i16, compression: none(Compression), data: toSpan(""))
    check c.storedLen() == 0
    check c.decode(0, 0, 8, Version.Psd) == ""
    expect(PsdError):
      discard c.decode(2, 2, 8, Version.Psd)

  test "encode then decode round-trips a plane":
    var plane = newString(12)
    for i in 0 ..< plane.len:
      plane[i] = char(byte(i * 7))
    let c = encodeChannel(0'i16, Rle, plane, 4, 3, 8, Version.Psd)
    check c.id == 0'i16
    check c.compression.get().kind == cRle
    check c.decode(4, 3, 8, Version.Psd) == plane

  test "storedLen counts the compression marker":
    let c = ChannelData(id: 0'i16, compression: some(Raw), data: toSpan("abcd"))
    check c.storedLen() == 6

suite "layers: tree building":
  proc layerWithSectionType(name: string, t: uint32,
      blend = ""): LayerRecord =
    result.name = name
    result.blendMode = if blend.len == 4: blend else: "pass"
    result.blocks = @[sectionDividerBlock(sectionTypeFromU32(t), blend)]

  test "flat layers produce flat nodes":
    let tree = buildLayerTree(@[LayerRecord(name: "a"),
      LayerRecord(name: "b")])
    check tree.len == 2
    check tree[0].kind == lnLayer

  test "a divider followed by a folder makes one group":
    let tree = buildLayerTree(@[
      layerWithSectionType("", 3'u32),
      LayerRecord(name: "child"),
      layerWithSectionType("grp", 1'u32),
    ])
    check tree.len == 1
    check tree[0].kind == lnGroup
    check tree[0].opened
    check tree[0].children.len == 1
    check tree[0].children[0].layer.name == "child"

  test "a closed folder is a group that is not opened":
    let tree = buildLayerTree(@[
      layerWithSectionType("", 3'u32),
      LayerRecord(name: "child"),
      layerWithSectionType("grp", 2'u32),
    ])
    check tree[0].kind == lnGroup
    check not tree[0].opened

  test "groups nest":
    let tree = buildLayerTree(@[
      layerWithSectionType("", 3'u32),
      layerWithSectionType("", 3'u32),
      LayerRecord(name: "deep"),
      layerWithSectionType("inner", 1'u32),
      layerWithSectionType("outer", 1'u32),
    ])
    check tree.len == 1
    check tree[0].children.len == 1
    check tree[0].children[0].children.len == 1

  test "sibling groups stay siblings":
    let tree = buildLayerTree(@[
      layerWithSectionType("", 3'u32),
      LayerRecord(name: "a"),
      layerWithSectionType("g1", 1'u32),
      layerWithSectionType("", 3'u32),
      LayerRecord(name: "b"),
      layerWithSectionType("g2", 1'u32),
    ])
    check tree.len == 2

  test "a stray folder becomes an empty top-level group":
    let tree = buildLayerTree(@[layerWithSectionType("g", 1'u32)])
    check tree.len == 1
    check tree[0].kind == lnGroup
    check tree[0].children.len == 0

  test "an unclosed divider flushes its children to the top":
    let tree = buildLayerTree(@[
      layerWithSectionType("", 3'u32),
      LayerRecord(name: "orphan"),
    ])
    check tree.len == 1
    check tree[0].kind == lnGroup
    check tree[0].children.len == 1

  test "section type 0 is an ordinary layer":
    let tree = buildLayerTree(@[layerWithSectionType("plain", 0'u32)])
    check tree[0].kind == lnLayer

  test "flattenTree drops dividers and keeps the rest":
    let layers = @[
      layerWithSectionType("", 3'u32),
      LayerRecord(name: "child"),
      layerWithSectionType("grp", 1'u32),
    ]
    let flat = flattenTree(buildLayerTree(layers))
    check flat.len == 2
    for l in flat:
      check not l.sectionType().isDivider()

suite "layers: record accessors":
  test "an empty record reads as normal, visible, opaque":
    let l = LayerRecord()
    check l.name() == ""
    check l.isVisible()
    check not l.isFolder()
    check not l.isDivider()
    check l.fillOpacity() == 255
    check l.layerId().isNone
    check l.layerMask().isNone
    check l.sectionType().kind == stOther

  test "luni wins over the legacy name":
    var l = LayerRecord(name: "legacy")
    l.blocks = @[unicodeNameBlock("Unicode")]
    check l.name() == "Unicode"

  test "lyid and iOpa are read from blocks":
    var l = LayerRecord()
    l.blocks = @[layerIdBlock(42'u32), fillOpacityBlock(128'u8)]
    check l.layerId().get() == 42'i32
    check l.fillOpacity() == 128

  test "lsdk is consulted when lsct is absent":
    var l = LayerRecord()
    l.blocks = @[TaggedBlock(signature: "8BIM", key: "lsdk",
      data: toSpan("\x00\x00\x00\x02"), padding: none(Span))]
    check l.sectionType().kind == stClosedFolder
    check l.isFolder()

  test "a hidden flag makes the record invisible":
    var l = LayerRecord(flags: newLayerFlags(2'u8))
    check not l.isVisible()

  test "a record round-trips through write and read":
    var l = LayerRecord(rect: rect(1, 2, 5, 6), blendMode: "mul ",
      opacity: 200, clipping: 1, filler: 7, name: "layer")
    l.flags = newLayerFlags(2'u8)
    l.channels = @[ChannelData(id: 0'i16, compression: some(Raw), data: toSpan("abc")),
      ChannelData(id: -1'i16, compression: some(Rle), data: toSpan("defg"))]
    l.channelLengths = @[2'i64 + 3, 2'i64 + 4]
    l.blendingRanges = fullBlendingRanges(1)
    l.blocks = @[layerIdBlock(9'u32), unicodeNameBlock("Named")]
    var w = initWriter()
    writeLayerRecord(w, l, Version.Psd)
    var r = initReader(w.toString())
    let got = readLayerRecord(r, Version.Psd)
    check got.rect == l.rect
    check got.blendMode == "mul "
    check got.opacity == 200
    check got.clipping == 1
    check got.filler == 7
    check got.name == "layer"
    check got.flags.hidden
    # a record carries the channel lengths, not the payloads: those live in
    # the channel data area after every record
    check got.channels.len == 2
    check got.channelLengths == @[5'i64, 6]
    check got.channels[0].data == ""
    check got.name() == "Named"
    check got.layerId().get() == 9'i32

  test "channel data is read afterwards, in record order":
    var l = LayerRecord(rect: rect(0, 0, 1, 1), blendMode: "norm",
      opacity: 255, name: "x")
    l.channels = @[ChannelData(id: 0'i16, compression: some(Raw), data: toSpan("A")),
      ChannelData(id: 1'i16, compression: some(Raw), data: toSpan("B"))]
    l.channelLengths = @[3'i64, 3]
    var rec = initWriter()
    writeLayerRecord(rec, l, Version.Psd)
    var area = initWriter()
    for c in l.channels:
      area.putU16(0) # Raw
      area.put(c.data)
    var r = initReader(rec.toString())
    var got = @[readLayerRecord(r, Version.Psd)]
    var areaR = initReader(area.toString())
    readLayerChannels(areaR, got, Version.Psd)
    check got[0].channels[0].data == "A"
    check got[0].channels[1].data == "B"
    check got[0].channels[0].compression.get().kind == cRaw

  test "a channel declaring length 1 is rejected":
    var w = initWriter()
    w.putStr4("8BIM")
    w.putU16(0)
    w.putStr4("norm")
    w.putU8(255); w.putU8(0); w.putU8(0); w.putU8(0)
    w.putU32(0)
    var layers = @[LayerRecord(rect: rect(0, 0, 1, 1), channels: @[
      ChannelData(id: 0'i16, compression: none(Compression), data: toSpan(""))],
      channelLengths: @[1'i64])]
    var area = initReader("\x00")
    expect(PsdError):
      readLayerChannels(area, layers, Version.Psd)

  test "a bad blend signature is rejected":
    var w = initWriter()
    w.putI32(0); w.putI32(0); w.putI32(1); w.putI32(1)
    w.putU16(1'u16)
    w.putI16(0'i16)
    w.putU32(0'u32)
    w.putStr4("XXXX")
    w.putU16(1'u16) # channels
    w.putI16(0'i16)
    w.putU32(0'u32)
    w.putStr4("norm")
    w.putU8(255); w.putU8(0); w.putU8(0); w.putU8(0)
    w.putU32(0'u32)
    var r = initReader(w.toString())
    try:
      discard readLayerRecord(r, Version.Psd)
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.InvalidSignature

  test "an absurd channel count is rejected before allocation":
    var w = initWriter()
    w.putI32(0); w.putI32(0); w.putI32(1); w.putI32(1)
    w.putU16(uint16(MaxLayerChannels + 1))
    var r = initReader(w.toString())
    try:
      discard readLayerRecord(r, Version.Psd)
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.LimitExceeded
