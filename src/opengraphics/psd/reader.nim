## Minimal big-endian binary reader with bounds checking.

import ./types

type
  BinReader* = object
    data*: seq[byte]
    pos*: int

proc initReader*(data: seq[byte]): BinReader =
  BinReader(data: data, pos: 0)

proc initReader*(data: string): BinReader =
  var s = newSeq[byte](data.len)
  for i, c in data:
    s[i] = byte(c)
  BinReader(data: s, pos: 0)

proc remaining*(r: BinReader): int {.inline.} =
  r.data.len - r.pos

proc atEnd*(r: BinReader): bool {.inline.} =
  r.pos >= r.data.len

proc require*(r: BinReader, n: int) {.inline.} =
  if n < 0 or r.pos + n > r.data.len:
    raise newException(PsdError, "truncated PSD: need " & $n &
      " bytes at offset " & $r.pos & " (len " & $r.data.len & ")")

proc readU8*(r: var BinReader): uint8 =
  r.require(1)
  result = r.data[r.pos]
  inc r.pos

proc readU16BE*(r: var BinReader): uint16 =
  r.require(2)
  result = (uint16(r.data[r.pos]) shl 8) or uint16(r.data[r.pos + 1])
  r.pos += 2

proc readU32BE*(r: var BinReader): uint32 =
  r.require(4)
  result = (uint32(r.data[r.pos]) shl 24) or
    (uint32(r.data[r.pos + 1]) shl 16) or
    (uint32(r.data[r.pos + 2]) shl 8) or
    uint32(r.data[r.pos + 3])
  r.pos += 4

proc readI16BE*(r: var BinReader): int16 =
  cast[int16](r.readU16BE())

proc readI32BE*(r: var BinReader): int32 =
  cast[int32](r.readU32BE())

proc readBytes*(r: var BinReader, n: int): seq[byte] =
  if n == 0:
    return @[]
  r.require(n)
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

proc readStr*(r: var BinReader, n: int): string =
  if n == 0:
    return ""
  r.require(n)
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(r.data[r.pos + i])
  r.pos += n

proc skip*(r: var BinReader, n: int) =
  if n == 0:
    return
  r.require(n)
  r.pos += n

proc readPascalStringEvenPadded*(r: var BinReader): string =
  ## Pascal string used by image resource block names:
  ## 1 length byte, then chars, padded so total is even.
  ## A null name is two bytes of zero.
  let n = int(r.readU8())
  var s = ""
  if n > 0:
    s = r.readStr(n)
  # total so far is 1 + n; pad to even
  if (1 + n) mod 2 != 0:
    r.skip(1)
  result = s

proc readPascalStringPad4*(r: var BinReader): string =
  ## Layer name: Pascal string padded to a multiple of 4.
  let n = int(r.readU8())
  var s = ""
  if n > 0:
    s = r.readStr(n)
  let consumed = 1 + n
  let padded = ((consumed + 3) div 4) * 4
  let pad = padded - consumed
  if pad > 0:
    r.skip(pad)
  result = s
