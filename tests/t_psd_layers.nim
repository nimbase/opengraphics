## Layer records end to end: geometry, names, flags and decoded pixels.
##
## Everything here is lazy in the new model, so these tests also pin the
## contract that a layer's samples are only decoded when asked for.

import std/options
import unittest
import ../src/opengraphics/psd
import ./psd_support

proc layerDoc(spec: TestLayerSpec, w, h: int,
    planes: seq[seq[byte]] = @[]): Document =
  let comp = if planes.len > 0: planes
             else: @[newSeq[byte](w * h), newSeq[byte](w * h), newSeq[byte](w * h)]
  readPsdBytes(buildPsd(w, h, 3, comp, layers = @[spec]))

test "a layer record carries its geometry, name and flags":
  let red = @[byte(255), 0]
  let grn = @[byte(0), 255]
  let blu = @[byte(0), 0]
  let spec = TestLayerSpec(name: "L1", top: 0, left: 0, bottom: 1, right: 2,
    planes: @[red, grn, blu], channelIds: @[int16(0), 1, 2], useRle: false,
    blendKey: "norm", opacity: 128, flags: 0)
  let doc = layerDoc(spec, 2, 1, @[@[byte(1), 2], @[byte(3), 4], @[byte(5), 6]])
  check doc.layerCount == 1
  let l = doc.layers[0]
  check l.name == "L1"        # legacy Pascal name
  check l.name() == "L1"      # display name, preferring `luni`
  check l.rect == Rect(top: 0, left: 0, bottom: 1, right: 2)
  check l.rect.width() == 2
  check l.rect.height() == 1
  check l.blendMode == "norm"
  check l.opacity == 128
  check l.isVisible()
  check l.channels.len == 3
  check l.isFolder() == false
  check l.isDivider() == false

test "the layers of a document de-interleave into pixels":
  let red = @[byte(255), 0]
  let grn = @[byte(0), 255]
  let blu = @[byte(0), 0]
  let spec = TestLayerSpec(name: "L1", top: 0, left: 0, bottom: 1, right: 2,
    planes: @[red, grn, blu], channelIds: @[int16(0), 1, 2], useRle: false,
    blendKey: "norm", opacity: 128, flags: 0)
  let doc = layerDoc(spec, 2, 1, @[@[byte(1), 2], @[byte(3), 4], @[byte(5), 6]])
  let li = doc.layerImage(0)
  check li.img.width == 2
  check li.img.height == 1
  check li.img.data[0] == Rgba(r: 255, g: 0, b: 0, a: 255)
  check li.img.data[1] == Rgba(r: 0, g: 255, b: 0, a: 255)
  # with no alpha channel the layer is opaque, not transparent
  check li.img.data[0].a == 255

test "the hidden flag marks a layer invisible":
  let p = @[byte(9)]
  let spec = TestLayerSpec(name: "H", top: 0, left: 0, bottom: 1, right: 1,
    planes: @[p, p, p], channelIds: @[int16(0), 1, 2], useRle: false,
    blendKey: "norm", opacity: 255, flags: 2)
  let doc = layerDoc(spec, 1, 1, @[p, p, p])
  check not doc.layers[0].isVisible()
  check doc.visibleLayers().len == 0

test "layers can be found by name":
  let p = @[byte(9)]
  let spec = TestLayerSpec(name: "H", top: 0, left: 0, bottom: 1, right: 1,
    planes: @[p, p, p], channelIds: @[int16(0), 1, 2], useRle: false,
    blendKey: "norm", opacity: 255, flags: 2)
  let doc = layerDoc(spec, 1, 1, @[p, p, p])
  check doc.layerByName("H") == 0
  check doc.layerByName("missing") == -1

test "RLE layer channels decode to the same pixels":
  let r = @[byte(10), 20]
  let g = @[byte(30), 40]
  let b = @[byte(50), 60]
  let spec = TestLayerSpec(name: "R", top: 0, left: 0, bottom: 1, right: 2,
    planes: @[r, g, b], channelIds: @[int16(0), 1, 2], useRle: true,
    blendKey: "norm", opacity: 255, flags: 0)
  let doc = layerDoc(spec, 2, 1, @[r, g, b])
  let li = doc.layerImage(0)
  check li.img.data[0] == Rgba(r: 10, g: 30, b: 50, a: 255)
  check li.img.data[1] == Rgba(r: 20, g: 40, b: 60, a: 255)

test "ZIP layer channels decode to the same pixels":
  let r = @[byte(10), 20]
  let g = @[byte(30), 40]
  let b = @[byte(50), 60]
  let spec = TestLayerSpec(name: "Z", top: 0, left: 0, bottom: 1, right: 2,
    planes: @[r, g, b], channelIds: @[int16(0), 1, 2], useZip: true,
    blendKey: "norm", opacity: 255, flags: 0)
  let doc = readPsdBytes(buildPsd(2, 1, 3, @[r, g, b], layers = @[spec],
    useZip = true))
  let li = doc.layerImage(0)
  check li.img.data[0] == Rgba(r: 10, g: 30, b: 50, a: 255)
  check li.img.data[1] == Rgba(r: 20, g: 40, b: 60, a: 255)

test "skipping the composite leaves the layer stack intact":
  let p = @[byte(1), 2]
  let spec = TestLayerSpec(name: "S", top: 0, left: 0, bottom: 1, right: 2,
    planes: @[p, p, p], channelIds: @[int16(0), 1, 2], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0)
  let bytes = buildPsd(2, 1, 3, @[p, p, p], layers = @[spec])
  let full = readPsdBytes(bytes)
  let skipped = readPsdBytes(bytes, ReadOptions(skipCompositeImageData: true))
  check not skipped.hasComposite
  check skipped.layerCount == full.layerCount
  check skipped.layers[0].name() == full.layers[0].name()
  check skipped.layers[0].channels.len == full.layers[0].channels.len
  # the bytes are still there for the lossless model
  check skipped.file.imageData.data.len == 6

test "an out-of-range layer index raises":
  let p = @[byte(9)]
  let spec = TestLayerSpec(name: "H", top: 0, left: 0, bottom: 1, right: 1,
    planes: @[p, p, p], channelIds: @[int16(0), 1, 2], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0)
  let doc = layerDoc(spec, 1, 1, @[p, p, p])
  expect(PsdError):
    discard doc.layerImage(5)
  expect(PsdError):
    discard doc.layerImage(-1)