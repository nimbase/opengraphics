import unittest
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/types
import ./psd_support

proc headerOnly(width, height: int): seq[byte] =
  ## 26-byte header alone: limit checks fire before anything else
  ## is read, so no further section bytes are needed.
  result = @[]
  putHeader(result, width, height, 3)

test "checkDimensions unit behavior":
  let lim = defaultLimits()
  lim.checkDimensions(1, 1, "document")
  lim.checkDimensions(10000, 10000, "document") # exactly at the pixel cap
  expect(PsdError):
    lim.checkDimensions(0, 10, "document")
  expect(PsdError):
    lim.checkDimensions(30001, 10, "document")
  expect(PsdError):
    lim.checkDimensions(10, 30001, "document")
  expect(PsdError):
    lim.checkDimensions(10000, 10001, "document") # 100M+ pixels

test "oversize document dimensions rejected without allocation":
  expect(PsdError):
    discard readPsdBytes(headerOnly(30001, 10))
  expect(PsdError):
    discard readPsdBytes(headerOnly(10000, 10001))

test "tight custom limits reject the real fixture":
  expect(PsdError):
    discard openPsd("tests/data/01.psd", limits = Limits(
      maxWidth: 30000, maxHeight: 30000, maxPixels: 100, maxLayers: 1000))

test "layer count over limit rejected before records parse":
  var data = headerOnly(1, 1)
  putU32BE(data, 0) # colormode len
  putU32BE(data, 0) # resources len
  var section: seq[byte] = @[]
  putU32BE(section, 2) # layerInfo len: count only
  putI16BE(section, 3) # 3 layers, none follow
  putU32BE(section, 0) # global mask len
  putU32BE(data, uint32(section.len))
  for v in section: data.add(v)
  # composite would follow, but the count check fires first
  expect(PsdError):
    discard readPsdBytes(data, limits = Limits(
      maxWidth: 30000, maxHeight: 30000, maxPixels: 100_000_000,
      maxLayers: 2))

test "huge layer rect rejected before channel decode":
  let p = @[byte(1)]
  var data = buildPsd(1, 1, 3, @[p, p, p], layers = @[
    TestLayerSpec(name: "Big", top: 0, left: 0, bottom: 1, right: 1,
      planes: @[p, p, p], channelIds: @[int16(0), 1, 2],
      useRle: false, blendKey: "norm", opacity: 255, flags: 0,
      lsct: -1, lsdk: -1),
  ])
  # record starts at 26 + 4 + 4 + 4 + 4 + 2 = 44; overwrite rect
  # with 0,0,40000,40000 (40000 = 0x9C40)
  data[44..47] = @[byte(0), 0, 0, 0]
  data[48..51] = @[byte(0), 0, 0, 0]
  data[52..55] = @[byte(0), 0, 0x9C, 0x40]
  data[56..59] = @[byte(0), 0, 0x9C, 0x40]
  expect(PsdError):
    discard readPsdBytes(data)
  # also enforced on the skip path
  expect(PsdError):
    discard readPsdBytes(data, ReadOptions(skipLayerImageData: true))

test "default limits accept the real fixture":
  let doc = openPsd("tests/data/01.psd")
  check doc.layerCount == 4
