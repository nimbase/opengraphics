import std/options
import unittest
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/layers
import ../src/opengraphics/psd/types
import ../src/opengraphics/psd/descriptor
import ../src/opengraphics/psd/smartobject
import psd_support

const testTransform = [0.0, 0.0, 20.0, 0.0, 20.0, 10.0, 0.0, 10.0]

proc soLayer(extra: seq[tuple[key: string, payload: seq[byte]]]): Document =
  let px = @[byte(5), 6, 7, 8]
  let spec = TestLayerSpec(name: "s", top: 0, left: 0, bottom: 2,
    right: 2, planes: @[px], channelIds: @[int16(0)], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0, lsct: -1, lsdk: -1,
    extra: extra)
  readPsdBytes(buildPsd(2, 2, 1, @[px], false, @[spec]))

test "no placed data by default":
  let doc = soLayer(@[])
  check not doc.layers[0].hasPlacedLayer()
  check not doc.layers[0].isSmartObject()
  check doc.layers[0].placedLayer().isNone

test "synthetic SoLd round-trips":
  let data = buildTestSoLd("uuid-1", "file-2", testTransform)
  let pl = parsePlacedLayer(data)
  check pl.kind == "SoLd"
  check pl.version == 4
  check pl.uniqueId == "uuid-1"
  check pl.placedId == "file-2"
  check pl.hasPage
  check pl.page == 1
  check pl.hasTransform
  check pl.transform == testTransform
  check pl.hasWarp
  check pl.warpStyle == "warpNone"
  check pl.hasBounds
  check pl.boundBottom == 10.0
  check pl.boundRight == 20.0
  check pl.hasSize
  check pl.width == 20.0
  check pl.height == 10.0
  check pl.hasResolution
  check pl.resolution == 72.0
  check pl.resolutionUnit == "#Rsl"
  check pl.raw == data

test "synthetic PlLd round-trips":
  let uuid = "$93899d32-3bef-524e-8160-ec9bf5549801"
  let data = buildTestPlLd(uuid, testTransform)
  let pl = parsePlacedLayer(data)
  check pl.kind == "PlLd"
  check pl.version == 3
  check pl.uniqueId == uuid
  check pl.placedId == ""
  check pl.hasTransform
  check pl.transform == testTransform
  check not pl.hasWarp

test "SoLd wins over PlLd on one layer":
  let doc = soLayer(@[
    ("PlLd", buildTestPlLd("$93899d32-3bef-524e-8160-ec9bf5549801",
      testTransform)),
    ("SoLd", buildTestSoLd("uuid-1", "file-2", testTransform)),
  ])
  check doc.layers[0].isSmartObject()
  check doc.layers[0].placedLayer().get().kind == "SoLd"

test "bad placed data raises":
  expect(PsdError):
    discard parsePlacedLayer(@[byte('X'), byte('Y'), byte('Z'),
      byte('W'), byte(0)])
  var badVer = buildTestSoLd("a", "b", testTransform)
  badVer[4 .. 7] = @[byte(0), 0, 0, 5]
  expect(PsdError):
    discard parsePlacedLayer(badVer)
  var badPl = buildTestPlLd("$93899d32-3bef-524e-8160-ec9bf5549801",
    testTransform)
  badPl[4 .. 7] = @[byte(0), 0, 0, 2]
  expect(PsdError):
    discard parsePlacedLayer(badPl)
  expect(PsdError):
    discard parsePlacedLayer(@[byte('s'), byte('o'), byte('L'),
      byte('D'), byte(1)])

test "descriptor engine: nested open-coded coverage":
  var items: seq[byte] = @[]
  putTextItem(items, "note", "hi")
  putLongItem(items, "n", -7)
  putDoubItem(items, "x", 1.5)
  var inner: seq[byte] = @[]
  putLongItem(inner, "m", 42)
  let innerObj = buildCountedObjc("Cls ", inner, 1)
  putDescKey(items, "sub")
  putStr(items, "Objc")
  for v in innerObj: items.add(v)
  putVlLsDoublesItem(items, "vec", [1.0, 2.0])
  putUntFItem(items, "res", "#Rsl", 300.0)
  putEnumItem(items, "st", "sty", "v1")
  var data: seq[byte] = @[]
  putU32BE(data, 16)
  putU32BE(data, 1)
  data.add(0)
  data.add(0)
  putU32BE(data, 0)
  putStr(data, "null")
  putU32BE(data, 7)
  for v in items: data.add(v)
  let obj = parseDescriptor(data)
  check obj.getText("note") == "hi"
  check obj.getLong("n") == -7
  check obj.getLong("missing", 9) == 9
  let (sok, sub) = obj.getObject("sub")
  check sok
  check sub.getLong("m") == 42
  check obj.getDoubles("vec") == @[1.0, 2.0]
  let (rok, unit, res) = obj.getUnitFloat("res")
  check rok
  check unit == "#Rsl"
  check res == 300.0
  let ei = obj.findItem("st")
  check obj.items[ei].value.enumValue == "v1"
  expect(PsdError):
    discard parseDescriptor(@[byte(0), 0, 0, 15])

test "descriptor over-limit count raises":
  var data: seq[byte] = @[]
  putU32BE(data, 16)
  putU32BE(data, 1)
  data.add(0)
  data.add(0)
  putU32BE(data, 0)
  putStr(data, "null")
  putU32BE(data, 5000)
  let lim = Limits(maxWidth: 30000, maxHeight: 30000,
    maxPixels: 100_000_000, maxLayers: 1000,
    maxSectionBytes: 512_000_000, maxBlocks: 10)
  expect(PsdError):
    discard parseDescriptor(data, lim)

test "real fixture layer 1 is a linked smart object":
  let doc = openPsd("tests/data/01.psd")
  for i in [0, 2, 3]:
    check not doc.layers[i].isSmartObject()
  let l = doc.layers[1]
  check l.isSmartObject()
  let pl = l.placedLayer().get()
  check pl.kind == "SoLd"
  check pl.uniqueId == "93899d32-3bef-524e-8160-ec9bf5549801"
  check pl.placedId == "a62e2ac1-75eb-3245-bbf0-5c5c89dd8980"
  check pl.hasPage
  check pl.page == 1
  check pl.hasTransform
  check abs(pl.transform[0] - 299.16) < 0.01
  check abs(pl.transform[5] - 645.0) < 0.01
  check pl.hasNonAffine
  check pl.hasWarp
  check pl.warpStyle == "warpNone"
  check pl.hasSize
  check abs(pl.width - 177.6) < 0.01
  check abs(pl.height - 48.8) < 0.01
  check pl.hasResolution
  check pl.resolution == 72.0
