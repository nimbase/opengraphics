## Leaf decoders for AEP chunk payloads (big endian).
##
## All readers take an explicit offset and bounds check before access,
## raising AepError on overrun. Field offsets live with the callers
## (comp.nim, layers.nim, items.nim) next to the spec tables.

import ./types

proc checkBounds*(data: openArray[byte], off, n: int, what: string) =
  if off < 0 or n < 0 or off + n > data.len:
    raise newException(AepError, "truncated " & what & " at offset " &
      $off & " (need " & $n & ", len " & $data.len & ")")

proc readU8At*(data: openArray[byte], off: int, what: string): uint8 =
  checkBounds(data, off, 1, what)
  data[off]

proc readU16BEAt*(data: openArray[byte], off: int, what: string): uint16 =
  checkBounds(data, off, 2, what)
  (uint16(data[off]) shl 8) or uint16(data[off + 1])

proc readS16BEAt*(data: openArray[byte], off: int, what: string): int16 =
  cast[int16](readU16BEAt(data, off, what))

proc readU32BEAt*(data: openArray[byte], off: int, what: string): uint32 =
  checkBounds(data, off, 4, what)
  (uint32(data[off]) shl 24) or (uint32(data[off + 1]) shl 16) or
    (uint32(data[off + 2]) shl 8) or uint32(data[off + 3])

proc readF32BEAt*(data: openArray[byte], off: int, what: string): float32 =
  let u = readU32BEAt(data, off, what)
  cast[float32](u)

proc readF64BEAt*(data: openArray[byte], off: int, what: string): float64 =
  checkBounds(data, off, 8, what)
  var u: uint64 = 0
  for i in 0 ..< 8:
    u = (u shl 8) or uint64(data[off + i])
  cast[float64](u)

proc readFourCCAt*(data: openArray[byte], off: int, what: string): string =
  checkBounds(data, off, 4, what)
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = char(data[off + i])

proc readString0*(data: openArray[byte], off, maxLen: int,
    what: string): string =
  ## NUL terminated string. Stops at the first NUL or maxLen, so junk
  ## after the terminator (renamed shorter values) is ignored.
  checkBounds(data, off, 1, what)
  result = ""
  var i = 0
  while i < maxLen and off + i < data.len:
    let c = data[off + i]
    if c == 0:
      break
    result.add(char(c))
    inc i

proc stripTrailingNul*(s: string): string =
  ## Match names (`tdmn`) are NUL padded. Keep bytes up to the first NUL.
  let p = s.find('\0')
  if p < 0: s else: s[0 ..< p]

proc flagSet*(flags: openArray[byte], byteIdx, bit: int): bool =
  ## Spec flag layout: byte 0 is the most significant (file order).
  if byteIdx < 0 or byteIdx >= flags.len or bit < 0 or bit > 7:
    return false
  (flags[byteIdx] and byte(1 shl bit)) != 0
