## Big-endian binary reader and writer with bounds checking.
##
## `Reader` scopes a window (`start`..`stop`) over one shared source buffer, so
## `sub` hands out a nested view without copying. This is what lets every
## section be parsed against its own boundary: the parser cannot accidentally
## read past the end of a sub-section, and a length prefix is validated once
## at the point it is consumed.
##
## The root is a `Source`, so the whole file may be a memory mapping and no
## part of parsing ever touches the heap except the parse tree itself. Payloads
## leave the reader as `Span`, a pair of offsets, which is what makes the
## resulting `PsdFile` O(record count) rather than O(file size).
##
## All multi-byte values are big-endian, matching the PSD wire format. There
## is no little-endian support anywhere in the crate.

import std/unicode

import ./error
import ./span

# `bytes`, `peekRest` and `initReader(Span)` all hand out a Span, so anything
# using io needs span's API too.
export span

type
  Reader* = object
    ## `root` is shared by every sub-reader of one file and never copied.
    root*: Source
    start*: int  ## inclusive; where this view begins
    stop*: int   ## exclusive; where this view ends
    pos*: int    ## absolute cursor, always within start..stop

  Writer* = object
    ## Growable output buffer. `beginLen`/`endLen` reserve a length field
    ## that is patched once the payload length is known, so sections are
    ## written without a second pass.
    buf*: seq[byte]

proc initReaderFrom*(source: Source): Reader =
  ## A reader over a whole source, which may be a memory mapping.
  Reader(root: source, start: 0, stop: source.size, pos: 0)

proc initReader*(data: string): Reader {.inline.} =
  ## Wraps the caller's buffer without copying it.
  initReaderFrom(newStringSource(data))

proc initReader*(data: seq[byte]): Reader {.inline.} =
  ## One copy at the boundary; sub-readers below stay copy-free.
  initReaderFrom(newBytesSource(data))

proc initReader*(data: Span): Reader {.inline.} =
  ## A reader over an existing span, so a sub-section can be re-parsed on its
  ## own without copying it out of the parent.
  Reader(root: data.src, start: data.start, stop: data.stop, pos: data.start)

proc pos*(r: Reader): int {.inline.} = r.pos

proc offset*(r: Reader): int {.inline.} =
  ## Cursor relative to this view's own start, rather than to the source.
  ##
  ## Needed wherever a sub-reader is handed to something that indexes a `Span`:
  ## span offsets are relative, and a sub-view's `pos` is not.
  r.pos - r.start

proc remaining*(r: Reader): int {.inline.} = r.stop - r.pos
proc isEmpty*(r: Reader): bool {.inline.} = r.pos >= r.stop
proc len*(r: Reader): int {.inline.} = r.stop - r.start

proc atEnd*(r: Reader): bool {.inline.} = r.pos >= r.stop

proc peekRest*(r: Reader): Span {.inline.} =
  ## Everything left in this view, as a window. Never copies.
  Span(src: r.root, start: r.pos, stop: r.stop)

proc matchesAt*(r: Reader, off: int, lit: string): bool {.inline.} =
  ## True when the bytes at `pos + off` equal `lit`, compared in place.
  ##
  ## Reading a fixed-size prefix through `peekRest` would materialise a view of
  ## the whole remaining region, which makes a loop over a block region
  ## quadratic in its size. This stays O(len(lit)) with no allocation.
  if off < 0 or lit.len > r.remaining - off:
    return false
  let p = cast[ptr UncheckedArray[char]](r.root.base)
  if p == nil:
    return false
  for i in 0 ..< lit.len:
    if p[r.pos + off + i] != lit[i]:
      return false
  true

proc require*(r: Reader, n: int) {.inline.} =
  if n < 0 or n > r.remaining:
    eof(n - r.remaining, r.pos)

proc bytes*(r: var Reader, n: int): Span =
  ## The next `n` bytes as a window into the root. Allocates nothing: the
  ## window is two integers and a refcount bump.
  if n == 0:
    return Span(src: r.root, start: r.pos, stop: r.pos)
  r.require(n)
  result = Span(src: r.root, start: r.pos, stop: r.pos + n)
  r.pos += n

proc skip*(r: var Reader, n: int) =
  if n == 0:
    return
  r.require(n)
  r.pos += n

proc sub*(r: var Reader, n: int64): Reader =
  ## A nested view over the next `n` bytes, consuming them from `r`. The
  ## child shares `root`, so this allocates nothing. Reading past the
  ## child's `stop` raises `UnexpectedEof` naming the child's own bounds.
  if n < 0 or n > r.remaining.int64:
    eof(int(n - r.remaining), r.pos)
  result = Reader(root: r.root, start: r.pos, stop: r.pos + int(n), pos: r.pos)
  r.pos += int(n)

proc readU8*(r: var Reader): uint8 =
  r.require(1)
  result = r.root.byteAt(r.pos)
  inc r.pos

proc readI8*(r: var Reader): int8 =
  cast[int8](r.readU8())

proc readU16BE*(r: var Reader): uint16 =
  r.require(2)
  let p = r.pos
  result = (uint16(r.root.byteAt(p)) shl 8) or uint16(r.root.byteAt(p + 1))
  r.pos += 2

proc readI16BE*(r: var Reader): int16 =
  cast[int16](r.readU16BE())

proc readU32BE*(r: var Reader): uint32 =
  r.require(4)
  let p = r.pos
  result = (uint32(r.root.byteAt(p)) shl 24) or
    (uint32(r.root.byteAt(p + 1)) shl 16) or
    (uint32(r.root.byteAt(p + 2)) shl 8) or
    uint32(r.root.byteAt(p + 3))
  r.pos += 4

proc readI32BE*(r: var Reader): int32 =
  cast[int32](r.readU32BE())

proc readU64BE*(r: var Reader): uint64 =
  r.require(8)
  var bits: uint64 = 0
  let p = r.pos
  for i in 0 ..< 8:
    bits = (bits shl 8) or uint64(r.root.byteAt(p + i))
  r.pos += 8
  result = bits

proc readI64BE*(r: var Reader): int64 =
  cast[int64](r.readU64BE())

proc readF64BE*(r: var Reader): float64 =
  cast[float64](r.readU64BE())

proc readF32BE*(r: var Reader): float32 =
  r.require(4)
  var bits: uint32 = 0
  let p = r.pos
  for i in 0 ..< 4:
    bits = (bits shl 8) or uint32(r.root.byteAt(p + i))
  r.pos += 4
  cast[float32](bits)

proc readArray4*(r: var Reader): array[4, byte] =
  r.require(4)
  let p = r.pos
  for i in 0 ..< 4:
    result[i] = r.root.byteAt(p + i)
  r.pos += 4

proc readStr4*(r: var Reader): string =
  ## A 4-byte tag such as `"8BIM"`, `"norm"` or `"luni"`. Owned, because a key
  ## is compared and stored as a `string` and four bytes is not worth a span.
  r.require(4)
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = char(r.root.byteAt(r.pos + i))
  r.pos += 4

proc lenField*(r: var Reader, long: bool): int64 =
  ## A section length: 32-bit in PSD, 64-bit in PSB. Note that PSB widens
  ## only *some* lengths (the layer and mask section, layer info, per-layer
  ## channel data, and 13 tagged-block keys); everything else stays 32-bit
  ## even in a PSB file.
  if not long:
    return int64(r.readU32BE())
  let v = r.readU64BE()
  # Every 64-bit length field in a PSD is untrusted input, and the sign bit is
  # set on plenty of corrupt bytes. Range-converting that to int64 raises a
  # RangeDefect, which escapes as a crash rather than a `PsdError`; reinter-
  # preting it instead would yield a *negative* count that every later
  # comparison would read as "smaller than what is here" and walk off the end.
  # No real length reaches 2^63, so refuse the field outright.
  if v > uint64(high(int64)):
    invalid("64-bit length field has its sign bit set (" & $v & ")")
  int64(v)

proc readPascal*(r: var Reader, align: int): string =
  ## Pascal string: one length byte, that many bytes, then zero padding so
  ## the total is a multiple of `align`. `align` is 2 for image-resource
  ## names and 4 for layer names.
  let n = int(r.readU8())
  let payload = r.bytes(n)
  let consumed = 1 + n
  if align > 1:
    let padded = ((consumed + align - 1) div align) * align
    if padded > consumed:
      r.skip(padded - consumed)
  payload.clone

proc readUnicodeUnits*(r: var Reader): seq[uint16] =
  ## Photoshop unicode string: u32 code-unit count, then that many big-endian
  ## u16 units. Units are returned raw; trailing NULs are the caller's
  ## business (see `descUnicodeToString`).
  let n = int64(r.readU32BE())
  if n < 0 or n > r.remaining.int64 div 2:
    eof(int(n * 2 - r.remaining), r.pos)
  result = newSeq[uint16](int(n))
  for i in 0 ..< int(n):
    result[i] = r.readU16BE()

proc isValidUtf8*(s: string): bool {.inline.} =
  ## `std/unicode.validateUtf8` returns -1 for valid and 0 for invalid, which
  ## is easy to read backwards. This wraps it so call sites say what they mean.
  validateUtf8(s) != 0

proc decodeLegacyName*(raw: string): string =
  ## Layer / resource names are legacy bytes: UTF-8 when valid, else
  ## Latin-1. Never fails, so an odd name still round-trips as text.
  if isValidUtf8(raw):
    return raw
  result = newString(raw.len)
  for i, c in raw:
    result[i] = char(ord(c))

proc appendUtf8(s: var string, cp: int) =
  ## One code point as UTF-8. Unpaired surrogates are passed through as
  ## U+FFFD by the caller's range checks.
  if cp < 0x80:
    s.add(char(cp))
  elif cp < 0x800:
    s.add(char(0xC0 or (cp shr 6)))
    s.add(char(0x80 or (cp and 0x3F)))
  elif cp < 0x10000:
    s.add(char(0xE0 or (cp shr 12)))
    s.add(char(0x80 or ((cp shr 6) and 0x3F)))
    s.add(char(0x80 or (cp and 0x3F)))
  else:
    s.add(char(0xF0 or (cp shr 18)))
    s.add(char(0x80 or ((cp shr 12) and 0x3F)))
    s.add(char(0x80 or ((cp shr 6) and 0x3F)))
    s.add(char(0x80 or (cp and 0x3F)))

proc unicodeToString*(units: openArray[uint16]): string =
  ## UTF-16BE units to UTF-8, dropping every trailing NUL unit first (that
  ## is how Photoshop terminates names) and replacing unpaired surrogates
  ## with U+FFFD.
  var endIdx = units.len
  while endIdx > 0 and units[endIdx - 1] == 0:
    dec endIdx
  var i = 0
  while i < endIdx:
    let c = int(units[i])
    inc i
    if c >= 0xD800 and c <= 0xDBFF:
      if i < endIdx and units[i] >= 0xDC00 and units[i] <= 0xDFFF:
        appendUtf8(result, 0x10000 + ((c - 0xD800) shl 10) +
          (int(units[i]) - 0xDC00))
        inc i
      else:
        appendUtf8(result, 0xFFFD)
    elif c >= 0xDC00 and c <= 0xDFFF:
      appendUtf8(result, 0xFFFD)
    else:
      appendUtf8(result, c)

proc encodeLegacyName*(s: string): string =
  ## Inverse of `decodeLegacyName` for writing: anything outside printable
  ## ASCII becomes `?`, and the result is clipped to the 255 bytes a
  ## Pascal length byte can express.
  result = newString(min(s.len, 255))
  for i in 0 ..< result.len:
    let c = s[i]
    result[i] = if c >= ' ' and c <= '~': c else: '?'

# --- Writer -----------------------------------------------------------------

proc initWriter*(capHint = 0): Writer =
  ## A growable output buffer. `capHint` reserves room up front so writing a
  ## large payload is one allocation rather than a geometric regrow-and-copy.
  Writer(buf: newSeqOfCap[byte](max(capHint, 64)))

proc len*(w: Writer): int {.inline.} = w.buf.len

proc reserve*(w: var Writer, extra: int) =
  ## Ensure room for `extra` more bytes without an intermediate buffer.
  if extra > 0:
    w.buf.setLen(w.buf.len + extra)

proc put*(w: var Writer, b: string) =
  ## Append in one copy. Walking the source byte at a time into an unreserved
  ## buffer reallocated and memcpied the whole output on every doubling.
  if b.len == 0:
    return
  let n = w.buf.len
  w.reserve(b.len)
  copyMem(addr w.buf[n], unsafeAddr b[0], b.len)

proc put*(w: var Writer, b: openArray[byte]) =
  if b.len == 0:
    return
  let n = w.buf.len
  w.reserve(b.len)
  copyMem(addr w.buf[n], unsafeAddr b[0], b.len)

proc put*(w: var Writer, s: Span) =
  ## Straight from the window into the output. A round trip therefore moves
  ## each byte once, straight from the file's buffer into the written result.
  let n = s.len
  if n == 0:
    return
  let at = w.buf.len
  w.reserve(n)
  copyMem(addr w.buf[at], s.base, n)

proc putU8*(w: var Writer, v: uint8) {.inline.} =
  w.buf.add(byte(v))

proc putI8*(w: var Writer, v: int8) {.inline.} =
  w.putU8(cast[uint8](v))

proc putU16*(w: var Writer, v: uint16) {.inline.} =
  w.buf.add(byte(v shr 8))
  w.buf.add(byte(v and 0xFF))

proc putI16*(w: var Writer, v: int16) {.inline.} =
  w.putU16(cast[uint16](v))

proc putU32*(w: var Writer, v: uint32) {.inline.} =
  w.buf.add(byte(v shr 24))
  w.buf.add(byte((v shr 16) and 0xFF))
  w.buf.add(byte((v shr 8) and 0xFF))
  w.buf.add(byte(v and 0xFF))

proc putI32*(w: var Writer, v: int32) {.inline.} =
  w.putU32(cast[uint32](v))

proc putU64*(w: var Writer, v: uint64) {.inline.} =
  for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
    w.buf.add(byte((v shr shift) and 0xFF))

proc putI64*(w: var Writer, v: int64) {.inline.} =
  w.putU64(cast[uint64](v))

proc putF64*(w: var Writer, v: float64) {.inline.} =
  w.putU64(cast[uint64](v))

proc putF32*(w: var Writer, v: float32) {.inline.} =
  var bits: uint32 = 0
  copyMem(addr bits, unsafeAddr v, 4)
  for shift in [24, 16, 8, 0]:
    w.buf.add(byte((bits shr shift) and 0xFF))

proc putArray4*(w: var Writer, b: array[4, byte]) {.inline.} =
  for x in b:
    w.buf.add(x)

proc putBytes*(w: var Writer, b: openArray[byte]) {.inline.} =
  ## A fixed-width byte array whose length is not always 4 (the header's
  ## six reserved bytes, for instance).
  for x in b:
    w.buf.add(x)

proc putStr4*(w: var Writer, s: string) =
  ## A 4-byte tag. Raises when `s` is not exactly four bytes, since a short
  ## or long tag would silently shift everything after it.
  if s.len != 4:
    invalid("expected a 4-byte tag, got '" & s & "'")
  w.put(s)

proc putStr3*(w: var Writer, s: string) =
  ## A 3-byte tag. The format is not uniform: `iSO` ("isolated group") is
  ## written with three bytes where every other tagged-block key has four, so
  ## a writer that assumes four shifts the length field of every block
  ## containing one.
  if s.len != 3:
    invalid("expected a 3-byte tag, got '" & s & "'")
  w.put(s)

proc putLen*(w: var Writer, v: int64, long: bool) =
  ## A length field. In PSD a value past 2^32-1 is unrepresentable, so the
  ## writer reports it rather than truncating.
  if long:
    w.putI64(v)
  else:
    if v < 0 or v > int64(high(uint32)):
      limitExceeded("section too large for a 32-bit length (use PSB)")
    w.putU32(uint32(v))

proc beginLen*(w: var Writer, long: bool): int =
  ## Reserve a length field and return the offset to hand to `endLen`.
  let at = w.buf.len
  if long: w.putI64(0) else: w.putU32(0)
  at

proc endLen*(w: var Writer, at: int, long: bool) =
  ## Back-patch the length reserved by `beginLen` with the payload size.
  let hdr = if long: 8 else: 4
  let payload = w.buf.len - at - hdr
  if long:
    for i in 0 ..< 8:
      w.buf[at + i] = byte((uint64(payload) shr ((7 - i) * 8)) and 0xFF)
  else:
    for i in 0 ..< 4:
      w.buf[at + i] = byte((uint32(payload) shr ((3 - i) * 8)) and 0xFF)

proc writePascal*(w: var Writer, name: string, align: int) =
  ## Inverse of `readPascal`. Names are clipped to 255 bytes and padded with
  ## NULs. Note this always writes zero pad bytes; see the plan's
  ## byte-exactness caveats.
  let n = min(name.len, 255)
  w.putU8(uint8(n))
  w.put(name[0 ..< n])
  let consumed = 1 + n
  if align > 1:
    let padded = ((consumed + align - 1) div align) * align
    for _ in consumed ..< padded:
      w.putU8(0)

proc writeUnicodeUnits*(w: var Writer, units: openArray[uint16]) =
  ## Inverse of `readUnicodeUnits`, without a trailing NUL (callers add one
  ## only where the format requires it).
  w.putU32(uint32(units.len))
  for u in units:
    w.putU16(u)

proc toUtf16Units*(s: string): seq[uint16] =
  ## UTF-8 string to UTF-16 code units. Characters above the BMP become a
  ## surrogate pair, which is what Photoshop writes for names and texts.
  ## Invalid input decodes lossily and never runs past the end.
  result = @[]
  var i = 0
  while i < s.len:
    let n = max(1, min(runeLenAt(s, i), s.len - i))
    let cp = runeAt(s, i).int32
    if cp > 0xFFFF:
      let v = cp - 0x10000
      result.add(uint16(0xD800 + (v shr 10)))
      result.add(uint16(0xDC00 + (v and 0x3FF)))
    else:
      result.add(uint16(cp))
    i += n

proc writeUnicode*(w: var Writer, s: string) =
  ## A unicode string with no trailing NUL, matching the majority of
  ## on-disk uses.
  w.writeUnicodeUnits(toUtf16Units(s))

proc toBytes*(w: Writer): seq[byte] =
  ## The written bytes. Callers usually want `toString` instead.
  result = w.buf

proc toString*(w: Writer): string =
  if w.buf.len == 0:
    return ""
  result = newString(w.buf.len)
  copyMem(addr result[0], unsafeAddr w.buf[0], w.buf.len)
