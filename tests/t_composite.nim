import unittest
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/types
import ./support

test "flat RGB raw composite decodes with spot checks":
  # 2x2: R plane 10,20,30,40; G 50,60,70,80; B 90,100,110,120
  let r = @[byte(10), 20, 30, 40]
  let g = @[byte(50), 60, 70, 80]
  let b = @[byte(90), 100, 110, 120]
  let data = buildPsd(2, 2, 3, @[r, g, b])
  let doc = readPsdBytes(data)
  check doc.width == 2
  check doc.height == 2
  check doc.hasComposite
  check doc.composite.data[0] == Rgba(r: 10, g: 50, b: 90, a: 255)
  check doc.composite.data[3] == Rgba(r: 40, g: 80, b: 120, a: 255)

test "flat RGB RLE composite decodes":
  let r = @[byte(5), 5, 5, 5]
  let g = @[byte(6), 6, 6, 6]
  let b = @[byte(7), 7, 7, 7]
  let data = buildPsd(2, 2, 3, @[r, g, b], useRle = true)
  let doc = readPsdBytes(data)
  check doc.composite.data[0] == Rgba(r: 5, g: 6, b: 7, a: 255)
  check doc.composite.data[3] == Rgba(r: 5, g: 6, b: 7, a: 255)

test "grayscale composite maps to rgb":
  let gray = @[byte(11), 12, 13, 14]
  var data = buildPsd(2, 2, 1, @[gray])
  # fix header mode to grayscale (offset 24)
  data[24] = 0
  data[25] = 1
  let doc = readPsdBytes(data)
  check doc.composite.data[0] == Rgba(r: 11, g: 11, b: 11, a: 255)

test "grayscale+alpha composite maps correctly":
  let gray = @[byte(11), 12, 13, 14]
  let alpha = @[byte(255), 0, 128, 64]
  var data = buildPsd(2, 2, 2, @[gray, alpha])
  data[24] = 0
  data[25] = 1
  let doc = readPsdBytes(data)
  check doc.composite.data[0] == Rgba(r: 11, g: 11, b: 11, a: 255)
  check doc.composite.data[1] == Rgba(r: 12, g: 12, b: 12, a: 0)
  check doc.composite.data[3] == Rgba(r: 14, g: 14, b: 14, a: 64)

test "unsupported compression rejected":
  var data = buildPsd(1, 1, 3, @[@[byte(1)], @[byte(2)], @[byte(3)]])
  # composite compression at: 26 + 4 + 4 + 4 = 38
  data[38] = 0
  data[39] = 2 # ZIP without prediction
  expect(PsdError):
    discard readPsdBytes(data)

test "skipComposite option avoids decode":
  let data = buildPsd(1, 1, 3, @[@[byte(1)], @[byte(2)], @[byte(3)]])
  let doc = readPsdBytes(data, ReadOptions(skipCompositeImageData: true))
  check not doc.hasComposite
