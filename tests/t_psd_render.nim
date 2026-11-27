import unittest
import ../src/opengraphics/psd
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
  check blendChannel(bmMultiply, 128, 128) == 64
  check blendChannel(bmScreen, 128, 128) == 192
  check blendChannel(bmDarken, 200, 100) == 100
  check blendChannel(bmLighten, 100, 200) == 200
  check blendChannel(bmDifference, 200, 100) == 100
  check blendChannel(bmOverlay, 200, 100) == 156
  check blendChannel(bmExclusion, 200, 100) == 144
  check blendChannel(bmColorBurn, 200, 100) == 58
  check blendChannel(bmLinearBurn, 200, 100) == 45
  check blendChannel(bmColorDodge, 200, 100) == 255
  check blendChannel(bmLinearDodge, 200, 100) == 255
  check blendChannel(bmHardMix, 200, 100) == 255
  check blendChannel(bmSubtract, 200, 100) == 0
  check blendChannel(bmDivide, 200, 100) == 127
  check blendChannel(bmHardLight, 200, 100) == 189
  # W3C SoftLight: Cs > 0.5 and Cb > 0.25, so the result is sqrt(Cb), which is
  # 159.7. The old approximation of the formula gave 134.
  check blendChannel(bmSoftLight, 200, 100) == 160
  check blendChannel(bmVividLight, 200, 100) == 231
  check blendChannel(bmLinearLight, 200, 100) == 245
  # W3C PinLight: Cs > 0.5 gives max(Cb, 2Cs - 1) = max(100, 145). The old
  # 2*(Cs - 128) was off by one, being 2Cs - 256.
  check blendChannel(bmPinLight, 200, 100) == 145
  check blendChannel(bmColorBurn, 0, 100) == 0
  check blendChannel(bmColorDodge, 255, 100) == 255
  check blendChannel(bmDivide, 0, 100) == 255

test "blend keys map, unknown falls back to normal":
  check blendModeFromKey("norm") == bmNormal
  check blendModeFromKey("dark") == bmDarken
  check blendModeFromKey("mul ") == bmMultiply
  check blendModeFromKey("idiv") == bmColorBurn
  check blendModeFromKey("lbrn") == bmLinearBurn
  check blendModeFromKey("lite") == bmLighten
  check blendModeFromKey("scrn") == bmScreen
  check blendModeFromKey("div ") == bmColorDodge
  check blendModeFromKey("lddg") == bmLinearDodge
  check blendModeFromKey("over") == bmOverlay
  check blendModeFromKey("sLit") == bmSoftLight
  check blendModeFromKey("hLit") == bmHardLight
  check blendModeFromKey("vLit") == bmVividLight
  check blendModeFromKey("lLit") == bmLinearLight
  check blendModeFromKey("pLit") == bmPinLight
  check blendModeFromKey("hMix") == bmHardMix
  check blendModeFromKey("diff") == bmDifference
  check blendModeFromKey("smud") == bmExclusion
  check blendModeFromKey("fsub") == bmSubtract
  check blendModeFromKey("fdiv") == bmDivide
  check blendModeFromKey("diss") == bmDissolve
  check blendModeFromKey("hue ") == bmHue
  check blendModeFromKey("sat ") == bmSaturation
  check blendModeFromKey("colr") == bmColor
  check blendModeFromKey("lum ") == bmLuminosity
  check blendModeFromKey("dkCl") == bmDarkerColor
  check blendModeFromKey("lgCl") == bmLighterColor
  check blendModeFromKey("pass") == bmPassThrough
  # only genuinely unknown keys fall back now
  check blendModeFromKey("xxxx") == bmNormal

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
  check doc.file.imageData.compression == Raw
  check doc.compositeImage().getPixel(1, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "real fixture render tracks stored composite":
  let doc = openPsd("tests/data/01.psd")
  let img = renderDocument(doc)
  # Hoist both buffers out of the loop: calling `compositeImage` per pixel
  # copies the whole ImageBuf value 490000 times.
  let rendered = img.data
  let stored = doc.compositeImage().data
  check img.width == 700
  check img.height == 700
  var opaque = 0
  var same = 0
  for i in 0 ..< rendered.len:
    if rendered[i].a == 255:
      inc opaque
    let a = rendered[i]
    let b = stored[i]
    if a.r == b.r and a.g == b.g and a.b == b.b:
      inc same
  check opaque == img.data.len
  check same > 400000 # ~98% exact; text effects account for the rest
  check img.getPixel(0, 0) == doc.compositeImage().getPixel(0, 0)

# --- adjustment layers as live adjustments -----------------------------------

proc adjBytesU16(v: uint16): seq[byte] =
  @[byte(v shr 8), byte(v and 0xFF)]

proc adjBytesI16(v: int16): seq[byte] =
  adjBytesU16(cast[uint16](v))

proc adjLayer(name, key: string, payload: seq[byte], opacity = 255'u8,
    clipping = 0'u8): TestLayerSpec =
  TestLayerSpec(name: name, top: 0, left: 0, bottom: 2, right: 2,
    planes: @[], channelIds: @[], useRle: false, blendKey: "norm",
    opacity: opacity, clipping: clipping, flags: 0, lsct: -1, lsdk: -1,
    extra: @[(key, payload)])

proc identityLevl(): seq[byte] =
  result = adjBytesU16(0)
  for _ in 0 ..< 5: # master + 3 channels + black, all 0..255 gamma 100
    for v in [0'u16, 255, 0, 255, 100]:
      result.add(adjBytesU16(v))

test "invert adjustment flips the backdrop":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("inv", "nvrt", @[]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 255, b: 0, a: 255)

test "invert at half opacity blends":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("inv", "nvrt", @[], opacity = 128),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 128, g: 128, b: 127, a: 255)

test "threshold splits on luminosity":
  let lo = adjBytesU16(200) & adjBytesU16(0)
  let hi = adjBytesU16(100) & adjBytesU16(0)
  let gray128 = solid("gray", 128, 128, 128)
  check renderDocument(docOf(@[gray128,
    adjLayer("th-lo", "thrs", lo)])).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 0, a: 255)
  check renderDocument(docOf(@[gray128,
    adjLayer("th-hi", "thrs", hi)])).getPixel(0, 0) ==
    Rgba(r: 255, g: 255, b: 255, a: 255)

test "posterize levels 2 pushes mid gray white, dark stays black":
  let p2 = adjBytesU16(2) & adjBytesU16(0)
  check renderDocument(docOf(@[solid("mid", 128, 128, 128),
    adjLayer("p", "post", p2)])).getPixel(0, 0) ==
    Rgba(r: 255, g: 255, b: 255, a: 255)
  check renderDocument(docOf(@[solid("dark", 64, 64, 64),
    adjLayer("p", "post", p2)])).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 0, a: 255)

test "identity levels leaves the backdrop alone":
  let doc = docOf(@[
    solid("red", 255, 0, 0),
    adjLayer("lv", "levl", identityLevl()),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "legacy brightness lifts gray by the slider":
  let brit = adjBytesI16(40) & adjBytesI16(0)
  let doc = docOf(@[
    solid("gray", 128, 128, 128),
    adjLayer("bc", "brit", brit),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 168, g: 168, b: 168, a: 255)

test "unsupported adjustment stays transparent":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("vib", "vibA", @[byte(1), 2, 3]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

test "adjustment at zero opacity does nothing":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("inv", "nvrt", @[], opacity = 0),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

# --- curves ---------------------------------------------------------------

proc curvU16(v: uint16): seq[byte] =
  adjBytesU16(v)

proc curvPayload(pencil: int, version: uint16, bits: uint32,
    curves: seq[seq[tuple[o, i: uint16]]] = @[],
    maps: seq[seq[byte]] = @[]): seq[byte] =
  ## Non-pencil curves as (output, input) pairs; pencil as 256-byte maps.
  result = @[byte(pencil)]
  result.add(adjBytesU16(version))
  result.add(@[byte(bits shr 24), byte((bits shr 16) and 0xFF),
    byte((bits shr 8) and 0xFF), byte(bits and 0xFF)])
  if pencil != 0:
    for m in maps:
      result.add(m)
  else:
    for pts in curves:
      result.add(curvU16(uint16(pts.len)))
      for p in pts:
        result.add(curvU16(p.o))
        result.add(curvU16(p.i))

test "curves identity leaves the backdrop alone":
  let c = curvPayload(0, 1, 0)
  let doc = docOf(@[
    solid("red", 255, 0, 0),
    adjLayer("cv", "curv", c),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "curves master invert flips the backdrop":
  let c = curvPayload(0, 1, 1, @[@[(o: 255'u16, i: 0'u16), (o: 0'u16, i: 255'u16)]])
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("cv", "curv", c),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 255, b: 0, a: 255)

test "curves red channel zeroed kills red":
  let ident = @[(o: 0'u16, i: 0'u16), (o: 255'u16, i: 255'u16)]
  let zero = @[(o: 0'u16, i: 0'u16), (o: 0'u16, i: 255'u16)]
  let c = curvPayload(0, 1, 3, @[ident, zero])
  let doc = docOf(@[
    solid("red", 255, 0, 0),
    adjLayer("cv", "curv", c),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 0, a: 255)

test "curves pencil identity leaves the backdrop alone":
  var m: seq[byte] = @[]
  for i in 0 ..< 256:
    m.add(byte(i))
  let c = curvPayload(1, 1, 1, maps = @[m])
  let doc = docOf(@[
    solid("red", 255, 0, 0),
    adjLayer("cv", "curv", c),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "curves endpoints pin black and white":
  # S-curve through (0,0), (128,192), (255,255): ends are exact, and the
  # midpoints pin the spline shape (cross-checked against an independent
  # transcription of the reference natural spline: 108 and 236).
  let pts = @[(o: 0'u16, i: 0'u16), (o: 192'u16, i: 128'u16),
    (o: 255'u16, i: 255'u16)]
  let c = curvPayload(0, 1, 1, @[pts])
  check renderDocument(docOf(@[solid("blk", 0, 0, 0),
    adjLayer("cv", "curv", c)])).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 0, a: 255)
  check renderDocument(docOf(@[solid("wht", 255, 255, 255),
    adjLayer("cv", "curv", c)])).getPixel(0, 0) ==
    Rgba(r: 255, g: 255, b: 255, a: 255)
  check renderDocument(docOf(@[solid("lo", 64, 64, 64),
    adjLayer("cv", "curv", c)])).getPixel(0, 0) ==
    Rgba(r: 108, g: 108, b: 108, a: 255)
  check renderDocument(docOf(@[solid("hi", 192, 192, 192),
    adjLayer("cv", "curv", c)])).getPixel(0, 0) ==
    Rgba(r: 236, g: 236, b: 236, a: 255)

test "curves bad version stays transparent":
  let c = curvPayload(0, 2, 1, @[@[(o: 255'u16, i: 0'u16)]])
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("cv", "curv", c),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)
