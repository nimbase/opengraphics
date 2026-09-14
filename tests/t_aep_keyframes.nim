import unittest
import ../src/opengraphics/aep/document
import ../src/opengraphics/aep/props
import ../src/opengraphics/aep/rifx
import ../src/opengraphics/aep/types

const Fixture = "tests/data/01.aep"

proc tdb4bytes(comp, attr1, type3, animated: int): seq[byte] =
  result = newSeq[byte](124)
  result[0] = byte('d')
  result[1] = byte('b')
  result[2] = byte((comp shr 8) and 0xFF)
  result[3] = byte(comp and 0xFF)
  result[5] = byte(attr1)
  result[59] = byte(type3)
  result[68] = byte(animated)

proc be16(v: int): seq[byte] =
  @[byte((v shr 8) and 0xFF), byte(v and 0xFF)]

proc f64s(vals: varargs[float64]): seq[byte] =
  result = @[]
  for v in vals:
    let u = cast[uint64](v)
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      result.add(byte((u shr shift) and 0xFF))

proc lhd3bytes(count, itemSize, itemType: int): seq[byte] =
  result = newSeq[byte](52)
  result[0] = 0
  result[1] = 0xD0
  result[2] = 0x0B
  result[3] = 0xEE
  let c = be16(count)
  result[10] = c[0]
  result[11] = c[1]
  let s = be16(itemSize)
  result[18] = s[0]
  result[19] = s[1]
  result[23] = byte(itemType)

proc kfHead(time, ease, label, attr: int): seq[byte] =
  result = @[byte(0)]
  result.add(be16(time))
  result.add([byte(0), byte(0)])
  result.add(byte(ease))
  result.add(byte(label))
  result.add(byte(attr))

proc leaf(id: string, payload: seq[byte]): RifxChunk =
  RifxChunk(id: id, data: payload)

proc listNode(kids: seq[RifxChunk]): RifxChunk =
  RifxChunk(id: "LIST", listType: "list", children: kids)

proc tdbsNode(kids: seq[RifxChunk]): RifxChunk =
  RifxChunk(id: "LIST", listType: "tdbs", children: kids)

proc tinfo(comp, attr1, type3, animated: int): Tdb4Info =
  parseTdb4(tdb4bytes(comp, attr1, type3, animated))

test "lhd3 fields and truncation":
  let h = parseLhd3(lhd3bytes(7, 0x30, 4))
  check h.count == 7
  check h.itemSize == 0x30
  check h.itemType == 4
  expect(AepError):
    discard parseLhd3(newSeq[byte](40))

test "scalar keyframes with ease modes":
  let ldat = kfHead(0, 1, 0, 0x07) & f64s(10.0, 0.5, 0.6, 0.7, 0.8) &
    kfHead(30, 3, 2, 0x07) & f64s(20.0, 0.0, 0.0, 0.0, 0.0)
  let n = listNode(@[leaf("lhd3", lhd3bytes(2, 0x30, 4)),
    leaf("ldat", ldat)])
  let ks = parseKeyframes(n, tinfo(1, 0x00, 0x08, 1))
  check ks.len == 2
  check ks[0].time == 0
  check ks[0].ease == EaseLinear
  check ks[0].values == @[10.0]
  check ks[0].inSpeed == @[0.5]
  check ks[0].outInfluence == @[0.8]
  check ks[0].labelColor == 0
  check ks[1].time == 30
  check ks[1].ease == EaseHold
  check ks[1].values == @[20.0]
  check ks[1].labelColor == 2

test "multidimensional keyframes":
  let ldat = kfHead(0, 2, 0, 0x07) &
    f64s(1.0, 2.0, 3.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9,
      1.0, 1.1, 1.2)
  let n = listNode(@[leaf("lhd3", lhd3bytes(1, 0x80, 4)),
    leaf("ldat", ldat)])
  let ks = parseKeyframes(n, tinfo(3, 0x00, 0x08, 1))
  check ks.len == 1
  check ks[0].ease == EaseEase
  check ks[0].values == @[1.0, 2.0, 3.0]
  check ks[0].inSpeed == @[0.1, 0.2, 0.3]
  check ks[0].outInfluence == @[1.0, 1.1, 1.2]

test "position keyframes carry spatial tangents":
  let ldat = kfHead(5, 1, 0, 0x1F) & f64s(0.0, 0.0) &
    f64s(1.0, 0.5, 1.5, 0.75) & f64s(100.0, 200.0) &
    f64s(10.0, 20.0) & f64s(30.0, 40.0)
  let n = listNode(@[leaf("lhd3", lhd3bytes(1, 0x68, 4)),
    leaf("ldat", ldat)])
  let ks = parseKeyframes(n, tinfo(2, 0x0F, 0x08, 1))
  check ks.len == 1
  check ks[0].time == 5
  check ks[0].values == @[100.0, 200.0]
  check ks[0].inSpeed == @[1.0]
  check ks[0].outInfluence == @[0.75]
  check ks[0].tanIn == @[10.0, 20.0]
  check ks[0].tanOut == @[30.0, 40.0]
  check ks[0].continuousBezier
  check ks[0].autoBezier
  check not ks[0].roving

test "color keyframes hold ARGB plus extra":
  let ldat = kfHead(0, 1, 0, 0x27) & f64s(0.0, 0.0) &
    f64s(1.0, 1.0, 1.0, 1.0) & f64s(255.0, 255.0, 0.0, 0.0) &
    f64s(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
  var tb = tdb4bytes(4, 0x00, 0x01, 1)
  let n = listNode(@[leaf("lhd3", lhd3bytes(1, 0x98, 4)),
    leaf("ldat", ldat)])
  let ks = parseKeyframes(n, parseTdb4(tb))
  check ks.len == 1
  check ks[0].values == @[255.0, 255.0, 0.0, 0.0]
  check ks[0].extra.len == 8
  check ks[0].roving

test "no value keyframes keep timing only":
  let ldat = kfHead(12, 1, 3, 0x07) & f64s(0.0, 0.0) &
    f64s(1.0, 1.0, 1.0, 1.0) & f64s(0.0)
  var tb = tdb4bytes(0, 0x00, 0x00, 1)
  tb[57] = 1
  let n = listNode(@[leaf("lhd3", lhd3bytes(1, 0x40, 4)),
    leaf("ldat", ldat)])
  let ks = parseKeyframes(n, parseTdb4(tb))
  check ks.len == 1
  check ks[0].time == 12
  check ks[0].values.len == 0
  check ks[0].inSpeed == @[1.0]
  check ks[0].labelColor == 3

test "3D position shares size with 3D multi":
  let ldat = kfHead(0, 1, 0, 0x07) & f64s(0.0, 0.0) &
    f64s(1.0, 0.5, 1.5, 0.75) & f64s(1.0, 2.0, 3.0) &
    f64s(0.1, 0.2, 0.3) & f64s(0.4, 0.5, 0.6)
  let n = listNode(@[leaf("lhd3", lhd3bytes(1, 0x80, 4)),
    leaf("ldat", ldat)])
  let pos = parseKeyframes(n, tinfo(3, 0x0F, 0x08, 1))
  check pos[0].values == @[1.0, 2.0, 3.0]
  check pos[0].tanIn == @[0.1, 0.2, 0.3]
  check pos[0].tanOut == @[0.4, 0.5, 0.6]
  let flat = parseKeyframes(n, tinfo(3, 0x00, 0x08, 1))
  check flat[0].values == @[0.0, 0.0, 1.0]
  check flat[0].tanIn.len == 0

test "unknown ease maps to EaseUnknown":
  let ldat = kfHead(0, 9, 0, 0x07) & f64s(1.0, 0.0, 0.0, 0.0, 0.0)
  let n = listNode(@[leaf("lhd3", lhd3bytes(1, 0x30, 4)),
    leaf("ldat", ldat)])
  let ks = parseKeyframes(n, tinfo(1, 0x00, 0x08, 1))
  check ks[0].ease == EaseUnknown

test "zero count needs no ldat":
  let n = listNode(@[leaf("lhd3", lhd3bytes(0, 0x30, 4))])
  check parseKeyframes(n, tinfo(1, 0x00, 0x08, 1)).len == 0

test "animated flag without list keeps empty keyframes":
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x00, 0x08, 1)),
    leaf("cdat", f64s(1.0))])
  let v = parseTdbs(n)
  check v.isAnimated
  check v.keyframes.len == 0
  check v.values.len == 0

test "animated tdbs attaches keyframes":
  let ldat = kfHead(0, 1, 0, 0x07) & f64s(5.0, 0.0, 0.0, 0.0, 0.0)
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x00, 0x08, 1)),
    listNode(@[leaf("lhd3", lhd3bytes(1, 0x30, 4)),
      leaf("ldat", ldat)])])
  let v = parseTdbs(n)
  check v.isAnimated
  check v.keyframes.len == 1
  check v.keyframes[0].values == @[5.0]
  check v.values.len == 0

test "nested gide lists do not animate a static":
  let inner = listNode(@[leaf("lhd3", lhd3bytes(0, 0x10, 2))])
  let gide = RifxChunk(id: "LIST", listType: "Gide",
    children: @[leaf("gdta", newSeq[byte](8)), inner])
  let n = tdbsNode(@[leaf("tdb4", tdb4bytes(1, 0x01, 0x08, 0)),
    gide, leaf("cdat", f64s(2.5))])
  let v = parseTdbs(n)
  check not v.isAnimated
  check v.values == @[2.5]
  check v.keyframes.len == 0

test "malformed lists rejected":
  let good = kfHead(0, 1, 0, 0x07) & f64s(1.0, 0.0, 0.0, 0.0, 0.0)
  let noLhd3 = listNode(@[leaf("ldat", good)])
  expect(AepError):
    discard parseKeyframes(noLhd3, tinfo(1, 0x00, 0x08, 1))
  let noLdat = listNode(@[leaf("lhd3", lhd3bytes(1, 0x30, 4))])
  expect(AepError):
    discard parseKeyframes(noLdat, tinfo(1, 0x00, 0x08, 1))
  let short = listNode(@[leaf("lhd3", lhd3bytes(2, 0x30, 4)),
    leaf("ldat", good)])
  expect(AepError):
    discard parseKeyframes(short, tinfo(1, 0x00, 0x08, 1))
  let wrongSize = listNode(@[leaf("lhd3", lhd3bytes(1, 0x30, 4)),
    leaf("ldat", good & f64s(0.0))])
  expect(AepError):
    discard parseKeyframes(wrongSize, tinfo(1, 0x00, 0x08, 1))
  let sizeMismatch = listNode(@[leaf("lhd3", lhd3bytes(1, 0x58, 4)),
    leaf("ldat", good & f64s(0.0, 0.0, 0.0, 0.0, 0.0, 0.0))])
  expect(AepError):
    discard parseKeyframes(sizeMismatch, tinfo(1, 0x00, 0x08, 1))
  let notList = tdbsNode(@[leaf("lhd3", lhd3bytes(1, 0x30, 4))])
  expect(AepError):
    discard parseKeyframes(notList, tinfo(1, 0x00, 0x08, 1))

test "integer animation unsupported":
  let ldat = kfHead(0, 1, 0, 0x07) & f64s(1.0, 0.0, 0.0, 0.0, 0.0)
  let n = listNode(@[leaf("lhd3", lhd3bytes(1, 0x30, 4)),
    leaf("ldat", ldat)])
  expect(AepError):
    discard parseKeyframes(n, tinfo(1, 0x00, 0x04, 1))

test "keyframe cap enforced":
  var limits = defaultAepLimits()
  limits.maxKeyframes = 1
  let good = kfHead(0, 1, 0, 0x07) & f64s(1.0, 0.0, 0.0, 0.0, 0.0)
  let n = listNode(@[leaf("lhd3", lhd3bytes(2, 0x30, 4)),
    leaf("ldat", good & good)])
  expect(AepError):
    discard parseKeyframes(n, tinfo(1, 0x00, 0x08, 1), limits)

test "longer lhd3 tolerated":
  var h = lhd3bytes(1, 0x30, 4)
  h.add([byte(0), byte(0), byte(0), byte(0)])
  let n = listNode(@[leaf("lhd3", h),
    leaf("ldat", kfHead(0, 1, 0, 0x07) & f64s(3.0, 0.0, 0.0, 0.0, 0.0))])
  let ks = parseKeyframes(n, tinfo(1, 0x00, 0x08, 1))
  check ks[0].values == @[3.0]

test "fixture stays fully static":
  let doc = openAep(Fixture)
  var total = 0
  for c in doc.comps:
    for l in c.layers:
      for p in layerTransform(c, l.id):
        check not p.value.isAnimated
        check p.value.keyframes.len == 0
        inc total
  check total == 7
