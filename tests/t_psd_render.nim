import unittest
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/layers
import ../src/opengraphics/psd/pixels
import ../src/opengraphics/psd/render
import ./psd_support

proc solid(name: string, r, g, b: byte, w = 2, h = 2,
    blendKey = "norm", opacity = 255'u8, flags = 0'u8,
    clipping = 0'u8, alpha: seq[byte] = @[]): TestLayerSpec =
  var planes = @[newSeq[byte](w * h), newSeq[byte](w * h),
    newSeq[byte](w * h)]
  for i in 0 ..< w * h:
    planes[0][i] = r
    planes[1][i] = g
    planes[2][i] = b
  var ids = @[int16(0), 1, 2]
  if alpha.len > 0:
    planes.add(alpha)
    ids.add(int16(-1))
  TestLayerSpec(name: name, top: 0, left: 0, bottom: int32(h),
    right: int32(w), planes: planes, channelIds: ids, useRle: false,
    blendKey: blendKey, opacity: opacity, clipping: clipping,
    flags: flags, lsct: -1, lsdk: -1)

proc docOf(specs: seq[TestLayerSpec], w = 2, h = 2): Document =
  let p = newSeq[byte](w * h)
  readPsdBytes(buildPsd(w, h, 3, @[p, p, p], layers = specs))

test "single opaque layer renders its pixels":
  let doc = docOf(@[solid("red", 255, 0, 0)])
  let img = renderDocument(doc)
  check img.width == 2
  check img.height == 2
  for px in img.data:
    check px == Rgba(r: 255, g: 0, b: 0, a: 255)

test "canvas stays transparent outside layer rects":
  var s = solid("dot", 255, 255, 255)
  s.bottom = 1
  s.right = 1
  s.planes = @[@[byte(255)], @[byte(255)], @[byte(255)]]
  let img = docOf(@[s]).renderDocument()
  check img.getPixel(0, 0) == Rgba(r: 255, g: 255, b: 255, a: 255)
  check img.getPixel(1, 0).a == 0
  check img.getPixel(0, 1).a == 0
  check img.getPixel(1, 1).a == 0

test "normal stacking applies opacity":
  # red at 128 over opaque blue: r = 255*128/255 = 128,
  # b = 255 - 255*128/255 = 127
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    solid("red", 255, 0, 0, opacity = 128),
  ])
  let img = renderDocument(doc)
  check img.getPixel(0, 0) == Rgba(r: 128, g: 0, b: 127, a: 255)

test "zero opacity paints nothing":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    solid("red", 255, 0, 0, opacity = 0),
  ])
  check renderDocument(doc).getPixel(1, 1) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

test "invisible layer is skipped":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    solid("red", 255, 0, 0, flags = 2),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

test "bottom-first file order wins ties":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    solid("red", 255, 0, 0),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "blend formulas pin exact values":
  check blendChannel(Multiply, 128, 128) == 64
  check blendChannel(Screen, 128, 128) == 192
  check blendChannel(Darken, 200, 100) == 100
  check blendChannel(Lighten, 100, 200) == 200
  check blendChannel(Difference, 200, 100) == 100
  check blendChannel(Overlay, 200, 100) == 156
  check blendChannel(Exclusion, 200, 100) == 144
  check blendChannel(ColorBurn, 200, 100) == 58
  check blendChannel(LinearBurn, 200, 100) == 45
  check blendChannel(ColorDodge, 200, 100) == 255
  check blendChannel(LinearDodge, 200, 100) == 255
  check blendChannel(HardMix, 200, 100) == 255
  check blendChannel(Subtract, 200, 100) == 0
  check blendChannel(Divide, 200, 100) == 127
  check blendChannel(HardLight, 200, 100) == 189
  check blendChannel(SoftLight, 200, 100) == 134
  check blendChannel(VividLight, 200, 100) == 231
  check blendChannel(LinearLight, 200, 100) == 245
  check blendChannel(PinLight, 200, 100) == 144
  check blendChannel(ColorBurn, 0, 100) == 0
  check blendChannel(ColorDodge, 255, 100) == 255
  check blendChannel(Divide, 0, 100) == 255

test "blend keys map, unknown falls back to normal":
  check blendModeFromKey("norm") == Normal
  check blendModeFromKey("dark") == Darken
  check blendModeFromKey("mul ") == Multiply
  check blendModeFromKey("idiv") == ColorBurn
  check blendModeFromKey("lbrn") == LinearBurn
  check blendModeFromKey("lite") == Lighten
  check blendModeFromKey("scrn") == Screen
  check blendModeFromKey("div ") == ColorDodge
  check blendModeFromKey("lddg") == LinearDodge
  check blendModeFromKey("over") == Overlay
  check blendModeFromKey("sLit") == SoftLight
  check blendModeFromKey("hLit") == HardLight
  check blendModeFromKey("vLit") == VividLight
  check blendModeFromKey("lLit") == LinearLight
  check blendModeFromKey("pLit") == PinLight
  check blendModeFromKey("hMix") == HardMix
  check blendModeFromKey("diff") == Difference
  check blendModeFromKey("smud") == Exclusion
  check blendModeFromKey("fsub") == Subtract
  check blendModeFromKey("fdiv") == Divide
  check blendModeFromKey("diss") == Normal
  check blendModeFromKey("hue ") == Normal
  check blendModeFromKey("xxxx") == Normal

test "multiply layer blends through the stack":
  # 128 gray multiplied over 128 gray: 128*128/255 = 64
  let doc = docOf(@[
    solid("base", 128, 128, 128),
    solid("top", 128, 128, 128, blendKey = "mul "),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 64, g: 64, b: 64, a: 255)

test "clipped layer paints only over its base":
  var base = solid("base", 255, 0, 0)
  base.bottom = 1
  base.right = 1
  base.planes = @[@[byte(255)], @[byte(0)], @[byte(0)]]
  let clipped = solid("clip", 0, 255, 0, clipping = 1)
  let img = docOf(@[base, clipped]).renderDocument()
  check img.getPixel(0, 0) == Rgba(r: 0, g: 255, b: 0, a: 255)
  check img.getPixel(1, 0).a == 0
  check img.getPixel(1, 1).a == 0

test "mask default 0 hides the layer":
  var s = solid("hid", 255, 0, 0)
  s.mask = TestMaskSpec(present: true, top: 0, left: 0, bottom: 2,
    right: 2, defaultColor: 0, flags: 0)
  let img = docOf(@[s]).renderDocument()
  for px in img.data:
    check px.a == 0

test "mask pixels modulate alpha":
  var s = solid("part", 255, 0, 0)
  s.mask = TestMaskSpec(present: true, top: 0, left: 0, bottom: 1,
    right: 2, defaultColor: 0, flags: 0)
  s.planes.add(@[byte(255), 0])
  s.channelIds.add(int16(-2))
  let img = docOf(@[s]).renderDocument()
  check img.getPixel(0, 0) == Rgba(r: 255, g: 0, b: 0, a: 255)
  check img.getPixel(1, 0).a == 0
  # second row is outside the mask rect: default 0 hides it
  check img.getPixel(0, 1).a == 0

test "group opacity folds into children":
  # file order: blue base, divider, red child, folder at 128
  var divMark = solid("div", 0, 0, 0)
  divMark.top = 0
  divMark.left = 0
  divMark.bottom = 0
  divMark.right = 0
  divMark.planes = @[]
  divMark.channelIds = @[]
  divMark.lsct = 3
  var folder = divMark
  folder.name = "grp"
  folder.opacity = 128
  folder.lsct = 1
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    divMark,
    solid("red", 255, 0, 0),
    folder,
  ])
  # red at effective 128 over blue == the opacity test above
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 128, g: 0, b: 127, a: 255)

test "invisible group renders nothing":
  var divMark = solid("div", 0, 0, 0)
  divMark.top = 0
  divMark.left = 0
  divMark.bottom = 0
  divMark.right = 0
  divMark.planes = @[]
  divMark.channelIds = @[]
  divMark.lsct = 3
  var folder = divMark
  folder.name = "grp"
  folder.flags = 2
  folder.lsct = 1
  let doc = docOf(@[
    divMark,
    solid("red", 255, 0, 0),
    folder,
  ])
  for px in renderDocument(doc).data:
    check px.a == 0

test "layer alpha channel composites":
  # top white at alpha 128 over opaque blue:
  # mix = 128, r = g = 255*128/255 = 128, b stays 255
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    solid("white", 255, 255, 255,
      alpha = @[byte(128), 128, 128, 128]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 128, g: 128, b: 255, a: 255)

test "renderToComposite replaces stored pixels":
  var doc = docOf(@[solid("red", 255, 0, 0)])
  doc.renderToComposite()
  check doc.hasComposite
  check doc.compositeCompression == Raw
  check doc.composite.getPixel(1, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "real fixture render tracks stored composite":
  let doc = openPsd("tests/data/01.psd")
  let img = renderDocument(doc)
  check img.width == 700
  check img.height == 700
  var opaque = 0
  var same = 0
  for i in 0 ..< img.data.len:
    if img.data[i].a == 255:
      inc opaque
    let a = img.data[i]
    let b = doc.composite.data[i]
    if a.r == b.r and a.g == b.g and a.b == b.b:
      inc same
  check opaque == img.data.len
  check same > 400000 # ~98% exact; text effects account for the rest
  check img.getPixel(0, 0) == doc.composite.getPixel(0, 0)
