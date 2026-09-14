import unittest
import ../src/opengraphics/aep/props
import ../src/opengraphics/aep/rifx
import ../src/opengraphics/aep/types

proc tdb4bytes(comp, attr1, type3, animated: int): seq[byte] =
  result = newSeq[byte](124)
  result[0] = byte('d')
  result[1] = byte('b')
  result[2] = byte((comp shr 8) and 0xFF)
  result[3] = byte(comp and 0xFF)
  result[5] = byte(attr1)
  result[59] = byte(type3)
  result[68] = byte(animated)

proc f64s(vals: varargs[float64]): seq[byte] =
  result = @[]
  for v in vals:
    let u = cast[uint64](v)
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      result.add(byte((u shr shift) and 0xFF))

proc leaf(id: string, payload: seq[byte]): RifxChunk =
  RifxChunk(id: id, data: payload)

proc strBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc tdmnChunk(name: string): RifxChunk =
  var payload = strBytes(name)
  while payload.len < 40:
    payload.add(0)
  leaf("tdmn", payload)

proc tdbsNode(kids: seq[RifxChunk]): RifxChunk =
  RifxChunk(id: "LIST", listType: "tdbs", children: kids)

proc tdgpNode(kids: seq[RifxChunk]): RifxChunk =
  RifxChunk(id: "LIST", listType: "tdgp", children: kids)

test "scalar static keeps first component":
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x01, 0x08, 0)),
    leaf("cdat", f64s(2.5, 9.9, 9.9, 9.9, 9.9))])
  let v = parseTdbs(n)
  check v.kind == PropVector
  check v.components == 1
  check v.values == @[2.5]
  check not v.isAnimated
  check not v.isPosition

test "vector position flags":
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(3, 0x0F, 0x08, 0)),
    leaf("cdat", f64s(1.0, 2.0, 3.0))])
  let v = parseTdbs(n)
  check v.isPosition
  check v.values == @[1.0, 2.0, 3.0]

test "color kind":
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(4, 0x01, 0x01, 0)),
    leaf("cdat", f64s(255.0, 255.0, 0.0, 0.0))])
  let v = parseTdbs(n)
  check v.kind == PropColor
  check v.values.len == 4

test "no value kind carries nothing":
  var tb = tdb4bytes(0, 0x01, 0x00, 0)
  tb[57] = 1
  let n = tdbsNode(@[leaf("tdb4", tb)])
  let v = parseTdbs(n)
  check v.kind == PropNoValue
  check v.values.len == 0

test "integer refs from tdpi tdps tdli":
  var payload = newSeq[byte](4)
  payload[3] = 5
  var src = newSeq[byte](4)
  src[3] = 0
  var mask = newSeq[byte](4)
  mask[3] = 2
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x01, 0x04, 0)),
    leaf("tdpi", payload), leaf("tdps", src), leaf("tdli", mask)])
  let v = parseTdbs(n)
  check v.kind == PropInteger
  check v.hasLayerRef
  check v.layerIndex == 5
  check v.hasMaskRef
  check v.maskIndex == 2

test "animated byte marks without values":
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x00, 0x08, 1)),
    leaf("cdat", f64s(1.0))])
  let v = parseTdbs(n)
  check v.isAnimated
  check v.values.len == 0

test "keyframe list marks animated":
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(2, 0x00, 0x08, 0)),
    leaf("cdat", f64s(1.0, 2.0)),
    RifxChunk(id: "LIST", listType: "list")])
  let v = parseTdbs(n)
  check v.isAnimated
  check v.values.len == 0

test "static without cdat rejected":
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x01, 0x08, 0))])
  expect(AepError):
    discard parseTdbs(n)

test "truncated cdat rejected":
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(3, 0x01, 0x08, 0)),
    leaf("cdat", f64s(1.0))])
  expect(AepError):
    discard parseTdbs(n)

test "component cap enforced":
  var limits = defaultAepLimits()
  limits.maxComponents = 2
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(3, 0x01, 0x08, 0)),
    leaf("cdat", f64s(1.0, 2.0, 3.0))])
  expect(AepError):
    discard parseTdbs(n, limits)

test "truncated tdb4 rejected":
  let n = tdbsNode(@[leaf("tdb4", newSeq[byte](100))])
  expect(AepError):
    discard parseTdbs(n)

test "tdbs without tdb4 rejected":
  let n = tdbsNode(@[leaf("cdat", f64s(1.0))])
  expect(AepError):
    discard parseTdbs(n)

test "display name expression minmax":
  var tdsnPayload: seq[byte] = @[]
  for c in "Utf8": tdsnPayload.add(byte(c))
  tdsnPayload.add([byte(0), 0, 0, 10])
  for c in "My Opacity": tdsnPayload.add(byte(c))
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x01, 0x08, 0)),
    leaf("tdsn", tdsnPayload),
    leaf("Utf8", strBytes("effect(\"x\")")),
    leaf("tdum", f64s(0.0)), leaf("tduM", f64s(100.0)),
    leaf("cdat", f64s(75.0))])
  let v = parseTdbs(n)
  check v.displayName == "My Opacity"
  check v.hasExpression
  check v.expression == "effect(\"x\")"
  check v.hasMinMax
  check v.minVal == 0.0
  check v.maxVal == 100.0
  check v.values == @[75.0]

test "placeholder tdsn name empties":
  var tdsnPayload: seq[byte] = @[]
  for c in "Utf8": tdsnPayload.add(byte(c))
  tdsnPayload.add([byte(0), 0, 0, 6])
  for c in "-_0_/-": tdsnPayload.add(byte(c))
  check parseTdsnName(tdsnPayload) == ""
  check parseTdsnName(@[byte(1), 2, 3]) == ""

test "group pairing skips subgroups":
  let sub = tdgpNode(@[tdmnChunk("ADBE Group End")])
  let g = tdgpNode(@[
    tdmnChunk("ADBE A"),
    tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x01, 0x08, 0)),
      leaf("cdat", f64s(1.0))]),
    tdmnChunk("ADBE Sub"), sub,
    tdmnChunk("ADBE C"),
    tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x01, 0x08, 0)),
      leaf("cdat", f64s(3.0))]),
    tdmnChunk("ADBE Group End")])
  let props = groupProperties(g)
  check props.len == 2
  check props[0].matchName == "ADBE A"
  check props[0].value.values == @[1.0]
  check props[1].matchName == "ADBE C"
  check getProp(props, "ADBE C").values == @[3.0]
  expect(AepError):
    discard getProp(props, "ADBE Missing")

test "child groups navigate":
  let inner = tdgpNode(@[tdmnChunk("ADBE Group End")])
  let g = tdgpNode(@[tdmnChunk("ADBE Transform Group"), inner,
    tdmnChunk("ADBE Group End")])
  let found = findGroup([g], ["ADBE Transform Group"])
  check found.listType == "tdgp"
  expect(AepError):
    discard findGroup([g], ["ADBE Missing"])
