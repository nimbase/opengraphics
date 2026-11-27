## Gradient and pattern fill content (`vscg` with `GrFl`/`PtFl`).
##
## Built with the descriptor writer so the parser reads back what Photoshop
## would write, rather than hand-encoded bytes.

import std/options
import std/unittest
import ../src/opengraphics/psd

proc payload(key: string, d: Descriptor): Span =
  var w = initWriter()
  w.putStr4(key)
  w.putU32(16)
  w.writeDescriptorBody(d)
  let s = w.toString()
  Span(src: newStringSource(s), start: 0, stop: s.len)

suite "fills: gradient content":
  test "GrFl scalars parse":
    var g = newDescriptor("Grdn")
    var d = newDescriptor("null")
    discard d.add("Angl", unitFloatValue("#Ang", 45.0))
    discard d.add("Scl ", unitFloatValue("#Prc", 100.0))
    discard d.add("Rvrs", boolValue(true))
    discard d.add("Dthr", boolValue(false))
    discard d.add("Grad", descriptorValue(g))
    let fc = parseFillContent(payload("GrFl", d))
    check fc.key == "GrFl"
    check fc.gradAngle == 45.0
    check fc.gradReverse
    check not fc.gradDither

  test "GrFl color stops parse":
    var stop = newDescriptor("Clrt")
    var clr = newDescriptor("RGBC")
    discard clr.add("Rd  ", doubleValue(255.0))
    discard clr.add("Grn ", doubleValue(0.0))
    discard clr.add("Bl  ", doubleValue(0.0))
    discard stop.add("Clr ", descriptorValue(clr))
    discard stop.add("Lctn", intValue(0))
    discard stop.add("Mdpn", intValue(50))
    var stop2 = newDescriptor("Clrt")
    var clr2 = newDescriptor("RGBC")
    discard clr2.add("Rd  ", doubleValue(0.0))
    discard clr2.add("Grn ", doubleValue(0.0))
    discard clr2.add("Bl  ", doubleValue(255.0))
    discard stop2.add("Clr ", descriptorValue(clr2))
    discard stop2.add("Lctn", intValue(4096))
    discard stop2.add("Mdpn", intValue(50))
    var grad = newDescriptor("Grdn")
    discard grad.add("Clrt", listValue(@[descriptorValue(stop),
      descriptorValue(stop2)]))
    var d = newDescriptor("null")
    discard d.add("Angl", unitFloatValue("#Ang", 90.0))
    discard d.add("Grad", descriptorValue(grad))
    let fc = parseFillContent(payload("GrFl", d))
    check fc.gradStops.len == 2
    check fc.gradStops[0].pos == 0.0
    check fc.gradStops[1].r == 0.0

suite "fills: pattern content":
  test "PtFl pattern ref parses":
    var ptrn = newDescriptor("Ptrn")
    discard ptrn.add("Nm  ", textValue("Bubbles"))
    discard ptrn.add("Idnt", textValue("abc-123"))
    var d = newDescriptor("null")
    discard d.add("Ptrn", descriptorValue(ptrn))
    discard d.add("Scl ", unitFloatValue("#Prc", 50.0))
    let fc = parseFillContent(payload("PtFl", d))
    check fc.key == "PtFl"
    check fc.patName == "Bubbles"
    check fc.patId == "abc-123"
    check fc.patScale == 0.5

  test "unknown key keeps raw":
    let fc = parseFillContent(payload("XXXX", newDescriptor("null")))
    check fc.key == "XXXX"
    check fc.solid.isNone
