## Drop-shadow compositing: offset, spread, blur, knockout, blend.
##
## Synthetic layers with hand-built `lfx2` descriptors (the writer grammar
## from `t_psd_effects`); expectations come from an independent transcription
## of the reference map math (see `/tmp/shadow_oracle.py` during development).

import std/unittest
import ../src/opengraphics/psd
import ./psd_support

proc spanBytes(s: Span): seq[byte] =
  let t = s.clone
  result = newSeq[byte](t.len)
  for i, c in t: result[i] = byte(c)

proc pxLayer(name: string, top, left, bottom, right: int32,
    r, g, b: byte, a: byte = 255,
    extra: seq[tuple[key: string, payload: seq[byte]]] = @[]): TestLayerSpec =
  let w = int(right - left)
  let h = int(bottom - top)
  var planes = @[newSeq[byte](w * h), newSeq[byte](w * h),
    newSeq[byte](w * h)]
  for i in 0 ..< w * h:
    planes[0][i] = r
    planes[1][i] = g
    planes[2][i] = b
  var ids = @[int16(0), 1, 2]
  if a != 255:
    planes.add(newSeq[byte](w * h))
    for i in 0 ..< w * h: planes[3][i] = a
    ids.add(int16(-1))
  TestLayerSpec(name: name, top: top, left: left, bottom: bottom,
    right: right, planes: planes, channelIds: ids, useRle: false,
    blendKey: "norm", opacity: 255, clipping: 0, flags: 0, lsct: -1,
    lsdk: -1, extra: extra)

proc shadowFx(angle, dist, size, spread: float64,
    color: array[3, float64], opacity = 100.0, blend = "Nrml",
    enabled = true, master = true): seq[byte] =
  var sh = newDescriptor("DrSh")
  discard sh.add("enab", boolValue(enabled))
  discard sh.add("Md  ", enumValue("BlnM", blend))
  discard sh.add("Opct", unitFloatValue("#Prc", opacity))
  discard sh.add("Angl", doubleValue(angle))
  discard sh.add("Dstn", doubleValue(dist))
  discard sh.add("blur", doubleValue(size))
  discard sh.add("Ckmt", doubleValue(spread * 100.0))
  var clr = newDescriptor("RGBC")
  discard clr.add("Rd  ", doubleValue(color[0]))
  discard clr.add("Grn ", doubleValue(color[1]))
  discard clr.add("Bl  ", doubleValue(color[2]))
  discard sh.add("Clr ", descriptorValue(clr))
  discard sh.add("useGlobalAngle", boolValue(false))
  var top = newDescriptor("null")
  if not master:
    discard top.add("masterFXSwitch", boolValue(false))
  discard top.add("DrSh", descriptorValue(sh))
  var w = initWriter()
  w.putU32(0)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  spanBytes(Span(src: newStringSource(s), start: 0, stop: s.len))

proc docOfFx(specs: seq[TestLayerSpec], w = 2, h = 1): Document =
  let p = newSeq[byte](w * h)
  readPsdBytes(buildPsd(w, h, 3, @[p, p, p], layers = specs))

test "hard offset shadow lands beside the layer":
  # Angle 180, distance 1: shadow one pixel right, size 0 blurs nothing.
  let fx = shadowFx(180, 1, 0, 0, [0.0, 0, 0])
  let doc = docOfFx(@[pxLayer("blk", 0, 0, 1, 1, 0, 0, 0,
    extra = @[("lfx2", fx)])], 3, 1)
  let img = renderDocument(doc)
  check img.getPixel(0, 0) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(1, 0) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(2, 0).a == 0

test "multiply shadow blends with the backdrop":
  # Red shadow over a blue base multiplies to black; a normal one stays red.
  let fx = shadowFx(180, 1, 0, 0, [255.0, 0, 0], blend = "Mltp")
  let doc = docOfFx(@[
    pxLayer("blue", 0, 0, 1, 2, 0, 0, 255),
    pxLayer("wht", 0, 0, 1, 1, 255, 255, 255, extra = @[("lfx2", fx)]),
  ])
  let img = renderDocument(doc)
  check img.getPixel(1, 0) == Rgba(r: 0, g: 0, b: 0, a: 255)

test "tinted shadow keeps its color":
  let fx = shadowFx(180, 1, 0, 0, [255.0, 0, 0])
  let doc = docOfFx(@[
    pxLayer("wht", 0, 0, 1, 1, 255, 255, 255, extra = @[("lfx2", fx)]),
  ])
  check renderDocument(doc).getPixel(1, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "knockout cuts the shadow under translucent pixels":
  # White at alpha 128 with a black contact shadow: the shadow is cut by
  # the shape, then the layer blends over, giving (205,205,205,159).
  let fx = shadowFx(180, 0, 0, 0, [0.0, 0, 0])
  let doc = docOfFx(@[
    pxLayer("wht", 0, 0, 1, 1, 255, 255, 255, 128,
      extra = @[("lfx2", fx)]),
  ])
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 205, g: 205, b: 205, a: 159)

test "blurred shadow falls off with distance":
  let fx = shadowFx(180, 0, 4, 0, [0.0, 0, 0])
  var specs = @[pxLayer("blk", 2, 2, 3, 3, 0, 0, 0,
    extra = @[("lfx2", fx)])]
  let doc = docOfFx(specs, 5, 5)
  let img = renderDocument(doc)
  check img.getPixel(2, 2) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(3, 2) == Rgba(r: 0, g: 0, b: 0, a: 10)
  check img.getPixel(4, 2) == Rgba(r: 0, g: 0, b: 0, a: 7)
  check img.getPixel(2, 1) == Rgba(r: 0, g: 0, b: 0, a: 10)
  check img.getPixel(1, 1) == Rgba(r: 0, g: 0, b: 0, a: 9)

test "spread grows the shape before blurring":
  # Size 2 at full spread dilates by 2 with no blur: a 5x5 block.
  let fx = shadowFx(180, 0, 2, 1, [0.0, 0, 0])
  let doc = docOfFx(@[pxLayer("blk", 3, 3, 4, 4, 0, 0, 0,
    extra = @[("lfx2", fx)])], 7, 7)
  let img = renderDocument(doc)
  check img.getPixel(3, 3) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(1, 1) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(0, 0).a == 0

test "disabled shadow paints nothing":
  let fx = shadowFx(180, 1, 0, 0, [0.0, 0, 0], enabled = false)
  let doc = docOfFx(@[pxLayer("blk", 0, 0, 1, 1, 0, 0, 0,
    extra = @[("lfx2", fx)])], 3, 1)
  check renderDocument(doc).getPixel(1, 0).a == 0

test "master switch off paints nothing":
  let fx = shadowFx(180, 1, 0, 0, [0.0, 0, 0], master = false)
  let doc = docOfFx(@[pxLayer("blk", 0, 0, 1, 1, 0, 0, 0,
    extra = @[("lfx2", fx)])], 3, 1)
  check renderDocument(doc).getPixel(1, 0).a == 0
