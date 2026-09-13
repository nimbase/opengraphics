import unittest
import ../src/opengraphics/psd/reader
import ../src/opengraphics/psd/header
import ../src/opengraphics/psd/types

test "valid header parses":
  var data: seq[byte] = @[]
  for c in "8BPS": data.add(byte(c))
  data.add(0); data.add(1) # version
  for _ in 0 ..< 6: data.add(0)
  data.add(0); data.add(3) # channels
  data.add(0); data.add(0); data.add(0); data.add(2) # h=2
  data.add(0); data.add(0); data.add(0); data.add(3) # w=3
  data.add(0); data.add(8) # depth
  data.add(0); data.add(3) # RGB
  var r = initReader(data)
  let h = parseHeader(r)
  check h.channels == 3
  check h.height == 2
  check h.width == 3
  check h.depth == 8
  check h.colorMode == Rgb

test "bad signature rejected":
  var r = initReader(@[byte('X'), byte('X'), byte('X'), byte('X'),
    byte(0), byte(1), 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 8, 0, 3])
  expect(PsdError):
    discard parseHeader(r)

test "PSB version rejected":
  var data: seq[byte] = @[]
  for c in "8BPS": data.add(byte(c))
  data.add(0); data.add(2)
  for _ in 0 ..< 6: data.add(0)
  data.add(0); data.add(3)
  data.add(0); data.add(0); data.add(0); data.add(1)
  data.add(0); data.add(0); data.add(0); data.add(1)
  data.add(0); data.add(8)
  data.add(0); data.add(3)
  var r = initReader(data)
  expect(PsdError):
    discard parseHeader(r)
