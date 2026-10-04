import std/options
import std/strutils
import unittest
import ../src/opengraphics/psd




proc solid(w, h: int, r, g, b: uint8, a = 255'u8): PixelData =
  ## An opaque rectangle of one colour.
  result = initRgba8(w, h)
  for i in 0 ..< w * h:
    result.rgba8[i * 4 + 0] = r
    result.rgba8[i * 4 + 1] = g
    result.rgba8[i * 4 + 2] = b
    result.rgba8[i * 4 + 3] = a

proc gradient(w, h: int): PixelData =
  ## Distinct values per pixel, so a mis-ordered plane shows up immediately.
  result = initRgba8(w, h)
  for i in 0 ..< w * h:
    result.rgba8[i * 4 + 0] = uint8((i * 4) and 0xFF)
    result.rgba8[i * 4 + 1] = uint8((i * 4 + 1) and 0xFF)
    result.rgba8[i * 4 + 2] = uint8((i * 4 + 2) and 0xFF)
    result.rgba8[i * 4 + 3] = 255'u8

proc oneLayer(): PsdFile =
  ## An 8x8 RGB document with one gradient layer and no composite.
  var b = initPsdBuilder(8, 8)
  b.pushLayer(newLayerSpec("base", 0, 0, 8, 8, gradient(8, 8)))
  readPsd(b.toBytes())

suite "builder: header and structure":
  test "the header reports what was asked for":
    let f = oneLayer()
    check f.width == 8
    check f.height == 8
    check f.header.depth == 8
    check f.header.colorMode.kind == cmRgb
    # 3 colour planes, no alpha because nothing was composited
    check f.header.channels == 3

  test "the layer record carries the spec's fields":
    let l = oneLayer().layers()[0]
    check l.name == "base"
    check l.rect == Rect(top: 0, left: 0, bottom: 8, right: 8)
    check l.blendMode == "norm"
    check l.opacity == 255
    check l.clipping == 0
    check not l.flags.hidden
    check l.mask.kind == mdNone

  test "channels are alpha first, then colour planes in order":
    let l = oneLayer().layers()[0]
    check l.channels.len == 4
    check l.channels[0].id == -1
    check l.channels[1].id == 0
    check l.channels[2].id == 1
    check l.channels[3].id == 2

  test "every channel is stored with the builder's compression":
    let expected = some(Rle)
    for c in oneLayer().layers()[0].channels:
      check c.compression == expected

  test "the name is written as both a Pascal name and an luni block":
    let l = oneLayer().layers()[0]
    check l.getBlock("luni").isSome
    check l.getBlock("lyid").isSome

  test "an empty builder writes no layer section at all":
    var b = initPsdBuilder(4, 4)
    let f = readPsd(b.toBytes())
    check f.layerInfo.isNone
    check f.globalLayerMask.isNone

  test "the merged image is a white placeholder when none is supplied":
    var b = initPsdBuilder(2, 2)
    let f = readPsd(b.toBytes())
    check not f.hasRealMergedData()
    check f.imageData.compression == Rle

  test "a supplied composite is flagged as real":
    var b = initPsdBuilder(2, 2)
    b.setComposite(solid(2, 2, 10, 20, 30))
    check readPsd(b.toBytes()).hasRealMergedData()

  test "the 1057 resource records the flag":
    var b = initPsdBuilder(2, 2)
    b.setComposite(solid(2, 2, 1, 2, 3))
    let f = readPsd(b.toBytes())
    check versionInfo(f.resources).get().hasRealMergedData
    check versionInfo(f.resources).get().writer == "Adobe Photoshop"

suite "builder: pixel fidelity":
  test "each colour plane decodes back to its own samples":
    let f = oneLayer()
    let src = gradient(8, 8)
    let l = f.layers()[0]
    for c in 0 .. 2:
      let plane = l.channels[c + 1].decode(8, 8, 8, Version.Psd)
      check plane.len == 64
      for i in 0 ..< 64:
        check ord(plane[i]) == int(src.rgba8[i * 4 + c])

  test "the alpha plane decodes to opaque":
    let f = oneLayer()
    let plane = f.layers()[0].channels[0].decode(8, 8, 8, Version.Psd)
    for v in plane:
      check ord(v) == 255

  test "a non-opaque alpha plane is preserved":
    var b = initPsdBuilder(4, 4)
    b.pushLayer(newLayerSpec("a", 0, 0, 4, 4, solid(4, 4, 9, 9, 9, 128)))
    let f = readPsd(b.toBytes())
    let plane = f.layers()[0].channels[0].decode(4, 4, 8, Version.Psd)
    for v in plane:
      check ord(v) == 128

  test "an offset layer keeps its position":
    var b = initPsdBuilder(16, 16)
    b.pushLayer(newLayerSpec("off", 4, 6, 8, 8, solid(8, 8, 1, 2, 3)))
    let l = readPsd(b.toBytes()).layers()[0]
    check l.rect == Rect(top: 6, left: 4, bottom: 14, right: 12)

  test "the merged image decodes to the composite":
    var b = initPsdBuilder(4, 4)
    b.setComposite(solid(4, 4, 40, 50, 60))
    let f = readPsd(b.toBytes())
    let decoded = decodePlanes(f.imageData.compression, f.imageData.data,
      f.mergedLayout())
    check decoded.len == 48
    for c in 0 .. 2:
      for i in 0 ..< 16:
        check ord(decoded[c * 16 + i]) == int([40'u8, 50'u8, 60'u8][c])

  test "a composite with alpha keeps its alpha plane":
    var b = initPsdBuilder(4, 4)
    b.setComposite(solid(4, 4, 7, 7, 7, 200))
    let f = readPsd(b.toBytes())
    check f.header.channels == 4
    let decoded = decodePlanes(f.imageData.compression, f.imageData.data,
      f.mergedLayout())
    for i in 0 ..< 16:
      check ord(decoded[48 + i]) == 200

  test "an opaque composite drops the alpha plane":
    var b = initPsdBuilder(4, 4)
    b.setComposite(solid(4, 4, 7, 7, 7, 255))
    check readPsd(b.toBytes()).header.channels == 3

suite "builder: colour modes and depths":
  test "16-bit grayscale works and lands in an Lr16 block":
    var b = initPsdBuilder(4, 4)
    b.setColorMode(ColorMode(kind: cmGrayscale))
    b.setDepth(16)
    b.pushLayer(newLayerSpec("g16", 0, 0, 4, 4, initGrayA16(4, 4)))
    b.setComposite(initGrayA16(4, 4))
    let f = readPsd(b.toBytes())
    check f.header.colorMode.kind == cmGrayscale
    check f.header.depth == 16
    check f.layerInfoPlacement.kind == pkGlobalBlock
    check f.layerInfoPlacement.key == "Lr16"
    check f.layers().len == 1

  test "8-bit documents keep their layer info in the section":
    check oneLayer().layerInfoPlacement.kind == pkSection

  test "CMYK ink is stored inverted":
    var b = initPsdBuilder(2, 1)
    b.setColorMode(ColorMode(kind: cmCmyk))
    var cm = initCmyka8(2, 1)
    cm.cmyka8 = @[10'u8, 20'u8, 30'u8, 40'u8, 255'u8,
                  0'u8, 0'u8, 0'u8, 0'u8, 128'u8]
    b.pushLayer(newLayerSpec("cmyk", 0, 0, 2, 1, cm))
    b.setComposite(cm)
    let f = readPsd(b.toBytes())
    check f.header.colorMode.kind == cmCmyk
    check f.header.channels == 5   # 4 ink plus a non-opaque alpha
    for c in 0 ..< 4:
      let plane = f.layers()[0].channels[c + 1].decode(2, 1, 8, Version.Psd)
      # ink 10 is stored 245; ink 0 is stored 255
      check ord(plane[0]) == 255 - int([10'u8, 20'u8, 30'u8, 40'u8][c])
      check ord(plane[1]) == 255

  test "CMYK alpha is not inverted":
    var b = initPsdBuilder(2, 1)
    b.setColorMode(ColorMode(kind: cmCmyk))
    var cm = initCmyka8(2, 1)
    cm.cmyka8 = @[10'u8, 20'u8, 30'u8, 40'u8, 255'u8,
                  0'u8, 0'u8, 0'u8, 0'u8, 128'u8]
    b.pushLayer(newLayerSpec("cmyk", 0, 0, 2, 1, cm))
    b.setComposite(cm)
    let f = readPsd(b.toBytes())
    let plane = f.layers()[0].channels[0].decode(2, 1, 8, Version.Psd)
    check ord(plane[0]) == 255
    check ord(plane[1]) == 128

  test "16-bit RGB samples survive the round trip":
    var b = initPsdBuilder(4, 4)
    b.setDepth(16)
    var p = initRgba16(4, 4)
    for i in 0 ..< 16:
      p.rgba16[i * 4 + 0] = uint16(1000 + i * 100)
      p.rgba16[i * 4 + 1] = 0xFFFF'u16
      p.rgba16[i * 4 + 2] = 0'u16
      p.rgba16[i * 4 + 3] = 0xFFFF'u16
    b.pushLayer(newLayerSpec("hi", 0, 0, 4, 4, p))
    b.setComposite(p)
    let f = readPsd(b.toBytes())
    let plane = f.layers()[0].channels[1].decode(4, 4, 16, Version.Psd)
    check plane.len == 32
    for i in 0 ..< 16:
      let got = (uint16(ord(plane[i * 2])) shl 8) or uint16(ord(plane[i * 2 + 1]))
      check got == p.rgba16[i * 4]

  test "PSB is written with the large-document signature":
    var b = initPsbBuilder(4, 4)
    b.pushLayer(newLayerSpec("p", 0, 0, 4, 4, solid(4, 4, 1, 1, 1)))
    let f = readPsd(b.toBytes())
    check f.header.version == Version.Psb

  test "an indexed document is rejected":
    var b = initPsdBuilder(4, 4)
    b.setColorMode(ColorMode(kind: cmIndexed))
    expect(PsdError):
      discard b.build()

  test "a 32-bit document is rejected":
    var b = initPsdBuilder(4, 4)
    b.setDepth(32)
    expect(PsdError):
      discard b.build()

suite "builder: layer flags":
  test "a hidden layer sets the hidden flag":
    var b = initPsdBuilder(4, 4)
    var spec = newLayerSpec("h", 0, 0, 4, 4, solid(4, 4, 1, 1, 1))
    spec.visible = false
    b.pushLayer(spec)
    check readPsd(b.toBytes()).layers()[0].flags.hidden

  test "clipping is stored as 1":
    var b = initPsdBuilder(4, 4)
    var spec = newLayerSpec("c", 0, 0, 4, 4, solid(4, 4, 1, 1, 1))
    spec.clipping = true
    b.pushLayer(spec)
    check readPsd(b.toBytes()).layers()[0].clipping == 1

  test "opacity is stored verbatim":
    var b = initPsdBuilder(4, 4)
    var spec = newLayerSpec("o", 0, 0, 4, 4, solid(4, 4, 1, 1, 1))
    spec.opacity = 128'u8
    b.pushLayer(spec)
    check readPsd(b.toBytes()).layers()[0].opacity == 128

  test "fill opacity writes an iOpa block":
    var b = initPsdBuilder(4, 4)
    var spec = newLayerSpec("f", 0, 0, 4, 4, solid(4, 4, 1, 1, 1))
    spec.fillOpacity = some(64'u8)
    b.pushLayer(spec)
    let l = readPsd(b.toBytes()).layers()[0]
    let blk = l.getBlock("iOpa").get()
    check blk.data.len == 4
    check blk.data.byteAt(0) == 64'u8

  test "no fill opacity means no iOpa block":
    check oneLayer().layers()[0].getBlock("iOpa").isNone

  test "an unusual blend mode survives":
    var b = initPsdBuilder(4, 4)
    var spec = newLayerSpec("m", 0, 0, 4, 4, solid(4, 4, 1, 1, 1))
    spec.blendMode = "mul "
    b.pushLayer(spec)
    check readPsd(b.toBytes()).layers()[0].blendMode == "mul "

  test "extra blocks are appended verbatim":
    var b = initPsdBuilder(4, 4)
    var spec = newLayerSpec("x", 0, 0, 4, 4, solid(4, 4, 1, 1, 1))
    spec.extraBlocks = @[boolBlock("clbl", true)]
    b.pushLayer(spec)
    check readPsd(b.toBytes()).layers()[0].getBlock("clbl").isSome

  test "a unicode name survives":
    var b = initPsdBuilder(4, 4)
    b.pushLayer(newLayerSpec("café ✓", 0, 0, 4, 4, solid(4, 4, 1, 1, 1)))
    check readPsd(b.toBytes()).layers()[0].name() == "café ✓"

  test "the legacy Pascal name is lossy but the luni block is not":
    # `LayerRecord.name` is the fixed legacy field, where anything outside
    # printable ASCII becomes '?'. The display name prefers `luni`.
    var b = initPsdBuilder(4, 4)
    b.pushLayer(newLayerSpec("café", 0, 0, 4, 4, solid(4, 4, 1, 1, 1)))
    let l = readPsd(b.toBytes()).layers()[0]
    check l.name == "caf??"   # five UTF-8 bytes, two non-ASCII
    check l.name() == "café"
    check l.getBlock("luni").isSome

suite "builder: masks":
  test "a mask adds a channel -2 and a mask record":
    var b = initPsdBuilder(8, 8)
    var spec = newLayerSpec("m", 0, 0, 8, 8, solid(8, 8, 1, 1, 1))
    spec.mask = some(newMaskSpec(Rect(top: 2, left: 2, bottom: 6, right: 6),
      newSeq[uint8](16), 0'u8))
    b.pushLayer(spec)
    let l = readPsd(b.toBytes()).layers()[0]
    check l.mask.kind == mdMask
    check l.mask.mask.rect == Rect(top: 2, left: 2, bottom: 6, right: 6)
    check l.channel(-2).isSome

  test "mask samples decode at the mask rect size":
    var b = initPsdBuilder(8, 8)
    var spec = newLayerSpec("m", 0, 0, 8, 8, solid(8, 8, 1, 1, 1))
    var data = newSeq[uint8](16)
    for i in 0 ..< 16:
      data[i] = uint8(i * 16)
    spec.mask = some(newMaskSpec(Rect(top: 2, left: 2, bottom: 6, right: 6), data))
    b.pushLayer(spec)
    let f = readPsd(b.toBytes())
    let plane = f.layers()[0].channel(-2).get().decode(4, 4, 8, Version.Psd)
    check plane.len == 16
    for i in 0 ..< 16:
      check ord(plane[i]) == i * 16

  test "a disabled mask sets the disabled flag":
    var b = initPsdBuilder(8, 8)
    var spec = newLayerSpec("m", 0, 0, 8, 8, solid(8, 8, 1, 1, 1))
    spec.mask = some(newMaskSpec(Rect(top: 0, left: 0, bottom: 4, right: 4),
      newSeq[uint8](16), 0'u8, true))
    b.pushLayer(spec)
    check readPsd(b.toBytes()).layers()[0].mask.mask.flags.disabled

  test "the default colour is stored":
    var b = initPsdBuilder(8, 8)
    var spec = newLayerSpec("m", 0, 0, 8, 8, solid(8, 8, 1, 1, 1))
    spec.mask = some(newMaskSpec(Rect(top: 0, left: 0, bottom: 4, right: 4),
      newSeq[uint8](16), 255'u8))
    b.pushLayer(spec)
    check readPsd(b.toBytes()).layers()[0].mask.mask.defaultColor == 255

  test "a 16-bit document scales the mask up to 16 bits":
    var b = initPsdBuilder(4, 4)
    b.setDepth(16)
    var spec = newLayerSpec("m", 0, 0, 4, 4, initRgba16(4, 4))
    var data = @[0'u8, 255'u8, 128'u8, 1'u8]
    spec.mask = some(newMaskSpec(Rect(top: 0, left: 0, bottom: 2, right: 2), data))
    b.pushLayer(spec)
    let f = readPsd(b.toBytes())
    let plane = f.layers()[0].channel(-2).get().decode(2, 2, 16, Version.Psd)
    check plane.len == 8
    for i, s in data:
      let got = (uint16(ord(plane[i * 2])) shl 8) or uint16(ord(plane[i * 2 + 1]))
      check got == uint16(s) * 257'u16

  test "a wrongly sized mask buffer raises":
    var b = initPsdBuilder(8, 8)
    var spec = newLayerSpec("m", 0, 0, 8, 8, solid(8, 8, 1, 1, 1))
    spec.mask = some(newMaskSpec(Rect(top: 0, left: 0, bottom: 4, right: 4),
      newSeq[uint8](9)))
    b.pushLayer(spec)
    expect(PsdError):
      discard b.build()

suite "builder: groups":
  test "a group writes four records for one inner layer":
    var b = initPsdBuilder(4, 4)
    b.beginGroup(newGroupSpec("grp"))
    b.pushLayer(newLayerSpec("inner", 0, 0, 4, 4, solid(4, 4, 255, 0, 0)))
    b.endGroup()
    b.pushLayer(newLayerSpec("outer", 0, 0, 4, 4, solid(4, 4, 0, 255, 0)))
    let f = readPsd(b.toBytes())
    check f.layers().len == 4

  test "the group's records carry the right lsct kinds":
    var b = initPsdBuilder(4, 4)
    b.beginGroup(newGroupSpec("grp"))
    b.pushLayer(newLayerSpec("inner", 0, 0, 4, 4, solid(4, 4, 255, 0, 0)))
    b.endGroup()
    let f = readPsd(b.toBytes())
    check f.layers()[0].getBlock("lsct").isSome
    check parseSectionDivider(f.layers()[0].getBlock("lsct").get().data).kind.kind ==
      stBoundingDivider
    let closing = parseSectionDivider(f.layers()[2].getBlock("lsct").get().data)
    check closing.kind.kind == stOpenFolder
    check closing.blendMode == "pass"
    check closing.hasBlendMode

  test "the opening record uses the fixed group name":
    var b = initPsdBuilder(4, 4)
    b.beginGroup(newGroupSpec("grp"))
    b.endGroup()
    check readPsd(b.toBytes()).layers()[0].name == "</Layer group>"

  test "the closing record carries the group's name":
    var b = initPsdBuilder(4, 4)
    b.beginGroup(newGroupSpec("my group"))
    b.endGroup()
    check readPsd(b.toBytes()).layers()[1].name == "my group"

  test "a closed group writes stClosedFolder":
    var b = initPsdBuilder(4, 4)
    var g = newGroupSpec("g")
    g.open = false
    b.beginGroup(g)
    b.endGroup()
    let f = readPsd(b.toBytes())
    check parseSectionDivider(f.layers()[1].getBlock("lsct").get().data).kind.kind ==
      stClosedFolder

  test "divider records have no channel data":
    var b = initPsdBuilder(4, 4)
    b.beginGroup(newGroupSpec("g"))
    b.endGroup()
    for l in readPsd(b.toBytes()).layers():
      for c in l.channels:
        check c.compression.isNone
        check c.data.len == 0

  test "nested groups nest correctly":
    var b = initPsdBuilder(4, 4)
    b.beginGroup(newGroupSpec("outer"))
    b.pushLayer(newLayerSpec("a", 0, 0, 4, 4, solid(4, 4, 1, 1, 1)))
    b.beginGroup(newGroupSpec("inner"))
    b.pushLayer(newLayerSpec("b", 0, 0, 4, 4, solid(4, 4, 2, 2, 2)))
    b.endGroup()
    b.endGroup()
    let tree = readPsd(b.toBytes()).layerTree()
    check tree.len == 1
    check tree[0].kind == lnGroup
    check tree[0].layer.name == "outer"
    check tree[0].children.len == 2

  test "an unbalanced group raises":
    var b = initPsdBuilder(4, 4)
    b.beginGroup(newGroupSpec("g"))
    expect(PsdError):
      discard b.build()

  test "endGroup without beginGroup raises":
    var b = initPsdBuilder(4, 4)
    expect(PsdError):
      b.endGroup()

  test "a hidden group sets the hidden flag":
    var b = initPsdBuilder(4, 4)
    var g = newGroupSpec("g")
    g.visible = false
    b.beginGroup(g)
    b.endGroup()
    check readPsd(b.toBytes()).layers()[1].flags.hidden

suite "builder: resources and compression":
  test "a resolution resource round-trips":
    var b = initPsdBuilder(4, 4)
    b.addResolution(300.0)
    let f = readPsd(b.toBytes())
    check abs(f.resolution().get().hRes() - 300.0) < 0.01

  test "an ICC profile round-trips":
    var b = initPsdBuilder(4, 4)
    b.addIccProfile("fake profile bytes")
    check readPsd(b.toBytes()).iccProfile() == "fake profile bytes"

  test "raw compression is honoured":
    var b = initPsdBuilder(8, 8)
    b.setCompression(Raw)
    b.pushLayer(newLayerSpec("r", 0, 0, 8, 8, gradient(8, 8)))
    let f = readPsd(b.toBytes())
    check f.layers()[0].channels[1].compression == some(Raw)
    # raw 8-bit RGB plane is exactly width * height bytes
    check f.layers()[0].channels[1].data.len == 64

  test "zip compression is honoured":
    var b = initPsdBuilder(8, 8)
    b.setCompression(Zip)
    b.pushLayer(newLayerSpec("z", 0, 0, 8, 8, gradient(8, 8)))
    check readPsd(b.toBytes()).layers()[0].channels[1].compression == some(Zip)

suite "builder: validation":
  test "a pixel buffer of the wrong depth raises":
    var b = initPsdBuilder(4, 4)
    b.setDepth(16)
    b.pushLayer(newLayerSpec("x", 0, 0, 4, 4, solid(4, 4, 1, 1, 1)))
    expect(PsdError):
      discard b.build()

  test "a pixel buffer of the wrong colour mode raises":
    var b = initPsdBuilder(4, 4)
    b.setColorMode(ColorMode(kind: cmGrayscale))
    b.pushLayer(newLayerSpec("x", 0, 0, 4, 4, solid(4, 4, 1, 1, 1)))
    expect(PsdError):
      discard b.build()

  test "a wrongly sized pixel buffer raises":
    var b = initPsdBuilder(4, 4)
    b.pushLayer(newLayerSpec("x", 0, 0, 4, 4, solid(8, 8, 1, 1, 1)))
    expect(PsdError):
      discard b.build()

  test "a composite of the wrong size raises":
    var b = initPsdBuilder(4, 4)
    b.setComposite(solid(8, 8, 1, 1, 1))
    expect(PsdError):
      discard b.build()

  test "a layer may be smaller than the canvas":
    var b = initPsdBuilder(64, 64)
    b.pushLayer(newLayerSpec("small", 0, 0, 8, 8, solid(8, 8, 1, 1, 1)))
    b.setComposite(solid(64, 64, 0, 0, 0))
    let f = readPsd(b.toBytes())
    check f.layers()[0].rect.width() == 8
    check f.width == 64

suite "builder: byte stability":
  test "a built file re-serializes to the same bytes":
    var b = initPsdBuilder(16, 16)
    b.addResolution(72.0)
    b.pushLayer(newLayerSpec("a", 0, 0, 16, 16, gradient(16, 16)))
    b.setComposite(gradient(16, 16))
    let bytes = b.toBytes()
    check writePsd(readPsd(bytes)) == bytes

  test "grouped and masked files re-serialize identically":
    var b = initPsdBuilder(8, 8)
    b.beginGroup(newGroupSpec("g"))
    var spec = newLayerSpec("inner", 1, 1, 4, 4, gradient(4, 4))
    spec.mask = some(newMaskSpec(Rect(top: 0, left: 0, bottom: 4, right: 4),
      newSeq[uint8](16)))
    b.pushLayer(spec)
    b.endGroup()
    let bytes = b.toBytes()
    check writePsd(readPsd(bytes)) == bytes

  test "CMYK and PSB files re-serialize identically":
    var b = initPsbBuilder(4, 4)
    b.setColorMode(ColorMode(kind: cmCmyk))
    b.pushLayer(newLayerSpec("c", 0, 0, 4, 4, initCmyka8(4, 4)))
    let bytes = b.toBytes()
    check writePsd(readPsd(bytes)) == bytes

  test "a 16-bit file re-serializes identically":
    var b = initPsdBuilder(4, 4)
    b.setDepth(16)
    b.pushLayer(newLayerSpec("hi", 0, 0, 4, 4, initRgba16(4, 4)))
    let bytes = b.toBytes()
    check writePsd(readPsd(bytes)) == bytes

suite "pixel data: helpers":
  test "the init helpers size the buffer correctly":
    check initRgba8(3, 2).sampleCount() == 24
    check initRgba16(3, 2).sampleCount() == 24
    check initGrayA8(3, 2).sampleCount() == 12
    check initGrayA16(3, 2).sampleCount() == 12
    check initCmyka8(3, 2).sampleCount() == 30
    check initCmyka16(3, 2).sampleCount() == 30

  test "each variant reports its mode and depth":
    check initRgba8(1, 1).colorMode().kind == cmRgb
    check initGrayA8(1, 1).colorMode().kind == cmGrayscale
    check initCmyka8(1, 1).colorMode().kind == cmCmyk
    check initRgba8(1, 1).depth() == 8
    check initRgba16(1, 1).depth() == 16

  test "colorChannels counts ink planes":
    check colorChannels(ColorMode(kind: cmRgb)) == 3
    check colorChannels(ColorMode(kind: cmGrayscale)) == 1
    check colorChannels(ColorMode(kind: cmCmyk)) == 4

  test "plane extraction de-interleaves":
    var p = initRgba8(2, 1)
    p.rgba8 = @[10'u8, 11'u8, 12'u8, 255'u8, 20'u8, 21'u8, 22'u8, 255'u8]
    check p.plane(0, 2) == "\x0A\x14"
    check p.plane(1, 2) == "\x0B\x15"
    check p.plane(2, 2) == "\x0C\x16"
    check p.plane(3, 2) == "\xFF\xFF"

  test "16-bit planes are big-endian":
    var p = initRgba16(1, 1)
    p.rgba16 = @[0x1234'u16, 0'u16, 0'u16, 0xFFFF'u16]
    check p.plane(0, 1) == "\x12\x34"

  test "alphaIsOpaque detects a single non-opaque sample":
    var p = initRgba8(3, 1)
    p.rgba8 = @[1'u8, 1'u8, 1'u8, 255'u8,
                2'u8, 2'u8, 2'u8, 255'u8,
                3'u8, 3'u8, 3'u8, 254'u8]
    check not p.alphaIsOpaque(3)

  test "an empty buffer counts as opaque":
    check initRgba8(0, 0).alphaIsOpaque(0)