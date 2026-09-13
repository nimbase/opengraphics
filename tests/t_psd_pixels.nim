import std/os
import std/strutils
import unittest
import ../src/opengraphics/psd/pixels
import ../src/opengraphics/psd/types

proc readU16LE(d: string, pos: int): uint16 =
  (uint16(byte(d[pos])) or (uint16(byte(d[pos + 1])) shl 8))

proc readU32LE(d: string, pos: int): uint32 =
  (uint32(byte(d[pos])) or (uint32(byte(d[pos + 1])) shl 8) or
    (uint32(byte(d[pos + 2])) shl 16) or (uint32(byte(d[pos + 3])) shl 24))

proc readI32LE(d: string, pos: int): int32 =
  cast[int32](readU32LE(d, pos))

test "bmp stride pads rows to 4 bytes":
  check bmpStride(1) == 4
  check bmpStride(2) == 8
  check bmpStride(3) == 12
  check bmpStride(4) == 12
  check bmpStride(700) == 2100

test "bmp header fields and size":
  var img = initImageBuf(3, 2)
  let path = getTempDir() / "psd_test_3x2.bmp"
  img.saveBmp(path)
  let d = readFile(path)
  check d.len == 54 + bmpStride(3) * 2
  check d[0] == 'B' and d[1] == 'M'
  check readU32LE(d, 2) == uint32(d.len)
  check readU32LE(d, 10) == 54
  check readU32LE(d, 14) == 40
  check readI32LE(d, 18) == 3
  check readI32LE(d, 22) == 2
  check readU16LE(d, 26) == 1
  check readU16LE(d, 28) == 24
  check readU32LE(d, 30) == 0 # BI_RGB

test "bmp pixels are BGR, padded, bottom-up":
  var img = initImageBuf(3, 2)
  # top row: red, green, blue; bottom row: white, black, gray(10,20,30)
  img.setPixel(0, 0, Rgba(r: 255, g: 0, b: 0, a: 255))
  img.setPixel(1, 0, Rgba(r: 0, g: 255, b: 0, a: 255))
  img.setPixel(2, 0, Rgba(r: 0, g: 0, b: 255, a: 255))
  img.setPixel(0, 1, Rgba(r: 255, g: 255, b: 255, a: 255))
  img.setPixel(1, 1, Rgba(r: 0, g: 0, b: 0, a: 255))
  img.setPixel(2, 1, Rgba(r: 10, g: 20, b: 30, a: 200)) # alpha dropped
  let path = getTempDir() / "psd_test_order.bmp"
  img.saveBmp(path)
  let d = readFile(path)
  let stride = bmpStride(3)
  # first stored row is image bottom row: white, black, gray + 3 pad bytes
  check byte(d[54]) == 255 and byte(d[55]) == 255 and byte(d[56]) == 255
  check byte(d[57]) == 0 and byte(d[58]) == 0 and byte(d[59]) == 0
  check byte(d[60]) == 30 and byte(d[61]) == 20 and byte(d[62]) == 10
  check byte(d[63]) == 0 and byte(d[64]) == 0 and byte(d[65]) == 0
  # second stored row is image top row: red, green, blue as BGR
  let o = 54 + stride
  check byte(d[o]) == 0 and byte(d[o+1]) == 0 and byte(d[o+2]) == 255
  check byte(d[o+3]) == 0 and byte(d[o+4]) == 255 and byte(d[o+5]) == 0
  check byte(d[o+6]) == 255 and byte(d[o+7]) == 0 and byte(d[o+8]) == 0

test "ppm header and size":
  var img = initImageBuf(2, 1)
  img.setPixel(0, 0, Rgba(r: 1, g: 2, b: 3, a: 255))
  img.setPixel(1, 0, Rgba(r: 4, g: 5, b: 6, a: 255))
  let path = getTempDir() / "psd_test.ppm"
  img.savePpm(path)
  let d = readFile(path)
  check d.startsWith("P6\n2 1\n255\n")
  check d.len == 11 + 6
  check byte(d[11]) == 1 and byte(d[12]) == 2 and byte(d[13]) == 3
  check byte(d[14]) == 4 and byte(d[15]) == 5 and byte(d[16]) == 6

test "empty image raises for both writers":
  let empty = ImageBuf(width: 0, height: 0, data: @[])
  expect(PsdError):
    empty.savePpm(getTempDir() / "psd_test_empty.ppm")
  expect(PsdError):
    empty.saveBmp(getTempDir() / "psd_test_empty.bmp")
