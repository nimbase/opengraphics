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
  discard sh.add("lagl", doubleValue(angle))
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

# --- outer glow -----------------------------------------------------------------

proc glowFx(size, spread, rng: float64, color: array[3, float64],
    opacity = 100.0, blend = "", precise = false,
    gradient = false): seq[byte] =
  var gl = newDescriptor("OrGl")
  discard gl.add("enab", boolValue(true))
  if blend.len > 0:
    discard gl.add("Md  ", enumValue("BlnM", blend))
  if opacity >= 0.0:
    discard gl.add("Opct", unitFloatValue("#Prc", opacity))
  discard gl.add("blur", doubleValue(size))
  discard gl.add("Ckmt", doubleValue(spread * 100.0))
  discard gl.add("Inpr", doubleValue(rng * 100.0))
  if precise:
    discard gl.add("GlwT", enumValue("GlwT", "PrBL"))
  var clr = newDescriptor("RGBC")
  discard clr.add("Rd  ", doubleValue(color[0]))
  discard clr.add("Grn ", doubleValue(color[1]))
  discard clr.add("Bl  ", doubleValue(color[2]))
  discard gl.add("Clr ", descriptorValue(clr))
  if gradient:
    discard gl.add("Grad", descriptorValue(newDescriptor("Grad")))
  var top = newDescriptor("null")
  discard top.add("OrGl", descriptorValue(gl))
  var w = initWriter()
  w.putU32(0)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  spanBytes(Span(src: newStringSource(s), start: 0, stop: s.len))

test "outer glow hugs the shape":
  let fx = glowFx(2, 0, 0.5, [0.0, 0, 0], blend = "Nrml")
  let doc = docOfFx(@[pxLayer("blk", 2, 2, 3, 3, 0, 0, 0,
    extra = @[("lfx2", fx)])], 5, 5)
  let img = renderDocument(doc)
  check img.getPixel(2, 2) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(1, 2) == Rgba(r: 0, g: 0, b: 0, a: 17)
  check img.getPixel(3, 2) == Rgba(r: 0, g: 0, b: 0, a: 17)
  check img.getPixel(2, 1) == Rgba(r: 0, g: 0, b: 0, a: 17)
  check img.getPixel(0, 0).a == 0

test "outer glow spread reaches further":
  let fx = glowFx(4, 0.5, 0.5, [0.0, 0, 0], blend = "Nrml")
  let doc = docOfFx(@[pxLayer("blk", 3, 3, 4, 4, 0, 0, 0,
    extra = @[("lfx2", fx)])], 7, 7)
  let img = renderDocument(doc)
  check img.getPixel(3, 3) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(4, 3) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(5, 3) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(6, 3) == Rgba(r: 0, g: 0, b: 0, a: 159)

test "screen glow blends with the backdrop":
  # Same soft edge as the black glow (coverage 17/255): screened over blue
  # at that strength gives dim magenta, opaque.
  let fx = glowFx(2, 0, 0.5, [255.0, 0, 0], blend = "Scrn")
  let doc = docOfFx(@[
    pxLayer("blue", 0, 0, 1, 2, 0, 0, 255),
    pxLayer("wht", 0, 0, 1, 1, 255, 255, 255, extra = @[("lfx2", fx)]),
  ])
  check renderDocument(doc).getPixel(1, 0) ==
    Rgba(r: 17, g: 0, b: 255, a: 255)

test "glow defaults to screen at 75 percent":
  # No Md/Opct keys: the reference defaults apply and the neighbor glows.
  let fx = glowFx(2, 0, 0.5, [0.0, 0, 0], opacity = -1.0)
  let doc = docOfFx(@[pxLayer("blk", 0, 0, 1, 1, 0, 0, 0,
    extra = @[("lfx2", fx)])], 3, 1)
  check renderDocument(doc).getPixel(1, 0).a > 0

test "precise glow stays unpainted":
  let fx = glowFx(2, 0, 0.5, [0.0, 0, 0], blend = "Nrml", precise = true)
  let doc = docOfFx(@[pxLayer("blk", 0, 0, 1, 1, 0, 0, 0,
    extra = @[("lfx2", fx)])], 3, 1)
  check renderDocument(doc).getPixel(1, 0).a == 0

test "gradient glow stays unpainted":
  let fx = glowFx(2, 0, 0.5, [0.0, 0, 0], blend = "Nrml", gradient = true)
  let doc = docOfFx(@[pxLayer("blk", 0, 0, 1, 1, 0, 0, 0,
    extra = @[("lfx2", fx)])], 3, 1)
  check renderDocument(doc).getPixel(1, 0).a == 0

test "disabled glow paints nothing":
  var gl = newDescriptor("OrGl")
  discard gl.add("enab", boolValue(false))
  var top = newDescriptor("null")
  discard top.add("OrGl", descriptorValue(gl))
  var w = initWriter()
  w.putU32(0)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  let fx = spanBytes(Span(src: newStringSource(s), start: 0, stop: s.len))
  let doc = docOfFx(@[pxLayer("blk", 0, 0, 1, 1, 0, 0, 0,
    extra = @[("lfx2", fx)])], 3, 1)
  check renderDocument(doc).getPixel(1, 0).a == 0

# --- color overlay --------------------------------------------------------------

proc overlayFx(color: array[3, float64], opacity = 100.0,
    blend = "Nrml", enabled = true, master = true): seq[byte] =
  var so = newDescriptor("SoFi")
  discard so.add("enab", boolValue(enabled))
  discard so.add("Md  ", enumValue("BlnM", blend))
  discard so.add("Opct", unitFloatValue("#Prc", opacity))
  var clr = newDescriptor("RGBC")
  discard clr.add("Rd  ", doubleValue(color[0]))
  discard clr.add("Grn ", doubleValue(color[1]))
  discard clr.add("Bl  ", doubleValue(color[2]))
  discard so.add("Clr ", descriptorValue(clr))
  var top = newDescriptor("null")
  if not master:
    discard top.add("masterFXSwitch", boolValue(false))
  discard top.add("SoFi", descriptorValue(so))
  var w = initWriter()
  w.putU32(0)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  spanBytes(Span(src: newStringSource(s), start: 0, stop: s.len))

proc overlayMulti(items: seq[Descriptor]): seq[byte] =
  var top = newDescriptor("null")
  var vals: seq[Value] = @[]
  for it in items:
    vals.add(descriptorValue(it))
  discard top.add("solidFillMulti", listValue(vals))
  var w = initWriter()
  w.putU32(0)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  spanBytes(Span(src: newStringSource(s), start: 0, stop: s.len))

proc overlayItem(color: array[3, float64], opacity = 100.0,
    blend = "Nrml"): Descriptor =
  var so = newDescriptor("SoFi")
  discard so.add("enab", boolValue(true))
  discard so.add("Md  ", enumValue("BlnM", blend))
  discard so.add("Opct", unitFloatValue("#Prc", opacity))
  var clr = newDescriptor("RGBC")
  discard clr.add("Rd  ", doubleValue(color[0]))
  discard clr.add("Grn ", doubleValue(color[1]))
  discard clr.add("Bl  ", doubleValue(color[2]))
  discard so.add("Clr ", descriptorValue(clr))
  so

test "color overlay replaces opaque pixels":
  let fx = overlayFx([0.0, 0, 255])
  let doc = docOfFx(@[pxLayer("red", 0, 0, 1, 1, 255, 0, 0,
    extra = @[("lfx2", fx)])], 1, 1)
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 255)

test "color overlay scales with its opacity":
  let fx = overlayFx([0.0, 0, 255], 50.0)
  let doc = docOfFx(@[pxLayer("red", 0, 0, 1, 1, 255, 0, 0,
    extra = @[("lfx2", fx)])], 1, 1)
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 127, g: 0, b: 128, a: 255)

test "color overlay keeps the layer alpha":
  let fx = overlayFx([0.0, 0, 255])
  let doc = docOfFx(@[pxLayer("red", 0, 0, 1, 1, 255, 0, 0, 128,
    extra = @[("lfx2", fx)])], 1, 1)
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 255, a: 128)

test "color overlay blends with its mode":
  let fx = overlayFx([0.0, 0, 0], blend = "Mltp")
  let doc = docOfFx(@[pxLayer("red", 0, 0, 1, 1, 255, 0, 0,
    extra = @[("lfx2", fx)])], 1, 1)
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 0, g: 0, b: 0, a: 255)

test "first listed overlay paints on top":
  let fx = overlayMulti(@[overlayItem([255.0, 0, 0]),
    overlayItem([0.0, 0, 255])])
  let doc = docOfFx(@[pxLayer("wht", 0, 0, 1, 1, 255, 255, 255,
    extra = @[("lfx2", fx)])], 1, 1)
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "disabled overlay paints nothing":
  let fx = overlayFx([0.0, 0, 255], enabled = false)
  let doc = docOfFx(@[pxLayer("red", 0, 0, 1, 1, 255, 0, 0,
    extra = @[("lfx2", fx)])], 1, 1)
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

test "overlay master switch off paints nothing":
  let fx = overlayFx([0.0, 0, 255], master = false)
  let doc = docOfFx(@[pxLayer("red", 0, 0, 1, 1, 255, 0, 0,
    extra = @[("lfx2", fx)])], 1, 1)
  check renderDocument(doc).getPixel(0, 0) ==
    Rgba(r: 255, g: 0, b: 0, a: 255)

# --- inner glow ---------------------------------------------------------------

proc innerGlowFx(size, spread, rng: float64, color: array[3, float64],
    opacity = 100.0, blend = "Nrml", center = false,
    precise = false, gradient = false, enabled = true): seq[byte] =
  var gl = newDescriptor("IrGl")
  discard gl.add("enab", boolValue(enabled))
  discard gl.add("Md  ", enumValue("BlnM", blend))
  discard gl.add("Opct", unitFloatValue("#Prc", opacity))
  discard gl.add("blur", doubleValue(size))
  discard gl.add("Ckmt", doubleValue(spread * 100.0))
  discard gl.add("Inpr", doubleValue(rng * 100.0))
  if center:
    discard gl.add("glwS", enumValue("glwS", "SrcC"))
  if precise:
    discard gl.add("GlwT", enumValue("GlwT", "PrBL"))
  var clr = newDescriptor("RGBC")
  discard clr.add("Rd  ", doubleValue(color[0]))
  discard clr.add("Grn ", doubleValue(color[1]))
  discard clr.add("Bl  ", doubleValue(color[2]))
  discard gl.add("Clr ", descriptorValue(clr))
  if gradient:
    discard gl.add("Grad", descriptorValue(newDescriptor("Grad")))
  var top = newDescriptor("null")
  discard top.add("IrGl", descriptorValue(gl))
  var w = initWriter()
  w.putU32(0)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  spanBytes(Span(src: newStringSource(s), start: 0, stop: s.len))

test "inner glow burns inward from the edge":
  let fx = innerGlowFx(2, 0, 0.5, [255.0, 0, 0])
  let doc = docOfFx(@[pxLayer("wht", 1, 1, 4, 4, 255, 255, 255,
    extra = @[("lfx2", fx)])], 5, 5)
  let img = renderDocument(doc)
  check img.getPixel(2, 2) == Rgba(r: 255, g: 135, b: 135, a: 255)
  check img.getPixel(2, 1) == Rgba(r: 255, g: 84, b: 84, a: 255)
  check img.getPixel(1, 1) == Rgba(r: 255, g: 48, b: 48, a: 255)
  check img.getPixel(0, 0).a == 0

test "inner glow center source burns outward":
  let fx = innerGlowFx(2, 0, 0.5, [255.0, 0, 0], center = true)
  let doc = docOfFx(@[pxLayer("wht", 1, 1, 4, 4, 255, 255, 255,
    extra = @[("lfx2", fx)])], 5, 5)
  let img = renderDocument(doc)
  check img.getPixel(2, 2) == Rgba(r: 255, g: 120, b: 120, a: 255)
  check img.getPixel(2, 1) == Rgba(r: 255, g: 171, b: 171, a: 255)

test "inner glow size one uses the narrow falloff":
  let fx = innerGlowFx(1, 0, 0.5, [255.0, 0, 0])
  let doc = docOfFx(@[pxLayer("wht", 1, 1, 4, 4, 255, 255, 255,
    extra = @[("lfx2", fx)])], 5, 5)
  let img = renderDocument(doc)
  check img.getPixel(2, 2) == Rgba(r: 255, g: 255, b: 255, a: 255)
  check img.getPixel(2, 1) == Rgba(r: 255, g: 127, b: 127, a: 255)

test "inner glow precise stays unpainted":
  let fx = innerGlowFx(2, 0, 0.5, [255.0, 0, 0], precise = true)
  let doc = docOfFx(@[pxLayer("wht", 1, 1, 4, 4, 255, 255, 255,
    extra = @[("lfx2", fx)])], 5, 5)
  check renderDocument(doc).getPixel(2, 1) ==
    Rgba(r: 255, g: 255, b: 255, a: 255)

test "inner glow gradient stays unpainted":
  let fx = innerGlowFx(2, 0, 0.5, [255.0, 0, 0], gradient = true)
  let doc = docOfFx(@[pxLayer("wht", 1, 1, 4, 4, 255, 255, 255,
    extra = @[("lfx2", fx)])], 5, 5)
  check renderDocument(doc).getPixel(2, 1) ==
    Rgba(r: 255, g: 255, b: 255, a: 255)

test "disabled inner glow paints nothing":
  let fx = innerGlowFx(2, 0, 0.5, [255.0, 0, 0], enabled = false)
  let doc = docOfFx(@[pxLayer("wht", 1, 1, 4, 4, 255, 255, 255,
    extra = @[("lfx2", fx)])], 5, 5)
  check renderDocument(doc).getPixel(2, 1) ==
    Rgba(r: 255, g: 255, b: 255, a: 255)

# --- inner shadow ---------------------------------------------------------------

proc innerShadowFx(angle, dist, size, spread: float64,
    color: array[3, float64], opacity = 100.0, blend = "Nrml",
    enabled = true): seq[byte] =
  var sh = newDescriptor("IrSh")
  discard sh.add("enab", boolValue(enabled))
  discard sh.add("Md  ", enumValue("BlnM", blend))
  discard sh.add("Opct", unitFloatValue("#Prc", opacity))
  discard sh.add("lagl", doubleValue(angle))
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
  discard top.add("IrSh", descriptorValue(sh))
  var w = initWriter()
  w.putU32(0)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  spanBytes(Span(src: newStringSource(s), start: 0, stop: s.len))

test "inner shadow size one darkens the edge pixel":
  # Photoshop oracle: size 1 darkens the first pixel inside every edge to
  # G 96 on orange, leaving the next pixel at 128. Wide layer so the
  # probed edge is straight.
  let fx = innerShadowFx(0, 0, 1, 0, [0.0, 0, 0])
  let doc = docOfFx(@[pxLayer("org", 1, 1, 4, 9, 255, 128, 0,
    extra = @[("lfx2", fx)])], 9, 5)
  let img = renderDocument(doc)
  check img.getPixel(4, 1) == Rgba(r: 191, g: 96, b: 0, a: 255)
  check img.getPixel(4, 2) == Rgba(r: 255, g: 128, b: 0, a: 255)
  check img.getPixel(1, 1) == Rgba(r: 143, g: 72, b: 0, a: 255)

test "inner shadow size three ramps inward":
  # Measured: 85, 114, 128 going in from a straight edge. The layer sits
  # clear of the canvas edge so the blur reach reads real shape, not the
  # canvas boundary.
  let fx = innerShadowFx(0, 0, 3, 0, [0.0, 0, 0])
  let doc = docOfFx(@[pxLayer("org", 3, 1, 9, 12, 255, 128, 0,
    extra = @[("lfx2", fx)])], 15, 11)
  let img = renderDocument(doc)
  check img.getPixel(6, 3) == Rgba(r: 170, g: 86, b: 0, a: 255)
  check img.getPixel(6, 4) == Rgba(r: 227, g: 114, b: 0, a: 255)
  check img.getPixel(6, 5) == Rgba(r: 255, g: 128, b: 0, a: 255)

test "inner shadow distance pushes a hard band":
  # Size 0 keeps the hard band: distance 2 darkens two rows, then clean.
  let fx = innerShadowFx(90, 2, 0, 0, [0.0, 0, 0])
  let doc = docOfFx(@[pxLayer("wht", 1, 1, 8, 4, 255, 255, 255,
    extra = @[("lfx2", fx)])], 5, 11)
  let img = renderDocument(doc)
  check img.getPixel(2, 1) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(2, 2) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(2, 3) == Rgba(r: 255, g: 255, b: 255, a: 255)
  check img.getPixel(1, 4) == Rgba(r: 255, g: 255, b: 255, a: 255)
  check img.getPixel(3, 4) == Rgba(r: 255, g: 255, b: 255, a: 255)
  check img.getPixel(2, 7) == Rgba(r: 255, g: 255, b: 255, a: 255)

test "disabled inner shadow paints nothing":
  let fx = innerShadowFx(0, 0, 1, 0, [0.0, 0, 0], enabled = false)
  let doc = docOfFx(@[pxLayer("org", 1, 1, 6, 4, 255, 128, 0,
    extra = @[("lfx2", fx)])], 7, 5)
  check renderDocument(doc).getPixel(3, 1) ==
    Rgba(r: 255, g: 128, b: 0, a: 255)

# --- stroke ---------------------------------------------------------------------

proc strokeFx(size: float64, pos, blend: string, color: array[3, float64],
    opacity = 100.0, gradient = false, pattern = false,
    enabled = true): seq[byte] =
  var fr = newDescriptor("FrFX")
  discard fr.add("enab", boolValue(enabled))
  discard fr.add("Md  ", enumValue("BlnM", blend))
  discard fr.add("Opct", unitFloatValue("#Prc", opacity))
  discard fr.add("Sz  ", doubleValue(size))
  discard fr.add("Styl", enumValue("Styl", pos))
  if gradient:
    discard fr.add("PntT", enumValue("FrFl", "GrFl"))
    discard fr.add("Grad", descriptorValue(newDescriptor("Grad")))
  elif pattern:
    discard fr.add("PntT", enumValue("FrFl", "Ptrn"))
    discard fr.add("Ptrn", descriptorValue(newDescriptor("Ptrn")))
  else:
    discard fr.add("PntT", enumValue("FrFl", "SClr"))
  var clr = newDescriptor("RGBC")
  discard clr.add("Rd  ", doubleValue(color[0]))
  discard clr.add("Grn ", doubleValue(color[1]))
  discard clr.add("Bl  ", doubleValue(color[2]))
  discard fr.add("Clr ", descriptorValue(clr))
  var top = newDescriptor("null")
  discard top.add("FrFX", descriptorValue(fr))
  var w = initWriter()
  w.putU32(0)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  spanBytes(Span(src: newStringSource(s), start: 0, stop: s.len))

test "outside stroke rings the shape":
  let fx = strokeFx(2, "Outs", "Nrml", [0.0, 0, 0])
  let doc = docOfFx(@[pxLayer("blk", 3, 3, 4, 4, 0, 0, 0,
    extra = @[("lfx2", fx)])], 7, 7)
  let img = renderDocument(doc)
  check img.getPixel(3, 3) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(1, 1) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(5, 5) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(0, 0).a == 0
  check img.getPixel(6, 3).a == 0

test "inside stroke fills inward from the edge":
  let fx = strokeFx(2, "InsF", "Nrml", [255.0, 0, 0])
  let doc = docOfFx(@[pxLayer("wht", 1, 1, 8, 8, 255, 255, 255,
    extra = @[("lfx2", fx)])], 9, 9)
  let img = renderDocument(doc)
  check img.getPixel(4, 1) == Rgba(r: 255, g: 0, b: 0, a: 255)
  check img.getPixel(4, 2) == Rgba(r: 255, g: 0, b: 0, a: 255)
  check img.getPixel(4, 3) == Rgba(r: 255, g: 255, b: 255, a: 255)

test "center stroke straddles the edge":
  let fx = strokeFx(2, "CtrF", "Nrml", [0.0, 0, 0])
  let doc = docOfFx(@[pxLayer("blk", 3, 3, 4, 4, 0, 0, 0,
    extra = @[("lfx2", fx)])], 7, 7)
  let img = renderDocument(doc)
  check img.getPixel(3, 3) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(2, 2) == Rgba(r: 0, g: 0, b: 0, a: 255)
  check img.getPixel(1, 1).a == 0

test "gradient stroke stays unpainted":
  let fx = strokeFx(2, "Outs", "Nrml", [0.0, 0, 0], gradient = true)
  let doc = docOfFx(@[pxLayer("blk", 3, 3, 4, 4, 0, 0, 0,
    extra = @[("lfx2", fx)])], 7, 7)
  check renderDocument(doc).getPixel(1, 1).a == 0

test "pattern stroke stays unpainted":
  let fx = strokeFx(2, "Outs", "Nrml", [0.0, 0, 0], pattern = true)
  let doc = docOfFx(@[pxLayer("blk", 3, 3, 4, 4, 0, 0, 0,
    extra = @[("lfx2", fx)])], 7, 7)
  check renderDocument(doc).getPixel(1, 1).a == 0

test "disabled stroke paints nothing":
  var fr = newDescriptor("FrFX")
  discard fr.add("enab", boolValue(false))
  var top = newDescriptor("null")
  discard top.add("FrFX", descriptorValue(fr))
  var w = initWriter()
  w.putU32(0)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  let fx = spanBytes(Span(src: newStringSource(s), start: 0, stop: s.len))
  let doc = docOfFx(@[pxLayer("blk", 3, 3, 4, 4, 0, 0, 0,
    extra = @[("lfx2", fx)])], 7, 7)
  check renderDocument(doc).getPixel(1, 1).a == 0
