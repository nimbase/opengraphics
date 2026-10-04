## Limit enforcement.
##
## Every cap runs on a value straight off the wire, ahead of the allocation or
## read it guards, so these tests mostly check *where* the check fires rather
## than that it fires: a file whose declared length overruns the input must be
## rejected by the length check rather than by a crash later on.

import std/options
import unittest
import ../src/opengraphics/psd
import ./psd_support

proc headerOnly(width, height, channels = 3): string =
  ## 26-byte header alone: limit checks fire before anything else is read, so
  ## no further section bytes are needed.
  var w = initWriter()
  w.putStr4("8BPS")
  w.putU16(1)
  for _ in 0 ..< 6: w.putU8(0)
  w.putU16(uint16(channels))
  w.putU32(uint32(height))
  w.putU32(uint32(width))
  w.putU16(8)
  w.putU16(3)
  w.toString()

proc tinyLimits(sectionBytes = 512_000_000, blocks = 10_000,
    pixels = 100_000_000, layers = 1000): Limits =
  Limits(maxWidth: 30000, maxHeight: 30000, maxPixels: pixels,
    maxLayers: layers, maxSectionBytes: sectionBytes, maxBlocks: blocks,
    maxDecodedBytes: 2_147_483_648)

test "checkDimensions unit behavior":
  # The promoted core uses the reference's defaults: 300000 per side with a
  # 2^30 pixel cap, so 30001 is legal here even though old v1 limits rejected it.
  let lim = defaultLimits()
  lim.checkDimensions(1, 1, "document")
  lim.checkDimensions(30_001, 10, "document")
  expect(PsdError):
    lim.checkDimensions(0, 10, "document")
  expect(PsdError):
    lim.checkDimensions(300_001, 10, "document")
  expect(PsdError):
    lim.checkDimensions(10, 300_001, "document")
  # PSD itself is capped at 30000 by the spec, PSB is not
  expect(PsdError):
    Header(version: Version.Psd, channels: 3, height: 10, width: 30_001,
      depth: 8, colorMode: ColorMode(kind: cmRgb)).validate()
  Header(version: Version.Psb, channels: 3, height: 10, width: 30_001,
    depth: 8, colorMode: ColorMode(kind: cmRgb)).validate()

test "checkDimensions rejects a size over the pixel cap":
  # 30000 x 30000 is inside the spec maximum but 900M pixels is not.
  expect(PsdError):
    tinyLimits().checkDimensions(30_000, 30_000, "document")

test "checkSection unit behavior":
  tinyLimits().checkSection(0, "thing")
  expect(PsdError):
    tinyLimits().checkSection(-1, "thing")
  expect(PsdError):
    tinyLimits(sectionBytes = 64).checkSection(65, "thing")

test "checkCount unit behavior":
  tinyLimits().checkCount(4, 100, 16, "things")
  expect(PsdError):
    tinyLimits().checkCount(-1, 100, 16, "things")
  expect(PsdError):
    tinyLimits().checkCount(1000, 100, 16, "things")

test "oversize document dimensions rejected without allocation":
  expect(PsdError):
    discard readPsdBytes(headerOnly(30_001, 10))
  expect(PsdError):
    discard readPsdBytes(headerOnly(10_000, 10_001))

test "tight custom limits reject the real fixture":
  expect(PsdError):
    discard openPsd("tests/data/01.psd",
      limits = tinyLimits(pixels = 100))

test "layer count over limit rejected before records parse":
  var w = initWriter()
  w.put(headerOnly(1, 1))
  w.putU32(0) # colormode len
  w.putU32(0) # resources len
  var section = initWriter()
  section.putU32(2)    # layer info len: the count field only
  section.putI16(3)    # 3 layers declared, none follow
  w.putU32(uint32(4))
  w.put(section.toString())
  w.putU32(0) # global mask len
  expect(PsdError):
    discard readPsdBytes(w.toString(), limits = tinyLimits(layers = 2))

test "oversize color mode data rejected before read":
  var w = initWriter()
  w.put(headerOnly(4, 4))
  w.putU32(16) # claims 16 bytes, none follow
  expect(PsdError):
    discard readPsdBytes(w.toString(), limits = tinyLimits(sectionBytes = 8))

test "oversize resources section rejected before parse":
  var w = initWriter()
  w.put(headerOnly(4, 4))
  w.putU32(0)    # colormode len
  w.putU32(100)  # claims 100 bytes, none follow
  expect(PsdError):
    discard readPsdBytes(w.toString(), limits = tinyLimits(sectionBytes = 64))

test "resource block count capped":
  var w = initWriter()
  w.put(headerOnly(2, 2))
  w.putU32(0) # colormode len
  var res = initWriter()
  for i in 0 ..< 4:
    res.putStr4("8BIM")
    res.putU16(uint16(1000 + i))
    res.writePascal("", 2)
    res.putU32(0) # empty payload
  let resBytes = res.toString()
  w.putU32(uint32(resBytes.len))
  w.put(resBytes)
  w.putU32(0) # layer section len
  w.putU16(0) # raw composite
  for _ in 0 ..< 4 * 4 * 3: w.putU8(1)
  let data = w.toString()
  expect(PsdError):
    discard readPsdBytes(data, limits = tinyLimits(blocks = 2))
  check readPsdBytes(data).file.resources.len == 4

test "oversize layer section rejected before records parse":
  var w = initWriter()
  w.put(headerOnly(2, 2))
  w.putU32(0)      # colormode len
  w.putU32(0)      # resources len
  w.putU32(10_000) # claims 10KB, none follow
  expect(PsdError):
    discard readPsdBytes(w.toString(), limits = tinyLimits(sectionBytes = 64))

test "composite channel volume capped, not just dimensions":
  # 4x4 with 16 channels: 256 samples is over a 200 cap, but 4x4 passes the
  # dimension check, so only a channel-aware check can catch this.
  var w = initWriter()
  w.put(headerOnly(4, 4, 16))
  w.putU32(0) # colormode len
  w.putU32(0) # resources len
  w.putU32(0) # layer section len
  w.putU16(0) # raw composite
  for _ in 0 ..< 4 * 4 * 16: w.putU8(7)
  let data = w.toString()
  expect(PsdError):
    discard readPsdBytes(data, limits = tinyLimits(pixels = 200))
  check readPsdBytes(data).hasComposite

test "default limits accept the real fixture":
  check openPsd("tests/data/01.psd").layerCount == 4