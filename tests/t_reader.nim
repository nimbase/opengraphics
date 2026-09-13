import unittest
import ../src/opengraphics/psd/reader
import ../src/opengraphics/psd/types

test "u16/u32 big-endian and bounds":
  var r = initReader(@[byte(0x12), 0x34, 0x00, 0x00, 0x00, 0x41])
  check r.readU16BE() == 0x1234'u16
  check r.readU32BE() == 0x00000041'u32
  check r.atEnd()

test "truncated raises PsdError":
  var r = initReader(@[byte(1)])
  expect(PsdError):
    discard r.readU32BE()

test "pascal even padding and pad4":
  # "AB": len 1? use name "hi": 1+2=3 -> 1 pad byte
  var r = initReader(@[byte(2), byte('h'), byte('i'), byte(0)])
  check r.readPascalStringEvenPadded() == "hi"
  # layer name "a": 1+1=2 -> pad to 4 = 2 pad bytes
  var r2 = initReader(@[byte(1), byte('a'), byte(0), byte(0)])
  check r2.readPascalStringPad4() == "a"
