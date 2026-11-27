import std/math
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

# --- exposure -------------------------------------------------------------

proc f32be(v: float32): seq[byte] =
  let bits = cast[uint32](v)
  @[byte(bits shr 24), byte((bits shr 16) and 0xFF),
    byte((bits shr 8) and 0xFF), byte(bits and 0xFF)]

proc expPayload(e, o, g: float32): seq[byte] =
  ## `expA`: 2 version bytes, then exposure, offset, gamma as f32BE.
  result = adjBytesU16(1)
  result.add(f32be(e))
  result.add(f32be(o))
  result.add(f32be(g))

test "exposure identity leaves the backdrop alone":
  let doc = docOf(@[
    solid("gray", 128, 128, 128),
    adjLayer("ex", "expA", expPayload(0, 0, 1)),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 128, g: 128, b: 128, a: 255)

test "exposure offset matches the measured oracle":
  # Photoshop corpus via the reference: offset 0.1738 lifts 76 to 134.
  let doc = docOf(@[
    solid("gray", 76, 76, 76),
    adjLayer("ex", "expA", expPayload(0, 0.1738, 1)),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 134, g: 134, b: 134, a: 255)

test "exposure plus one stop brightens mid gray":
  let doc = docOf(@[
    solid("gray", 128, 128, 128),
    adjLayer("ex", "expA", expPayload(1, 0, 1)),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 175, g: 175, b: 175, a: 255)

test "exposure gamma darkens through linear light":
  let doc = docOf(@[
    solid("gray", 128, 128, 128),
    adjLayer("ex", "expA", expPayload(0, 0, 2)),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 181, g: 181, b: 181, a: 255)

test "exposure keeps black black and clamps white":
  let c = expPayload(1, 0, 1)
  check renderDocument(docOf(@[solid("blk", 0, 0, 0),
    adjLayer("ex", "expA", c)])).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 0, a: 255)
  check renderDocument(docOf(@[solid("wht", 255, 255, 255),
    adjLayer("ex", "expA", c)])).getPixel(0, 0) ==
    Rgba(r: 255, g: 255, b: 255, a: 255)

test "exposure truncated stays transparent":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("ex", "expA", @[byte(0), 1]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

# --- channel mixer --------------------------------------------------------

proc mixPayload(mono: uint16, rows: array[3, array[5, int16]]): seq[byte] =
  ## `mixr`: version + mono flag, then three rows of five i16 (slot 3 is the
  ## unused black slot, slot 4 the constant), all in percent.
  result = adjBytesU16(1) & adjBytesU16(mono)
  for row in rows:
    for v in row:
      result.add(adjBytesI16(v))

const
  mixIdentity = [[100'i16, 0, 0, 0, 0], [0'i16, 100, 0, 0, 0],
    [0'i16, 0, 100, 0, 0]]
  mixSwapRB = [[0'i16, 0, 100, 0, 0], [0'i16, 100, 0, 0, 0],
    [100'i16, 0, 0, 0, 0]]
  mixLuma = [[30'i16, 59, 11, 0, 0], [0'i16, 0, 0, 0, 0], [0'i16, 0, 0, 0, 0]]

test "mixer identity leaves the backdrop alone":
  let doc = docOf(@[
    solid("red", 255, 0, 0),
    adjLayer("mx", "mixr", mixPayload(0, mixIdentity)),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "mixer swaps red and blue":
  let doc = docOf(@[
    solid("red", 255, 0, 0),
    adjLayer("mx", "mixr", mixPayload(0, mixSwapRB)),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

test "mixer mono maps red to luma gray":
  # 30% of 255 = 76.5, just above halfway, so 77.
  let doc = docOf(@[
    solid("red", 255, 0, 0),
    adjLayer("mx", "mixr", mixPayload(1, mixLuma)),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 77, g: 77, b: 77, a: 255)

test "mixer truncated stays transparent":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("mx", "mixr", @[byte(0), 1]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

# --- black and white --------------------------------------------------------

proc blwhPayload(weights: array[6, float64], tint: seq[float64] = @[]): seq[byte] =
  ## `blwh`: versioned descriptor with the six channel weights, `useTint`
  ## and an optional `tintColor` in RGBC doubles 0..255.
  var d = newDescriptor("null")
  const keys = ["Rd  ", "Yllw", "Grn ", "Cyn ", "Bl  ", "Mgnt"]
  for i, k in keys:
    discard d.add(k, doubleValue(weights[i]))
  if tint.len == 3:
    var t = newDescriptor("RGBC")
    discard t.add("Rd  ", doubleValue(tint[0]))
    discard t.add("Grn ", doubleValue(tint[1]))
    discard t.add("Bl  ", doubleValue(tint[2]))
    discard d.add("tintColor", descriptorValue(t))
    discard d.add("useTint", boolValue(true))
  else:
    discard d.add("useTint", boolValue(false))
  var w = initWriter()
  w.putU32(16)
  w.writeDescriptorBody(d)
  let s = w.toString()
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

test "blackwhite maps red and yellow to their grays":
  # Defaults 40/60/40/60/20/80: red -> 40% of 255, yellow -> 60%.
  let c = blwhPayload([40.0, 60, 40, 60, 20, 80])
  check renderDocument(docOf(@[solid("red", 255, 0, 0),
    adjLayer("bw", "blwh", c)])).getPixel(0, 0) ==
    Rgba(r: 102, g: 102, b: 102, a: 255)
  check renderDocument(docOf(@[solid("ylw", 255, 255, 0),
    adjLayer("bw", "blwh", c)])).getPixel(0, 0) ==
    Rgba(r: 153, g: 153, b: 153, a: 255)

test "blackwhite keeps gray gray":
  let c = blwhPayload([40.0, 60, 40, 60, 20, 80])
  check renderDocument(docOf(@[solid("gray", 128, 128, 128),
    adjLayer("bw", "blwh", c)])).getPixel(0, 0) ==
    Rgba(r: 128, g: 128, b: 128, a: 255)

test "blackwhite tint takes the tint hue at the gray":
  let c = blwhPayload([40.0, 60, 40, 60, 20, 80], @[225.0, 211, 179])
  check renderDocument(docOf(@[solid("gray", 128, 128, 128),
    adjLayer("bw", "blwh", c)])).getPixel(0, 0) ==
    Rgba(r: 141, g: 127, b: 95, a: 255)

test "blackwhite truncated stays transparent":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("bw", "blwh", @[byte(0), 1]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

# --- photo filter -----------------------------------------------------------

proc phflPayload(color: array[3, uint16], density: uint32,
    preserve: bool): seq[byte] =
  ## `phfl` v2: RGB space, 3x u16 comps, 2 pad bytes, u32 percent density,
  ## u8 preserve flag.
  result = adjBytesU16(2) & adjBytesU16(0)
  for c in color:
    result.add(adjBytesU16(c))
  result.add(adjBytesU16(0))
  result.add(@[byte(density shr 24), byte((density shr 16) and 0xFF),
    byte((density shr 8) and 0xFF), byte(density and 0xFF)])
  result.add(if preserve: byte(1) else: byte(0))

proc u16comp(v: int): uint16 =
  ## 8-bit channel to the 0..65535 space the v2 block stores.
  uint16(v * 65535 div 255)

test "photofilter density zero is identity":
  let c = phflPayload([u16comp(255), u16comp(200), u16comp(100)], 0, false)
  check renderDocument(docOf(@[solid("red", 255, 0, 0),
    adjLayer("pf", "phfl", c)])).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "photofilter warming gel tints white to the gel":
  # At full density white becomes the filter color itself.
  let c = phflPayload([u16comp(255), u16comp(200), u16comp(100)], 100, false)
  check renderDocument(docOf(@[solid("wht", 255, 255, 255),
    adjLayer("pf", "phfl", c)])).getPixel(0, 0) ==
    Rgba(r: 255, g: 200, b: 100, a: 255)

test "photofilter warming gel on blue and red":
  # Cross-checked against an independent transcription of the reference
  # matrix (sRGB transfer, D50 XYZ, SetLum off).
  let c = phflPayload([u16comp(255), u16comp(200), u16comp(100)], 100, false)
  check renderDocument(docOf(@[solid("blu", 0, 0, 255),
    adjLayer("pf", "phfl", c)])).getPixel(0, 0) ==
    Rgba(r: 119, g: 0, b: 122, a: 255)
  let c25 = phflPayload([u16comp(255), u16comp(200), u16comp(100)], 25, false)
  check renderDocument(docOf(@[solid("red", 255, 0, 0),
    adjLayer("pf", "phfl", c25)])).getPixel(0, 0) ==
    Rgba(r: 247, g: 0, b: 0, a: 255)

test "photofilter preserve keeps the luminosity":
  let c = phflPayload([u16comp(255), u16comp(200), u16comp(100)], 100, true)
  check renderDocument(docOf(@[solid("gray", 128, 128, 128),
    adjLayer("pf", "phfl", c)])).getPixel(0, 0) ==
    Rgba(r: 154, g: 125, b: 72, a: 255)

test "photofilter truncated stays transparent":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("pf", "phfl", @[byte(0), 1]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

# --- gradient map -----------------------------------------------------------

proc grdmPayload(rev, dither: bool,
    stops: seq[tuple[pos: float64, rgb: array[3, int]]]): seq[byte] =
  ## `grdm` v1: rev/dither flags, empty name, then stops as u32 location
  ## (pos * 4096), 4 reserved bytes, RGB space, 4x u16 comps, 2 pad bytes.
  result = adjBytesU16(1)
  result.add(if rev: byte(1) else: byte(0))
  result.add(if dither: byte(1) else: byte(0))
  result.add(@[byte(0), 0, 0, 0]) # empty name
  result.add(adjBytesU16(uint16(stops.len)))
  for s in stops:
    let loc = uint32(round(s.pos * 4096.0))
    result.add(@[byte(loc shr 24), byte((loc shr 16) and 0xFF),
      byte((loc shr 8) and 0xFF), byte(loc and 0xFF)])
    result.add(@[byte(0), 0, 0, 0])
    result.add(adjBytesU16(0))
    for v in [s.rgb[0], s.rgb[1], s.rgb[2], 0]:
      result.add(adjBytesU16(u16comp(v)))
    result.add(@[byte(0), 0])

test "gradientmap black-white follows luminosity":
  # Red sits at exactly 76.5: Rust/Nim round half away from zero, so 77.
  let c = grdmPayload(false, false, @[(0.0, [0, 0, 0]), (1.0, [255, 255, 255])])
  check renderDocument(docOf(@[solid("gray", 128, 128, 128),
    adjLayer("gm", "grdm", c)])).getPixel(0, 0) ==
    Rgba(r: 128, g: 128, b: 128, a: 255)
  check renderDocument(docOf(@[solid("red", 255, 0, 0),
    adjLayer("gm", "grdm", c)])).getPixel(0, 0) ==
    Rgba(r: 77, g: 77, b: 77, a: 255)

test "gradientmap reverse flips the ramp":
  let c = grdmPayload(true, false, @[(0.0, [0, 0, 0]), (1.0, [255, 255, 255])])
  check renderDocument(docOf(@[solid("gray", 128, 128, 128),
    adjLayer("gm", "grdm", c)])).getPixel(0, 0) ==
    Rgba(r: 127, g: 127, b: 127, a: 255)

test "gradientmap white-black inverts by luminosity":
  let c = grdmPayload(false, false, @[(0.0, [255, 255, 255]), (1.0, [0, 0, 0])])
  check renderDocument(docOf(@[solid("blu", 0, 0, 255),
    adjLayer("gm", "grdm", c)])).getPixel(0, 0) ==
    Rgba(r: 227, g: 227, b: 227, a: 255)

test "gradientmap dither splits a half level across pixels":
  # Red sits at exactly 76.5, so dither-off rounds to 77 everywhere, while
  # dither-on drops the (0,0) Bayer cell to 76 and keeps (1,0) at 77.
  let plain = grdmPayload(false, false, @[(0.0, [0, 0, 0]), (1.0, [255, 255, 255])])
  let plainImg = renderDocument(docOf(@[solid("red", 255, 0, 0),
    adjLayer("gm", "grdm", plain)]))
  check plainImg.getPixel(0, 0) == Rgba(r: 77, g: 77, b: 77, a: 255)
  check plainImg.getPixel(1, 0) == Rgba(r: 77, g: 77, b: 77, a: 255)
  let dith = grdmPayload(false, true, @[(0.0, [0, 0, 0]), (1.0, [255, 255, 255])])
  let img = renderDocument(docOf(@[solid("red", 255, 0, 0),
    adjLayer("gm", "grdm", dith)]))
  check img.getPixel(0, 0) == Rgba(r: 76, g: 76, b: 76, a: 255)
  check img.getPixel(1, 0) == Rgba(r: 77, g: 77, b: 77, a: 255)

test "gradientmap file order does not matter":
  let c = grdmPayload(false, false, @[(1.0, [255, 255, 255]), (0.0, [0, 0, 0])])
  check renderDocument(docOf(@[solid("gray", 128, 128, 128),
    adjLayer("gm", "grdm", c)])).getPixel(0, 0) ==
    Rgba(r: 128, g: 128, b: 128, a: 255)

test "gradientmap bad version stays transparent":
  var c = grdmPayload(false, false, @[(0.0, [0, 0, 0]), (1.0, [255, 255, 255])])
  c[0] = 0
  c[1] = 2 # version 2
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("gm", "grdm", c),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

# --- color balance --------------------------------------------------------

proc blncPayload(shadows, midtones, highlights: array[3, int16],
    preserve: bool): seq[byte] =
  ## `blnc`: three tones of three i16 (-100..100), then a preserve byte.
  result = @[]
  for tone in [shadows, midtones, highlights]:
    for v in tone:
      result.add(adjBytesI16(v))
  result.add(if preserve: byte(1) else: byte(0))

test "balance zeros leave the backdrop alone":
  let c = blncPayload([0'i16, 0, 0], [0'i16, 0, 0], [0'i16, 0, 0], false)
  check renderDocument(docOf(@[solid("red", 255, 0, 0),
    adjLayer("cb", "blnc", c)])).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "balance midtones red lifts the red ramp":
  # Photoshop oracle: midtones +50 maps gray 64 to 96 and gray 128 to 156;
  # the 128 point sits on a .5 rounding boundary (float32 vs float64 land
  # on different sides), so it pins within the reference's own +/-1.
  let c = blncPayload([0'i16, 0, 0], [50'i16, 0, 0], [0'i16, 0, 0], false)
  check renderDocument(docOf(@[solid("lo", 64, 64, 64),
    adjLayer("cb", "blnc", c)])).getPixel(0, 0) ==
    Rgba(r: 96, g: 64, b: 64, a: 255)
  let px = renderDocument(docOf(@[solid("mid", 128, 128, 128),
    adjLayer("cb", "blnc", c)])).getPixel(0, 0)
  check abs(int(px.r) - 156) <= 1
  check px.g == 128
  check px.b == 128

test "balance shadows and highlights move the ends":
  # Photoshop oracles: shadows -100 maps gray 128 to red 23, highlights
  # +100 maps it to 223; green is untouched in both.
  let sh = blncPayload([-100'i16, 0, 0], [0'i16, 0, 0], [0'i16, 0, 0], false)
  check renderDocument(docOf(@[solid("mid", 128, 128, 128),
    adjLayer("cb", "blnc", sh)])).getPixel(0, 0) ==
    Rgba(r: 23, g: 128, b: 128, a: 255)
  let hi = blncPayload([0'i16, 0, 0], [0'i16, 0, 0], [100'i16, 0, 0], false)
  check renderDocument(docOf(@[solid("mid", 128, 128, 128),
    adjLayer("cb", "blnc", hi)])).getPixel(0, 0) ==
    Rgba(r: 223, g: 128, b: 128, a: 255)

test "balance preserve luminosity rebalances across channels":
  # Measured: shadows red and blue +50 darken only green, 128 to 97.
  let c = blncPayload([50'i16, 0, 50], [0'i16, 0, 0], [0'i16, 0, 0], true)
  check renderDocument(docOf(@[solid("mid", 128, 128, 128),
    adjLayer("cb", "blnc", c)])).getPixel(0, 0) ==
    Rgba(r: 128, g: 97, b: 128, a: 255)

test "balance truncated stays transparent":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("cb", "blnc", @[byte(0), 1, 2, 3]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

# --- selective color ----------------------------------------------------------

proc selcPayload(relative: bool,
    rows: array[9, array[4, int16]]): seq[byte] =
  ## `selc`: version 1, method (0 relative), 8 reserved bytes, then nine
  ## rows of four i16 (cyan, magenta, yellow, black) in percent.
  result = adjBytesU16(1) & adjBytesU16(if relative: 0 else: 1)
  result.add(@[byte(0), 0, 0, 0, 0, 0, 0, 0])
  for row in rows:
    for v in row:
      result.add(adjBytesI16(v))

proc selcRows(range: int, vals: array[4, int16]): array[9, array[4, int16]] =
  for i in 0 ..< 9:
    result[i] = [0'i16, 0, 0, 0]
  result[range] = vals

test "selective zeros leave the backdrop alone":
  let c = selcPayload(false, selcRows(7, [0'i16, 0, 0, 0]))
  check renderDocument(docOf(@[solid("red", 255, 0, 0),
    adjLayer("sc", "selc", c)])).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "selective absolute neutrals cyan matches the oracle":
  # Measured: neutrals cyan +50 maps gray 64 to red 32, gray 192 to 129.
  let c = selcPayload(false, selcRows(7, [50'i16, 0, 0, 0]))
  check renderDocument(docOf(@[solid("lo", 64, 64, 64),
    adjLayer("sc", "selc", c)])).getPixel(0, 0) ==
    Rgba(r: 32, g: 64, b: 64, a: 255)
  check renderDocument(docOf(@[solid("hi", 192, 192, 192),
    adjLayer("sc", "selc", c)])).getPixel(0, 0) ==
    Rgba(r: 129, g: 192, b: 192, a: 255)

test "selective relative and absolute part ways on gray":
  # Same neutrals cyan +50 on gray 128: absolute inks to near-black red,
  # relative scales by the ink present and barely moves.
  let abs = selcPayload(false, selcRows(7, [50'i16, 0, 0, 0]))
  check renderDocument(docOf(@[solid("mid", 128, 128, 128),
    adjLayer("sc", "selc", abs)])).getPixel(0, 0) ==
    Rgba(r: 1, g: 128, b: 128, a: 255)
  let rel = selcPayload(true, selcRows(7, [50'i16, 0, 0, 0]))
  check renderDocument(docOf(@[solid("mid", 128, 128, 128),
    adjLayer("sc", "selc", rel)])).getPixel(0, 0) ==
    Rgba(r: 65, g: 128, b: 128, a: 255)

test "selective truncated stays transparent":
  let doc = docOf(@[
    solid("blue", 0, 0, 255),
    adjLayer("sc", "selc", @[byte(0), 1, 2, 3]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)
