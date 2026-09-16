import std/options
import unittest
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/layers
import ../src/opengraphics/psd/types
import ../src/opengraphics/psd/vector
import psd_support

proc vecLayer(extra: seq[tuple[key: string, payload: seq[byte]]]): Document =
  let px = @[byte(5), 6, 7, 8]
  let spec = TestLayerSpec(name: "v", top: 0, left: 0, bottom: 2,
    right: 2, planes: @[px], channelIds: @[int16(0)], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0, lsct: -1, lsdk: -1,
    extra: extra)
  readPsdBytes(buildPsd(2, 2, 1, @[px], false, @[spec]))

test "no vector data by default":
  let doc = vecLayer(@[])
  check not doc.layers[0].hasVectorMask()
  check doc.layers[0].vectorMask().isNone
  check not doc.layers[0].hasFillContent()
  check doc.layers[0].fillContent().isNone

test "synthetic closed rect parses":
  let knots = @[(0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0)]
  let doc = vecLayer(@[("vsms", buildVsms(knots))])
  let l = doc.layers[0]
  check l.hasVectorMask()
  let vm = l.vectorMask().get()
  check vm.version == 3
  check vm.flags == 0
  check vm.initialFill == 0
  check not vm.hasClipboard
  check vm.subpaths.len == 1
  check vm.subpaths[0].closed
  check vm.subpaths[0].knots.len == 4
  check vm.subpaths[0].knots[2].anchorVert == 1.0
  check vm.subpaths[0].knots[2].anchorHoriz == 1.0
  check vm.subpaths[0].knots[2].linked
  check vm.trailingRaw.len == 0

test "vmsk key is accepted too":
  let doc = vecLayer(@[("vmsk", buildVsms(@[(0.25, 0.5)]))])
  check doc.layers[0].hasVectorMask()
  let vm = doc.layers[0].vectorMask().get()
  check vm.subpaths.len == 1
  check vm.subpaths[0].knots[0].anchorVert == 0.25
  check vm.subpaths[0].knots[0].anchorHoriz == 0.5

test "open subpath and knot linkage":
  var data = buildVsms(@[(0.0, 0.0)], closed = false)
  # knot record starts after header(8) + fill rule(26) + initial fill(26)
  # + length record(26); flip its selector from 1 (linked) to 2 (unlinked)
  data[8 + 26 + 26 + 26 + 1] = 2
  let vm = parseVectorMask(data)
  check not vm.subpaths[0].closed
  check not vm.subpaths[0].knots[0].linked

test "clipboard record parses":
  var data: seq[byte] = @[]
  putU32BE(data, 3)
  putU32BE(data, 0)
  putU16BE(data, 7)
  putFixed824(data, 0.0)
  putFixed824(data, 0.0)
  putFixed824(data, 1.0)
  putFixed824(data, 1.0)
  putFixed824(data, 72.0)
  for _ in 0 ..< 4: data.add(0)
  let vm = parseVectorMask(data)
  check vm.hasClipboard
  check vm.clipboard.top == 0.0
  check vm.clipboard.bottom == 1.0
  check vm.clipboard.right == 1.0
  check vm.clipboard.resolution == 72.0

test "unknown selector is skipped, knot without subpath raises":
  var data: seq[byte] = @[]
  putU32BE(data, 3)
  putU32BE(data, 0)
  putU16BE(data, 42) # future selector
  for _ in 0 ..< 24: data.add(byte(0xAB))
  let vm = parseVectorMask(data)
  check vm.subpaths.len == 0
  var bad: seq[byte] = @[]
  putU32BE(bad, 3)
  putU32BE(bad, 0)
  putU16BE(bad, 1)
  for _ in 0 ..< 24: bad.add(0)
  expect(PsdError):
    discard parseVectorMask(bad)

test "truncated vector mask raises":
  expect(PsdError):
    discard parseVectorMask(@[byte(0), 0, 0])
  var data = buildVsms(@[(0.0, 0.0)])
  expect(PsdError):
    discard parseVectorMask(data[0 ..< data.len - 10])

test "synthetic SoCo parses to RGB":
  let doc = vecLayer(@[("vscg", buildSoCo(23.0, 25.0, 33.0))])
  let l = doc.layers[0]
  check l.hasFillContent()
  let fc = l.fillContent().get()
  check fc.kind == SolidColor
  check fc.kindKey == "SoCo"
  check fc.red == 23.0
  check fc.green == 25.0
  check fc.blue == 33.0

test "non-SoCo fill is unknown with raw preserved":
  var data: seq[byte] = @[]
  putStr(data, "GrFl")
  putU32BE(data, 16)
  for v in [byte(1), 2, 3]: data.add(v)
  let fc = parseFillContent(data)
  check fc.kind == Unknown
  check fc.kindKey == "GrFl"
  check fc.raw == data

test "broken SoCo raises":
  var data = buildSoCo(1.0, 2.0, 3.0)
  data[4 .. 7] = @[byte(0), 0, 0, 15] # bad version
  expect(PsdError):
    discard parseFillContent(data)
  expect(PsdError):
    discard parseFillContent(@[byte('S'), byte('o'), byte('C'),
      byte('o'), byte(1), byte(2)])

test "real fixture layer 0 is a rectangle shape":
  let doc = openPsd("tests/data/01.psd")
  for i in 1 ..< 4:
    check not doc.layers[i].hasVectorMask()
    check not doc.layers[i].hasFillContent()
  let l = doc.layers[0]
  check l.hasVectorMask()
  let vm = l.vectorMask().get()
  check vm.version == 3
  check vm.initialFill == 0
  check vm.subpaths.len == 1
  check vm.subpaths[0].closed
  check vm.subpaths[0].knots.len == 4
  let k = vm.subpaths[0].knots
  check abs(k[0].anchorVert * 700.0 - 0.5) < 1.0
  check abs(k[2].anchorVert * 700.0 - 699.5) < 1.0
  check abs(k[2].anchorHoriz * 700.0 - 700.5) < 1.0
  for knot in k:
    check knot.linked
    check knot.prevVert == knot.anchorVert
    check knot.nextHoriz == knot.anchorHoriz
  let fc = l.fillContent().get()
  check fc.kind == SolidColor
  check abs(fc.red - 23.0) < 0.01
  check abs(fc.green - 25.0) < 0.01
  check abs(fc.blue - 33.0) < 0.01
