import unittest
import std/options
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/layers
import ../src/opengraphics/psd/resources
import ../src/opengraphics/psd/types

const Fixture = "tests/data/01.psd"

test "real file header and structure":
  let doc = openPsd(Fixture)
  check doc.width == 700
  check doc.height == 700
  check doc.header.channels == 3
  check doc.header.depth == 8
  check doc.header.colorMode == Rgb
  check doc.hasComposite
  check doc.composite.width == 700
  check doc.composite.height == 700
  check doc.compositeCompression == Rle
  check doc.layerCount == 4
  check doc.resources.blocks.len == 25

test "real file layers":
  let doc = openPsd(Fixture)
  check doc.layers[0].displayName() == "Rectangle 1"
  check doc.layers[1].displayName() == "nim-lang"
  check doc.layers[2].displayName() == "Efficient, expressive, elegant"
  check doc.layers[3].displayName() ==
    "Nim is a statically typed compiled systems programming language"
  for l in doc.layers:
    check l.isVisible()
    check l.channels.len == 4
    check l.channelPixels.len == 4
    for p in l.channelPixels:
      check p.len == l.width() * l.height()
  # layer rects (left, top, right, bottom)
  check doc.layers[1].left == 299
  check doc.layers[1].top == 616
  check doc.layers[1].right == 403
  check doc.layers[1].bottom == 645

test "real file pixels are sane":
  let doc = openPsd(Fixture)
  # composite is not blank: spans full range
  var rMin = 255
  var rMax = 0
  for p in doc.composite.data:
    if int(p.r) < rMin: rMin = int(p.r)
    if int(p.r) > rMax: rMax = int(p.r)
  check rMin == 0
  check rMax == 255
  check doc.composite.data[0] == Rgba(r: 0, g: 0, b: 0, a: 255)
  # smart-object layer center is opaque white, corner transparent
  let img1 = doc.layers[1].layerPixelsToImage()
  check img1.width == 104
  check img1.height == 29
  check img1.data[0].a == 0
  check img1.data[img1.data.len div 2] == Rgba(r: 255, g: 255, b: 255, a: 255)
  # type layer carries its engine data preserved
  var hasTySh = false
  for b in doc.layers[2].extraBlocks:
    if b.key == "TySh":
      hasTySh = true
      check b.data.len == 10344
  check hasTySh

test "real file thumbnail and icc":
  let doc = openPsd(Fixture)
  check doc.resources.hasIccProfile()
  let icc = doc.resources.iccProfile()
  check icc.len == 3144
  # first u32 is the profile size and matches the payload
  check icc[0] == 0 and icc[1] == 0
  check (int(icc[0]) shl 24 or int(icc[1]) shl 16 or
    int(icc[2]) shl 8 or int(icc[3])) == icc.len
  let thumb = doc.resources.getThumbnail()
  check thumb.isSome
  check thumb.get.width == 160
  check thumb.get.height == 160
  check thumb.get.format == 1
  check thumb.get.bitsPerPixel == 24
  check thumb.get.jpeg.len == 4398
  check thumb.get.jpeg[0] == 0xFF and thumb.get.jpeg[1] == 0xD8
  check thumb.get.jpeg[^2] == 0xFF and thumb.get.jpeg[^1] == 0xD9

test "real file skipThumbnail drops payload":
  let doc = openPsd(Fixture, ReadOptions(skipThumbnail: true))
  check doc.resources.getThumbnail().isNone
  check doc.hasComposite # unrelated sections still decode

test "real file has flat layer tree":
  let doc = openPsd(Fixture)
  let tree = doc.layerTree()
  check tree.len == 4
  for n in tree:
    check not n.isGroup
    check n.children.len == 0
