## ZIP (deflate) channel decoding, Compression 2 and 3.
##
## Photoshop ZIP stores each planar channel (composite) or each layer
## channel deflated with zlib (RFC 1950). `ZipPrediction` (3) adds a
## per-row delta: each byte after the first in a row is stored as the
## difference from its left neighbor, matching libpsd's
## `psd_unzip_with_prediction` (reimplemented here against the
## `zlib` Nim package already used by `pdf/filters`).
##
## v1 scope: 8-bit only. Decompressed size is always known up front
## (`w*h` per channel), so output is bounded by `Limits` before
## inflating and truncated/overlong streams raise `PsdError`.

import zlib/zlib_api
import ./types

proc zipFail(msg: string) {.noreturn.} =
  raise newException(PsdError, msg)

proc toString(data: openArray[byte]): string =
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc inflateOnce(data: string, windowBits: ZWindowBits,
    expectedLen: int): string =
  if data.len == 0:
    if expectedLen == 0:
      return ""
    zipFail("ZIP: empty input for " & $expectedLen & " expected bytes")
  var zs = ZStream(
    next_in: cast[ptr uint8](unsafeAddr data[0]),
    avail_in: data.len.cuint)
  var r = zs.inflateInit2(windowBits)
  if r != Z_OK:
    zipFail("ZIP: inflateInit failed (" & $r & ")")
  var cap = max(expectedLen, 64)
  result = newString(cap)
  var total = 0
  var lastIn: culong = 0
  while true:
    if total == cap:
      # Bound runaway output: Photoshop streams decode to exactly
      # expectedLen; allow one doubling for zlib framing slack.
      if cap >= expectedLen * 2 + 16:
        discard zs.inflateEnd()
        zipFail("ZIP: output exceeds expected " & $expectedLen & " bytes")
      cap = min(cap * 2, expectedLen * 2 + 16)
      result.setLen(cap)
    zs.next_out = cast[ptr uint8](addr result[total])
    zs.avail_out = cuint(cap - total)
    r = zs.inflate(Z_FINISH)
    total = cap - int(zs.avail_out)
    if r == Z_STREAM_END:
      break
    if r == Z_NEED_DICT:
      discard zs.inflateEnd()
      zipFail("ZIP: preset dictionary not supported")
    let roomLeft = int(zs.avail_out) > 0
    if (r == Z_OK or r == Z_BUF_ERROR) and
        (not roomLeft or zs.total_in > lastIn):
      lastIn = zs.total_in
      continue
    let msg = if zs.msg == nil: $r else: $zs.msg
    discard zs.inflateEnd()
    if (r == Z_OK or r == Z_BUF_ERROR) and zs.avail_in == 0 and roomLeft:
      break # stream end without marker; accept exact-size output
    zipFail("ZIP: inflate failed (" & msg & ")")
  discard zs.inflateEnd()
  result.setLen(total)

proc inflateZlib*(data: openArray[byte], expectedLen: int): seq[byte] =
  ## Inflate one zlib (or raw deflate fallback) stream, requiring
  ## exactly `expectedLen` output bytes.
  if expectedLen < 0:
    zipFail("ZIP: negative expected length")
  if expectedLen == 0:
    return @[]
  let s = toString(data)
  var inflated = ""
  # zlib-wrapped (RFC 1950) first, raw deflate (RFC 1951) fallback,
  # mirroring pdf/filters.flateDecode.
  if s.len >= 2 and (byte(s[0]) and 0x0F) == 8 and
      (int(byte(s[0])) * 256 + int(byte(s[1]))) mod 31 == 0:
    try:
      inflated = inflateOnce(s, Z_DEFAULT_WINDOW_BITS, expectedLen)
    except PsdError:
      inflated = inflateOnce(s, Z_RAW_DEFLATE, expectedLen)
  else:
    inflated = inflateOnce(s, Z_RAW_DEFLATE, expectedLen)
  if inflated.len != expectedLen:
    zipFail("ZIP: decoded " & $inflated.len & " bytes, want " &
      $expectedLen)
  toBytes(inflated)

proc deflateZlib*(data: openArray[byte]): seq[byte] =
  ## zlib-wrapped deflate (test fixtures + future writers).
  if data.len == 0:
    return @[]
  let s = toString(data)
  var zs = ZStream(
    next_in: cast[ptr uint8](unsafeAddr s[0]),
    avail_in: s.len.cuint)
  var r = zs.deflateInit(Z_DEFAULT_COMPRESSION)
  if r != Z_OK:
    zipFail("ZIP: deflateInit failed (" & $r & ")")
  let bound = int(zs.deflateBound(s.len.culong)) + 16
  var output = newString(bound)
  zs.next_out = cast[ptr uint8](addr output[0])
  zs.avail_out = cuint(bound)
  r = zs.deflate(Z_FINISH)
  let total = bound - int(zs.avail_out)
  discard zs.deflateEnd()
  if r != Z_STREAM_END:
    zipFail("ZIP: deflate failed (" & $r & ")")
  output.setLen(total)
  toBytes(output)

proc undoPrediction*(data: var seq[byte], width, height: int) =
  ## In-place horizontal delta decode for 8-bit `ZipPrediction`.
  if width <= 0 or height <= 0:
    return
  if data.len != width * height:
    zipFail("ZIP prediction: size " & $data.len & " != " &
      $width & "x" & $height)
  for y in 0 ..< height:
    let base = y * width
    for x in 1 ..< width:
      data[base + x] = byte((int(data[base + x]) +
        int(data[base + x - 1])) and 0xFF)

proc applyPrediction*(data: var seq[byte], width, height: int) =
  ## Forward delta (encoder side, fixtures only).
  if width <= 0 or height <= 0:
    return
  for y in countdown(height - 1, 0):
    let base = y * width
    for x in countdown(width - 1, 1):
      data[base + x] = byte((int(data[base + x]) -
        int(data[base + x - 1])) and 0xFF)

proc unzipChannel*(data: openArray[byte], width, height: int,
    prediction: bool): seq[byte] =
  ## Inflate one channel plane (`width*height` bytes), applying the
  ## delta when `prediction` (Compression 3) is set.
  if width <= 0 or height <= 0:
    return @[]
  result = inflateZlib(data, width * height)
  if prediction:
    undoPrediction(result, width, height)
