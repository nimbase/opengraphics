import unittest
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/layers
import ../src/opengraphics/psd/types
import psd_support

proc maskSpec(top, left, bottom, right: int32, color = 255'u8,
    flags = 0'u8): TestMaskSpec =
  TestMaskSpec(present: true, top: top, left: left, bottom: bottom,
    right: right, defaultColor: color, flags: flags)

proc maskedLayer(mask: TestMaskSpec, useRle = false, useZip = false,
    prediction = false): Document =
  ## 4x4 pixel layer with a 4x3 mask (12 mask bytes vs 16 layer bytes,
  ## so mask-vs-layer sizing mistakes surface immediately).
  let px = @[byte(10), 11, 12, 13, 14, 15, 16, 17,
    byte(18), 19, 20, 21, 22, 23, 24, 25]
  let mp = @[byte(0), 30, 60, 90, 120, 150, 180, 210, 240, 255, 128, 64]
  let spec = TestLayerSpec(name: "m", top: 0, left: 0, bottom: 4,
    right: 4, planes: @[px, mp], channelIds: @[int16(0), int16(-2)],
    useRle: useRle, blendKey: "norm", opacity: 255, flags: 0,
    lsct: -1, lsdk: -1, useZip: useZip, zipPrediction: prediction,
    mask: mask)
  readPsdBytes(buildPsd(4, 4, 1, @[px], false, @[spec]))

test "no mask by default":
  let px = @[byte(1), 2, 3, 4]
  let spec = TestLayerSpec(name: "p", top: 0, left: 0, bottom: 2,
    right: 2, planes: @[px], channelIds: @[int16(0)], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0, lsct: -1, lsdk: -1)
  let doc = readPsdBytes(buildPsd(2, 2, 1, @[px], false, @[spec]))
  let l = doc.layers[0]
  check not l.hasMask()
  check not l.maskEnabled()
  check l.maskChannelIndex() == -1
  check l.maskData().len == 0
  check l.maskRaw.len == 0
  check l.maskWidth() == 0
  check l.maskHeight() == 0

test "20-byte mask parses rect, color and flags":
  let doc = maskedLayer(maskSpec(10, 20, 13, 24, 0, 0b101))
  let l = doc.layers[0]
  check l.hasMask()
  check l.maskEnabled()
  check l.mask.top == 10
  check l.mask.left == 20
  check l.mask.bottom == 13
  check l.mask.right == 24
  check l.maskWidth() == 4
  check l.maskHeight() == 3
  check l.mask.defaultColor == 0
  check l.mask.relative
  check not l.mask.disabled
  check l.mask.invert
  check not l.mask.hasReal
  check l.maskRaw.len == 20

test "disabled mask reports enabled=false":
  let doc = maskedLayer(maskSpec(0, 0, 3, 4, 255, 0b10))
  check doc.layers[0].hasMask()
  check not doc.layers[0].maskEnabled()

test "36-byte mask parses real rect and flags":
  var m = maskSpec(0, 0, 3, 4)
  m.real = true
  m.realFlags = 0b1
  m.realDefault = 255
  m.realTop = 5
  m.realLeft = 6
  m.realBottom = 9
  m.realRight = 14
  let doc = maskedLayer(m)
  let l = doc.layers[0]
  check l.mask.hasReal
  check l.mask.realTop == 5
  check l.mask.realLeft == 6
  check l.mask.realBottom == 9
  check l.mask.realRight == 14
  check l.mask.realWidth() == 8
  check l.mask.realHeight() == 4
  check l.mask.realDefaultColor == 255
  check l.mask.realRelative
  check l.maskRaw.len == 36

test "raw mask channel decodes with mask dims":
  let doc = maskedLayer(maskSpec(0, 0, 3, 4))
  let l = doc.layers[0]
  check l.maskChannelIndex() == 1
  check l.maskData() == @[byte(0), 30, 60, 90, 120, 150, 180, 210,
    240, 255, 128, 64]
  # pixel plane is untouched (16 layer bytes, not 12)
  check l.channelPixels[0] == @[byte(10), 11, 12, 13, 14, 15, 16, 17,
    byte(18), 19, 20, 21, 22, 23, 24, 25]

test "rle mask channel decodes with mask dims":
  let doc = maskedLayer(maskSpec(0, 0, 3, 4), useRle = true)
  check doc.layers[0].maskData() == @[byte(0), 30, 60, 90, 120, 150,
    180, 210, 240, 255, 128, 64]

test "zip mask channel decodes with mask dims":
  for prediction in [false, true]:
    let doc = maskedLayer(maskSpec(0, 0, 3, 4), useZip = true,
      prediction = prediction)
    let l = doc.layers[0]
    check l.channelCompression == (if prediction: ZipPrediction
      else: ZipNoPrediction)
    check l.maskData() == @[byte(0), 30, 60, 90, 120, 150, 180, 210,
      240, 255, 128, 64]

test "skip-image path stays aligned past mask channels":
  let px = @[byte(10), 11, 12, 13, 14, 15, 16, 17,
    byte(18), 19, 20, 21, 22, 23, 24, 25]
  let mp = @[byte(0), 30, 60, 90, 120, 150, 180, 210, 240, 255, 128, 64]
  let spec = TestLayerSpec(name: "m", top: 0, left: 0, bottom: 4,
    right: 4, planes: @[px, mp], channelIds: @[int16(0), int16(-2)],
    useRle: false, blendKey: "norm", opacity: 255, flags: 0,
    lsct: -1, lsdk: -1, mask: maskSpec(0, 0, 3, 4))
  let bytes = buildPsd(4, 4, 1, @[px], false, @[spec])
  let doc = readPsdBytes(bytes, ReadOptions(skipLayerImageData: true))
  check doc.layers[0].hasMask()
  check doc.layers[0].maskData().len == 0
  check doc.hasComposite
  check doc.composite.data.len == 16

test "empty mask rect consumes payload without desync":
  let spec = TestLayerSpec(name: "e", top: 0, left: 0, bottom: 2,
    right: 2, planes: @[@[byte(1), 2, 3, 4], @[]],
    channelIds: @[int16(0), int16(-2)], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0, lsct: -1, lsdk: -1,
    mask: maskSpec(0, 0, 0, 0))
  let px = @[byte(1), 2, 3, 4]
  let doc = readPsdBytes(buildPsd(2, 2, 1, @[px], false, @[spec]))
  check doc.layers[0].hasMask()
  check doc.layers[0].maskData().len == 0
  check doc.hasComposite

test "truncated mask raises PsdError":
  var raw: seq[byte] = @[]
  for v in [byte(0), 0, 0, 0, 0, 0, 0, 0, 0, 0]: raw.add(v)
  let px = @[byte(1), 2, 3, 4]
  let spec = TestLayerSpec(name: "t", top: 0, left: 0, bottom: 2,
    right: 2, planes: @[px], channelIds: @[int16(0)], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0, lsct: -1, lsdk: -1,
    mask: TestMaskSpec(rawOverride: raw))
  expect(PsdError):
    discard readPsdBytes(buildPsd(2, 2, 1, @[px], false, @[spec]))

test "huge mask area rejected before channel decode":
  # 20-byte mask payload claiming a 20000x20000 mask; the -2 channel
  # carries only a stub payload, so the limit must fire first.
  var raw: seq[byte] = @[]
  putI32BE(raw, 0)
  putI32BE(raw, 0)
  putI32BE(raw, 20000)
  putI32BE(raw, 20000)
  raw.add(255)
  raw.add(0)
  raw.add(0)
  raw.add(0)
  let px = @[byte(1), 2, 3, 4]
  let spec = TestLayerSpec(name: "h", top: 0, left: 0, bottom: 2,
    right: 2, planes: @[px, @[byte(7)]],
    channelIds: @[int16(0), int16(-2)], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0, lsct: -1, lsdk: -1,
    mask: TestMaskSpec(rawOverride: raw))
  expect(PsdError):
    discard readPsdBytes(buildPsd(2, 2, 1, @[px], false, @[spec]))

test "global mask parses opacity and kind":
  var gm: seq[byte] = @[]
  putU16BE(gm, 0) # color space
  for _ in 0 ..< 4: putU16BE(gm, 0)
  putU16BE(gm, 100) # opacity
  gm.add(128) # kind: use per-layer value
  let px = @[byte(1), 2, 3, 4]
  let doc = readPsdBytes(buildPsd(2, 2, 1, @[px], globalMask = gm))
  check doc.layerInfo.globalMask.hasData
  check doc.layerInfo.globalMask.opacity == 100
  check doc.layerInfo.globalMask.kind == 128
  check doc.layerInfo.globalMaskRaw == gm

test "global mask absent by default":
  let px = @[byte(1), 2, 3, 4]
  let doc = readPsdBytes(buildPsd(2, 2, 1, @[px]))
  check not doc.layerInfo.globalMask.hasData

test "real fixture has no masks and still parses":
  let doc = openPsd("tests/data/01.psd")
  check doc.layerCount == 4
  for l in doc.layers:
    check not l.hasMask()
    check l.maskChannelIndex() == -1
    check l.maskData().len == 0
  check not doc.layerInfo.globalMask.hasData
