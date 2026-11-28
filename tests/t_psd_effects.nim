## Layer-effects parsing: `lfx2` master switch and per-effect dispatch.
##
## No committed fixture carries `lfx2`, so these tests build the descriptor
## with the descriptor writer (the same grammar the parser reads) rather than
## hand-encoding bytes.

import std/options
import std/unittest
import ../src/opengraphics/psd

proc lfx2Payload(d: Descriptor): Span =
  var w = initWriter()
  w.putU32(0) # lfx2 version
  w.putU32(16) # descriptor version
  w.writeDescriptorBody(d)
  let s = w.toString()
  Span(src: newStringSource(s), start: 0, stop: s.len)

suite "effects: kinds and keys":
  test "all 10 single keys map":
    check kindFor("DrSh") == ekDropShadow
    check kindFor("IrSh") == ekInnerShadow
    check kindFor("OrGl") == ekOuterGlow
    check kindFor("IrGl") == ekInnerGlow
    check kindFor("ebbl") == ekBevelEmboss
    check kindFor("ChFX") == ekSatin
    check kindFor("SoFi") == ekColorOverlay
    check kindFor("GrFl") == ekGradientOverlay
    check kindFor("patternFill") == ekPatternOverlay
    check kindFor("FrFX") == ekStroke
    check kindFor("xxxx") == ekUnknown

  test "known-keys gate covers masters":
    check isKnownEffectsKey("DrSh")
    check isKnownEffectsKey("dropShadowMulti")
    check isKnownEffectsKey("masterFXSwitch")
    check not isKnownEffectsKey("TySh")

suite "effects: lfx2 descriptor":
  test "empty descriptor yields master on, no effects":
    let d = newDescriptor("null")
    let r = effectsFromDescriptor(d)
    check r.master
    check r.effects.len == 0

  test "master switch off is honoured":
    var d = newDescriptor("null")
    discard d.add("masterFXSwitch", boolValue(false))
    let r = effectsFromDescriptor(d)
    check not r.master

  test "a drop shadow parses with common fields":
    var sh = newDescriptor("DrSh")
    discard sh.add("enab", boolValue(true))
    discard sh.add("Md  ", enumValue("BlnM", "Mltp"))
    discard sh.add("Opct", unitFloatValue("#Prc", 75.0))
    discard sh.add("Dstn", doubleValue(5.0))
    discard sh.add("blur", doubleValue(3.0))
    var d = newDescriptor("null")
    discard d.add("DrSh", descriptorValue(sh))
    let r = parseLfx2(lfx2Payload(d))
    check r.isSome
    check r.get().master
    check r.get().effects.len == 1
    let e = r.get().effects[0]
    check e.kind == ekDropShadow
    check e.common.enabled
    check e.common.blend == "Mltp"
    check abs(e.common.opacity - 0.75f32) < 1e-5
    check e.distance == 5.0f32

  test "multi list parses each entry":
    var s1 = newDescriptor("DrSh")
    discard s1.add("enab", boolValue(true))
    var s2 = newDescriptor("DrSh")
    discard s2.add("enab", boolValue(false))
    var d = newDescriptor("null")
    discard d.add("dropShadowMulti",
      listValue(@[descriptorValue(s1), descriptorValue(s2)]))
    let r = parseLfx2(lfx2Payload(d))
    check r.isSome
    check r.get().effects.len == 2

  test "drop shadow parses color spread knockout":
    var sh = newDescriptor("DrSh")
    discard sh.add("enab", boolValue(true))
    var clr = newDescriptor("RGBC")
    discard clr.add("Rd  ", doubleValue(10.0))
    discard clr.add("Grn ", doubleValue(20.0))
    discard clr.add("Bl  ", doubleValue(30.0))
    discard sh.add("Clr ", descriptorValue(clr))
    discard sh.add("Ckmt", doubleValue(25.0))
    discard sh.add("layerConceals", boolValue(false))
    var d = newDescriptor("null")
    discard d.add("DrSh", descriptorValue(sh))
    let e = parseLfx2(lfx2Payload(d)).get().effects[0]
    check e.color == [10.0f32, 20.0f32, 30.0f32]
    check abs(e.spread - 0.25f32) < 1e-6
    check not e.knocksOut

  test "drop shadow color spread knockout defaults":
    var sh = newDescriptor("DrSh")
    discard sh.add("enab", boolValue(true))
    var d = newDescriptor("null")
    discard d.add("DrSh", descriptorValue(sh))
    let e = parseLfx2(lfx2Payload(d)).get().effects[0]
    check e.color == [0.0f32, 0.0f32, 0.0f32]
    check e.spread == 0.0f32
    check e.knocksOut
    check e.angle == 120.0f32
    check e.useGlobalLight
    check e.common.blend == "Mltp"
    check abs(e.common.opacity - 0.75f32) < 1e-6

  test "drop shadow reads the local angle":
    # Real files carry it in `lagl`; a legacy `Angl` still works.
    var sh = newDescriptor("DrSh")
    discard sh.add("enab", boolValue(true))
    discard sh.add("lagl", unitFloatValue("#Ang", 30.0))
    var d = newDescriptor("null")
    discard d.add("DrSh", descriptorValue(sh))
    check parseLfx2(lfx2Payload(d)).get().effects[0].angle == 30.0f32
    var sh2 = newDescriptor("DrSh")
    discard sh2.add("enab", boolValue(true))
    discard sh2.add("Angl", unitFloatValue("#Ang", 45.0))
    var d2 = newDescriptor("null")
    discard d2.add("DrSh", descriptorValue(sh2))
    check parseLfx2(lfx2Payload(d2)).get().effects[0].angle == 45.0f32

  test "outer glow parses paint spread range technique":
    var gl = newDescriptor("OrGl")
    discard gl.add("enab", boolValue(true))
    var clr = newDescriptor("RGBC")
    discard clr.add("Rd  ", doubleValue(255.0))
    discard clr.add("Grn ", doubleValue(0.0))
    discard clr.add("Bl  ", doubleValue(0.0))
    discard gl.add("Clr ", descriptorValue(clr))
    discard gl.add("Ckmt", doubleValue(40.0))
    discard gl.add("Inpr", doubleValue(30.0))
    discard gl.add("GlwT", enumValue("GlwT", "PrBL"))
    var d = newDescriptor("null")
    discard d.add("OrGl", descriptorValue(gl))
    let e = parseLfx2(lfx2Payload(d)).get().effects[0]
    check e.kind == ekOuterGlow
    check e.glowColor == [255.0f32, 0.0f32, 0.0f32]
    check abs(e.glowSpread - 0.4f32) < 1e-6
    check abs(e.glowRange - 0.3f32) < 1e-6
    check e.glowPrecise
    check not e.glowGradient

  test "outer glow defaults":
    var gl = newDescriptor("OrGl")
    discard gl.add("enab", boolValue(true))
    var d = newDescriptor("null")
    discard d.add("OrGl", descriptorValue(gl))
    let e = parseLfx2(lfx2Payload(d)).get().effects[0]
    check e.glowColor == [0.0f32, 0.0f32, 0.0f32]
    check e.glowSpread == 0.0f32
    check abs(e.glowRange - 0.5f32) < 1e-6
    check not e.glowPrecise
    check not e.glowGradient

  test "color overlay parses its paint":
    var so = newDescriptor("SoFi")
    discard so.add("enab", boolValue(true))
    discard so.add("Md  ", enumValue("BlnM", "Mltp"))
    discard so.add("Opct", unitFloatValue("#Prc", 75.0))
    var clr = newDescriptor("RGBC")
    discard clr.add("Rd  ", doubleValue(10.0))
    discard clr.add("Grn ", doubleValue(20.0))
    discard clr.add("Bl  ", doubleValue(30.0))
    discard so.add("Clr ", descriptorValue(clr))
    var d = newDescriptor("null")
    discard d.add("SoFi", descriptorValue(so))
    let e = parseLfx2(lfx2Payload(d)).get().effects[0]
    check e.kind == ekColorOverlay
    check e.overlayColor == [10.0f32, 20.0f32, 30.0f32]
    check e.common.blend == "Mltp"
    check abs(e.common.opacity - 0.75f32) < 1e-6

  test "color overlay defaults to black":
    var so = newDescriptor("SoFi")
    discard so.add("enab", boolValue(true))
    var d = newDescriptor("null")
    discard d.add("SoFi", descriptorValue(so))
    let e = parseLfx2(lfx2Payload(d)).get().effects[0]
    check e.overlayColor == [0.0f32, 0.0f32, 0.0f32]

  test "inner glow parses source and range":
    var gl = newDescriptor("IrGl")
    discard gl.add("enab", boolValue(true))
    discard gl.add("Ckmt", doubleValue(30.0))
    discard gl.add("Inpr", doubleValue(40.0))
    discard gl.add("glwS", enumValue("glwS", "SrcC"))
    var d = newDescriptor("null")
    discard d.add("IrGl", descriptorValue(gl))
    let e = parseLfx2(lfx2Payload(d)).get().effects[0]
    check e.kind == ekInnerGlow
    check e.glowCenter
    check abs(e.glowSpread - 0.3f32) < 1e-6
    check abs(e.glowRange - 0.4f32) < 1e-6
    check not e.glowPrecise

  test "stroke parses paint size and position":
    var fr = newDescriptor("FrFX")
    discard fr.add("enab", boolValue(true))
    discard fr.add("Sz  ", doubleValue(4.0))
    discard fr.add("Styl", enumValue("Styl", "CtrF"))
    var clr = newDescriptor("RGBC")
    discard clr.add("Rd  ", doubleValue(1.0))
    discard clr.add("Grn ", doubleValue(2.0))
    discard clr.add("Bl  ", doubleValue(3.0))
    discard fr.add("Clr ", descriptorValue(clr))
    var d = newDescriptor("null")
    discard d.add("FrFX", descriptorValue(fr))
    let e = parseLfx2(lfx2Payload(d)).get().effects[0]
    check e.kind == ekStroke
    check e.strokeSize == 4.0f32
    check e.strokePosition == "CtrF"
    check e.strokeColor == [1.0f32, 2.0f32, 3.0f32]
    check not e.strokeGradient
    check not e.strokePattern

  test "stroke defaults to an outside solid stroke":
    var fr = newDescriptor("FrFX")
    discard fr.add("enab", boolValue(true))
    var d = newDescriptor("null")
    discard d.add("FrFX", descriptorValue(fr))
    let e = parseLfx2(lfx2Payload(d)).get().effects[0]
    check e.strokeSize == 3.0f32
    check e.strokePosition == "Outs"
    check e.strokeColor == [0.0f32, 0.0f32, 0.0f32]

  test "stroke gradient and pattern paint flag as unpainted":
    var fr = newDescriptor("FrFX")
    discard fr.add("enab", boolValue(true))
    discard fr.add("PntT", enumValue("FrFl", "GrFl"))
    discard fr.add("Grad", descriptorValue(newDescriptor("Grad")))
    var d = newDescriptor("null")
    discard d.add("FrFX", descriptorValue(fr))
    check parseLfx2(lfx2Payload(d)).get().effects[0].strokeGradient
    var fr2 = newDescriptor("FrFX")
    discard fr2.add("enab", boolValue(true))
    discard fr2.add("Ptrn", descriptorValue(newDescriptor("Ptrn")))
    var d2 = newDescriptor("null")
    discard d2.add("FrFX", descriptorValue(fr2))
    check parseLfx2(lfx2Payload(d2)).get().effects[0].strokePattern

  test "short payload stays none, not a crash":
    check parseLfx2(Span(src: newStringSource("\x00\x01"),
      start: 0, stop: 2)).isNone
