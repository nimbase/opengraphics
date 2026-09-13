## PackBits (PSD RLE) decode. Same algorithm as Macintosh
## PackBits / TIFF: per scanline, length byte n as int8:
## 0..127 -> copy next n+1 bytes literally,
## -127..-1 -> repeat next byte (1-n) times,
## -128 -> no-op.

import ./types

proc decodePackBitsRow*(src: openArray[byte], pos: var int, expectedLen: int): seq[byte] =
  result = newSeqOfCap[byte](expectedLen)
  while result.len < expectedLen:
    if pos >= src.len:
      raise newException(PsdError, "truncated PackBits row")
    let n = cast[int8](src[pos])
    inc pos
    if n >= 0:
      let count = int(n) + 1
      if pos + count > src.len:
        raise newException(PsdError, "truncated PackBits literal")
      for i in 0 ..< count:
        result.add(src[pos + i])
      pos += count
    elif n != -128:
      let count = 1 - int(n)
      if pos >= src.len:
        raise newException(PsdError, "truncated PackBits repeat")
      let v = src[pos]
      inc pos
      for _ in 0 ..< count:
        result.add(v)
    # -128: no-op
  if result.len != expectedLen:
    raise newException(PsdError, "PackBits row length mismatch")

proc encodePackBitsRow*(row: openArray[byte]): seq[byte] =
  ## Simple literal-only encoder (used for test fixtures).
  ## Splits into chunks of at most 128 literal bytes.
  var i = 0
  while i < row.len:
    let chunk = min(128, row.len - i)
    result.add(byte(chunk - 1))
    for j in 0 ..< chunk:
      result.add(row[i + j])
    i += chunk
