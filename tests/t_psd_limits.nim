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
      maxWidth: 30000, maxHeight: 30000, maxPixels: 100, maxLayers: 1000,
      maxSectionBytes: 512_000_000, maxBlocks: 10_000))

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
      maxLayers: 2, maxSectionBytes: 512_000_000, maxBlocks: 10_000))

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

proc tinyLimits(sectionBytes = 512_000_000, blocks = 10_000,
    pixels = 100_000_000): Limits =
  Limits(maxWidth: 30000, maxHeight: 30000, maxPixels: pixels,
    maxLayers: 1000, maxSectionBytes: sectionBytes, maxBlocks: blocks)

test "oversize color mode data rejected before read":
  var data = headerOnly(4, 4)
  putU32BE(data, 16) # claims 16 bytes, none follow
  expect(PsdError):
    discard readPsdBytes(data, limits = tinyLimits(sectionBytes = 8))

test "oversize resources section rejected before parse":
  var data = headerOnly(4, 4)
  putU32BE(data, 0) # colormode len
  putU32BE(data, 100) # claims 100 bytes, none follow
  expect(PsdError):
    discard readPsdBytes(data, limits = tinyLimits(sectionBytes = 64))

test "resource block count capped":
  var data = headerOnly(2, 2)
  putU32BE(data, 0) # colormode len
  var res: seq[byte] = @[]
  for i in 0 ..< 4:
    res.add(byte('8')); res.add(byte('B')); res.add(byte('I')); res.add(byte('M'))
    putU16BE(res, uint16(1000 + i))
    res.add(0); res.add(0) # empty name
    putU32BE(res, 0) # empty payload
  putU32BE(data, uint32(res.len))
  for v in res: data.add(v)
  putU32BE(data, 0) # layer section len
  let p = @[byte(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] # 2x2x3 raw
  putU16BE(data, 0)
  for v in p: data.add(v)
  expect(PsdError):
    discard readPsdBytes(data, limits = tinyLimits(blocks = 2))
  # generous cap parses fine
  check readPsdBytes(data).resources.blocks.len == 4

test "oversize layer section rejected before records parse":
  var data = headerOnly(2, 2)
  putU32BE(data, 0) # colormode len
  putU32BE(data, 0) # resources len
  putU32BE(data, 10_000) # claims 10KB, none follow
  expect(PsdError):
    discard readPsdBytes(data, limits = tinyLimits(sectionBytes = 64))

test "oversize layer extra data rejected":
  let p = @[byte(1)]
  var data = buildPsd(1, 1, 3, @[p, p, p], layers = @[
    TestLayerSpec(name: "Big", top: 0, left: 0, bottom: 1, right: 1,
      planes: @[p, p, p], channelIds: @[int16(0), 1, 2],
      useRle: false, blendKey: "norm", opacity: 255, flags: 0,
      lsct: -1, lsdk: -1),
  ])
  # extraLen sits after rect(16) + channels(2+3*6) + sig(4) + blend(4)
  # + opacity/clipping/flags/filler(4) = record start + 48
  let extraAt = 26 + 4 + 4 + 4 + 4 + 2 + 48
  check data[extraAt ..< extraAt + 4] == @[byte(0), 0, 0, 12]
  data[extraAt .. extraAt + 3] = @[byte(0x01), 0, 0, 0] # 16MB claim
  expect(PsdError):
    discard readPsdBytes(data, limits = tinyLimits(sectionBytes = 64))

test "composite channel volume capped, not just dimensions":
  # 4x4 with 16 channels: 256 samples > 200 cap, but 4x4 dims pass.
  var data: seq[byte] = @[]
  putHeader(data, 4, 4, 16)
  putU32BE(data, 0) # colormode len
  putU32BE(data, 0) # resources len
  putU32BE(data, 0) # layer section len
  putU16BE(data, 0) # raw composite
  for _ in 0 ..< 4 * 4 * 16:
    data.add(7)
  expect(PsdError):
    discard readPsdBytes(data, limits = tinyLimits(pixels = 200))
  check readPsdBytes(data).hasComposite
