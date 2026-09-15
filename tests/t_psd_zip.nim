import unittest
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/layers
import ../src/opengraphics/psd/zip
import ../src/opengraphics/psd/types
import psd_support

test "zip round-trip without prediction":
  let plane = @[byte(10), byte(20), byte(30), byte(40),
    byte(50), byte(60), byte(70), byte(80)]
  let comp = deflateZlib(plane)
  check unzipChannel(comp, 4, 2, false) == plane

test "zip prediction round-trip":
  let plane = @[byte(10), byte(12), byte(200), byte(205),
    byte(5), byte(5), byte(250), byte(3)]
  var tmp = plane
  applyPrediction(tmp, 4, 2)
  let comp = deflateZlib(tmp)
  check unzipChannel(comp, 4, 2, true) == plane

test "composite zip decodes":
  let r = @[byte(255), byte(0), byte(10), byte(20)]
  let g = @[byte(0), byte(255), byte(30), byte(40)]
  let b = @[byte(0), byte(0), byte(50), byte(60)]
  let bytes = buildPsd(2, 2, 3, @[r, g, b], false, @[], true, false)
  let doc = readPsdBytes(bytes)
  check doc.compositeCompression == ZipNoPrediction
  check doc.composite.width == 2
  check doc.composite.data[0].r == 255
  check doc.composite.data[1].r == 0
  check doc.composite.data[2].g == 30
  check doc.composite.data[3].b == 60

test "composite zip with prediction decodes":
  let r = @[byte(10), byte(12), byte(200), byte(205)]
  let bytes = buildPsd(2, 2, 1, @[r], false, @[], true, true)
  let doc = readPsdBytes(bytes)
  check doc.compositeCompression == ZipPrediction
  check doc.composite.data[0].r == 10
  check doc.composite.data[1].r == 12
  check doc.composite.data[2].r == 200
  check doc.composite.data[3].r == 205

test "layer zip decodes and skips":
  let plane = @[byte(7), byte(8), byte(9), byte(10)]
  let spec = TestLayerSpec(name: "z", top: 0, left: 0, bottom: 2,
    right: 2, planes: @[plane], channelIds: @[int16(0)], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0, lsct: -1, lsdk: -1,
    useZip: true, zipPrediction: false)
  let bytes = buildPsd(2, 2, 1, @[plane], false, @[spec])
  let doc = readPsdBytes(bytes)
  check doc.layerCount == 1
  check doc.layers[0].channelCompression == ZipNoPrediction
  check doc.layers[0].channelPixels[0] == plane
  let skipped = readPsdBytes(bytes, ReadOptions(skipLayerImageData: true))
  check skipped.layers[0].channelPixels[0].len == 0
  check skipped.hasComposite

test "layer zip prediction decodes":
  let plane = @[byte(100), byte(110), byte(50), byte(60)]
  let spec = TestLayerSpec(name: "zp", top: 0, left: 0, bottom: 2,
    right: 2, planes: @[plane], channelIds: @[int16(0)], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0, lsct: -1, lsdk: -1,
    useZip: true, zipPrediction: true)
  let doc = readPsdBytes(buildPsd(2, 2, 1, @[plane], false, @[spec]))
  check doc.layers[0].channelCompression == ZipPrediction
  check doc.layers[0].channelPixels[0] == plane

test "truncated zip raises PsdError":
  expect(PsdError):
    discard unzipChannel(@[byte(0x78), byte(0x9C), byte(1)], 4, 2, false)
