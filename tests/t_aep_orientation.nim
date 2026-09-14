import unittest
import ../src/opengraphics/aep/document
import ../src/opengraphics/aep/props
import ../src/opengraphics/aep/rifx
import ../src/opengraphics/aep/types

const Fixture = "tests/data/01.aep"

proc f64s(vals: varargs[float64]): seq[byte] =
  result = @[]
  for v in vals:
    let u = cast[uint64](v)
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      result.add(byte((u shr shift) and 0xFF))

proc leaf(id: string, payload: seq[byte]): RifxChunk =
  RifxChunk(id: id, data: payload)

proc tdb4bytes(): seq[byte] =
  result = newSeq[byte](124)
  result[2] = 0
  result[3] = 1
  result[5] = 0x07
  result[59] = 0x18

proc tdsnChunk(name: string): RifxChunk =
  var payload: seq[byte] = @[]
  for c in "Utf8":
    payload.add(byte(c))
  let n = name.len
  payload.add([byte((n shr 24) and 0xFF), byte((n shr 16) and 0xFF),
    byte((n shr 8) and 0xFF), byte(n and 0xFF)])
  for c in name:
    payload.add(byte(c))
  leaf("tdsn", payload)

proc makeOtst(base: array[3, float64], frames: seq[array[3, float64]],
    display = ""): RifxChunk =
  var tdbs: seq[RifxChunk] = @[leaf("tdsb", @[byte(0), 0, 0, 3]),
    leaf("tdb4", tdb4bytes()),
    leaf("cdat", f64s(base[0], base[1], base[2]))]
  if display.len > 0:
    tdbs.add(tdsnChunk(display))
  var otky: seq[RifxChunk] = @[]
  for f in frames:
    otky.add(leaf("otda", f64s(f[0], f[1], f[2])))
  RifxChunk(id: "LIST", listType: "otst", children: @[
    RifxChunk(id: "LIST", listType: "tdbs", children: tdbs),
    RifxChunk(id: "LIST", listType: "otky", children: otky)])

proc tdmnChunk(name: string): RifxChunk =
  var payload = newSeq[byte](40)
  for i, c in name:
    payload[i] = byte(c)
  leaf("tdmn", payload)

proc tdgpNode(kids: seq[RifxChunk]): RifxChunk =
  RifxChunk(id: "LIST", listType: "tdgp", children: kids)

test "static plus frames plus display name":
  let o = parseOtst(makeOtst([1.0, 2.0, 3.0],
    @[[4.0, 5.0, 6.0], [7.0, 8.0, 9.0]], "Spin"), "ADBE Orientation")
  check o.matchName == "ADBE Orientation"
  check o.displayName == "Spin"
  check o.staticValue == [1.0, 2.0, 3.0]
  check o.frames == @[[4.0, 5.0, 6.0], [7.0, 8.0, 9.0]]

test "missing otky means no frames":
  let tdbs = RifxChunk(id: "LIST", listType: "tdbs", children: @[
    leaf("tdb4", tdb4bytes()), leaf("cdat", f64s(0.0, 0.0, 0.0))])
  let n = RifxChunk(id: "LIST", listType: "otst", children: @[tdbs])
  let o = parseOtst(n, "ADBE Orientation")
  check o.staticValue == [0.0, 0.0, 0.0]
  check o.frames.len == 0
  check o.displayName == ""

test "placeholder display name empties":
  let o = parseOtst(makeOtst([0.0, 0.0, 0.0], @[], "-_0_/-"),
    "ADBE Orientation")
  check o.displayName == ""

test "malformed otst rejected":
  let noTdbs = RifxChunk(id: "LIST", listType: "otst", children: @[
    RifxChunk(id: "LIST", listType: "otky", children: @[])])
  expect(AepError):
    discard parseOtst(noTdbs, "ADBE Orientation")
  let noCdat = RifxChunk(id: "LIST", listType: "otst", children: @[
    RifxChunk(id: "LIST", listType: "tdbs",
      children: @[leaf("tdb4", tdb4bytes())])])
  expect(AepError):
    discard parseOtst(noCdat, "ADBE Orientation")
  let shortCdat = RifxChunk(id: "LIST", listType: "otst", children: @[
    RifxChunk(id: "LIST", listType: "tdbs", children: @[
      leaf("tdb4", tdb4bytes()), leaf("cdat", f64s(1.0))])])
  expect(AepError):
    discard parseOtst(shortCdat, "ADBE Orientation")
  var badFrames: seq[RifxChunk] = @[leaf("otda", f64s(1.0, 2.0))]
  let badOtky = RifxChunk(id: "LIST", listType: "otky", children: badFrames)
  let bad = RifxChunk(id: "LIST", listType: "otst", children: @[
    RifxChunk(id: "LIST", listType: "tdbs", children: @[
      leaf("tdb4", tdb4bytes()), leaf("cdat", f64s(0.0, 0.0, 0.0))]),
    badOtky])
  expect(AepError):
    discard parseOtst(bad, "ADBE Orientation")
  let notOtst = RifxChunk(id: "LIST", listType: "tdbs")
  expect(AepError):
    discard parseOtst(notOtst, "ADBE Orientation")

test "frame cap enforced":
  var limits = defaultAepLimits()
  limits.maxKeyframes = 1
  let n = makeOtst([0.0, 0.0, 0.0],
    @[[1.0, 1.0, 1.0], [2.0, 2.0, 2.0]])
  expect(AepError):
    discard parseOtst(n, "ADBE Orientation", limits)

test "group pairing skips tdbs and stops at end":
  let g = tdgpNode(@[
    tdmnChunk("ADBE Scale"),
    RifxChunk(id: "LIST", listType: "tdbs"),
    tdmnChunk("ADBE Orientation"),
    makeOtst([0.0, 0.0, 0.0], @[[1.0, 2.0, 3.0]]),
    tdmnChunk("ADBE Group End"),
    tdmnChunk("ADBE Rotate X"),
    makeOtst([9.0, 9.0, 9.0], @[])])
  let os = orientationsIn(g)
  check os.len == 1
  check os[0].matchName == "ADBE Orientation"
  check os[0].frames == @[[1.0, 2.0, 3.0]]
  expect(AepError):
    discard orientationsIn(RifxChunk(id: "LIST", listType: "tdbs"))

test "nested groups collected in order":
  let inner = tdgpNode(@[tdmnChunk("ADBE Group End")])
  let outer = tdgpNode(@[tdmnChunk("ADBE Transform Group"), inner,
    tdmnChunk("ADBE Group End")])
  check collectGroups(outer).len == 2
  check collectGroups(leaf("cdat", f64s(1.0))).len == 0

test "fixture orientation pinned":
  let doc = openAep(Fixture)
  let c = doc.comps[0]
  let all = layerOrientations(c, 13)
  check all.len == 1
  check all[0].matchName == "ADBE Orientation"
  check all[0].displayName == ""
  check all[0].staticValue == [0.0, 0.0, 0.0]
  check all[0].frames == @[[0.0, 0.0, 0.0]]
  check layerOrientation(c, 13).staticValue == [0.0, 0.0, 0.0]
  expect(AepError):
    discard layerOrientation(c, 9999)
