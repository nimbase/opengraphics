import unittest
import ../src/opengraphics/psd/rle

test "literal run decodes":
  var pos = 0
  # n=2 -> 3 literal bytes
  let row = decodePackBitsRow(@[byte(2), 10, 20, 30], pos, 3)
  check row == @[byte(10), byte(20), byte(30)]

test "repeat run decodes":
  var pos = 0
  # n=-2 (0xFE) -> repeat next byte 3 times
  let row = decodePackBitsRow(@[byte(0xFE), byte(7)], pos, 3)
  check row == @[byte(7), byte(7), byte(7)]

test "round-trip literal encoder":
  let src = @[byte(1), 2, 3, 4, 5]
  let enc = encodePackBitsRow(src)
  var pos = 0
  check decodePackBitsRow(enc, pos, 5) == src

test "repeat data from real encoder output decodes":
  # hand-encoded: repeat 9 four times then literals 1,2
  var pos = 0
  let row = decodePackBitsRow(@[byte(0xFD), byte(9), byte(1), byte(1), byte(2)], pos, 6)
  check row == @[byte(9), byte(9), byte(9), byte(9), byte(1), byte(2)]
