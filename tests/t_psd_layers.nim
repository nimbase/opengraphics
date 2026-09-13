import unittest
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/layers
import ./psd_support

test "layer records parse with names and pixels":
  let red = @[byte(255), 0]
  let grn = @[byte(0), 255]
  let blu = @[byte(0), 0]
  let spec = TestLayerSpec(name: "L1", top: 0, left: 0, bottom: 1, right: 2,
    planes: @[red, grn, blu], channelIds: @[int16(0), 1, 2],
    useRle: false, blendKey: "norm", opacity: 128, flags: 0)
  let data = buildPsd(2, 1, 3, @[@[byte(1), 2], @[byte(3), 4], @[byte(5), 6]],
    layers = @[spec])
  let doc = readPsdBytes(data)
  check doc.layerCount == 1
  let l = doc.layers[0]
  check l.name == "L1"
  check l.displayName() == "L1"
  check l.width() == 2
  check l.height() == 1
  check l.blendKey == "norm"
  check l.opacity == 128
  check l.isVisible()
  check l.channelPixels.len == 3
  let img = l.layerPixelsToImage()
  check img.width == 2
  check img.data[0].r == 255
  check img.data[1].g == 255

test "hidden flag marks invisible":
  let p = @[byte(9)]
  let spec = TestLayerSpec(name: "H", top: 0, left: 0, bottom: 1, right: 1,
    planes: @[p, p, p], channelIds: @[int16(0), 1, 2],
    useRle: false, blendKey: "norm", opacity: 255, flags: 2)
  let data = buildPsd(1, 1, 3, @[p, p, p], layers = @[spec])
  let doc = readPsdBytes(data)
  check not doc.layers[0].isVisible()
  check doc.visibleLayers().len == 0
  check doc.layerByName("H") == 0
  check doc.layerByName("missing") == -1

test "RLE layer channels decode":
  let r = @[byte(10), 20]
  let g = @[byte(30), 40]
  let b = @[byte(50), 60]
  let spec = TestLayerSpec(name: "R", top: 0, left: 0, bottom: 1, right: 2,
    planes: @[r, g, b], channelIds: @[int16(0), 1, 2],
    useRle: true, blendKey: "norm", opacity: 255, flags: 0)
  let data = buildPsd(2, 1, 3, @[r, g, b], layers = @[spec])
  let doc = readPsdBytes(data)
  let img = doc.layers[0].layerPixelsToImage()
  check img.data[0] == Rgba(r: 10, g: 30, b: 50, a: 255)
  check img.data[1] == Rgba(r: 20, g: 40, b: 60, a: 255)

test "skipLayerImageData keeps structure":
  let p = @[byte(1), 2]
  let spec = TestLayerSpec(name: "S", top: 0, left: 0, bottom: 1, right: 2,
    planes: @[p, p, p], channelIds: @[int16(0), 1, 2],
    useRle: false, blendKey: "norm", opacity: 255, flags: 0)
  # composite raw planes 2x1
  let data = buildPsd(2, 1, 3, @[p, p, p], layers = @[spec])
  let doc = readPsdBytes(data, ReadOptions(skipLayerImageData: true))
  check doc.layerCount == 1
  check doc.layers[0].name == "S"
  check doc.hasComposite
