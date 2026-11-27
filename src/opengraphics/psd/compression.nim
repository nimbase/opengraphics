## Channel compression: Raw, RLE (PackBits) and ZIP with prediction.
##
## Photoshop stores every channel planar and big-endian: all of plane 0, then
## all of plane 1, and so on. This module is depth-agnostic; the sample width
## only matters for RLE row sizes and for the ZIP prediction transform.
##
## RLE row counts: one table covering every row of every plane. Counts are u16
## in PSD and u32 in PSB.
##
## ZIP prediction (`ZipPrediction`) is a per-row horizontal delta applied
## before deflation, undone after inflation:
##   depth 1, 8  byte-wise delta across the row
##   depth 16    big-endian u16 sample delta
##   depth 32    the row is split into 4 byte planes (MSB plane first) and the
##              whole buffer is then byte-delta'd
##
## Merged image data is a single zlib stream spanning all planes; prediction
## is applied per row across that whole planar buffer.

import std/os
import std/tempfiles

from archive/io import openInputBorrowed, openInputString, newOutput, take,
  inputLen, inputPos, readSpan
from archive/flate import inflateInto, inflateIntoFile, FlateError
from archive/zlibf import adler32Checksum, adler32Update, zlibCompressInto

import ./error
import ./header
import ./io

export span

const
  ## Ceiling on one decoded plane buffer.
  MaxDecodedBytes* = 1'i64 shl 31

type
  CompressionKind* {.pure.} = enum
    cRaw, cRle, cZip, cZipPrediction, cUnknown

  Compression* = object
    ## `Unknown` preserves a code we do not decode, so such data still
    ## round-trips byte for byte.
    case kind*: CompressionKind
    of cRaw: discard
    of cRle: discard
    of cZip: discard
    of cZipPrediction: discard
    of cUnknown: raw*: uint16

const
  Raw* = Compression(kind: cRaw)
  Rle* = Compression(kind: cRle)
  Zip* = Compression(kind: cZip)
  ZipPrediction* = Compression(kind: cZipPrediction)

proc compressionFromU16*(v: uint16): Compression =
  case v
  of 0'u16: Raw
  of 1'u16: Rle
  of 2'u16: Zip
  of 3'u16: ZipPrediction
  else: Compression(kind: cUnknown, raw: v)

proc toU16*(c: Compression): uint16 {.inline.} =
  case c.kind
  of cRaw: 0'u16
  of cRle: 1'u16
  of cZip: 2'u16
  of cZipPrediction: 3'u16
  of cUnknown: c.raw

proc `==`*(a, b: Compression): bool {.inline.} =
  ## Nim's derived equality cannot compare variant objects, and comparing the
  ## stored code covers both the known kinds and `Unknown`, where two different
  ## raw codes are genuinely different.
  a.toU16 == b.toU16

type
  PlaneLayout* = object
    ## The geometry needed to size and validate plane buffers.
    planes*: int
    width*: int
    height*: int
    depth*: int
    version*: Version

proc newPlaneLayout*(planes, width, height, depth: int,
    version: Version): PlaneLayout {.inline.} =
  PlaneLayout(planes: planes, width: width, height: height, depth: depth,
    version: version)

proc rowBytes*(l: PlaneLayout): int {.inline.} =
  header.rowBytes(l.width, l.depth)

proc rows*(l: PlaneLayout): int64 =
  ## Scanlines across every plane, which is also the RLE count-table length.
  int64(l.planes) * int64(l.height)

proc totalBytes*(l: PlaneLayout): int64 =
  l.rows() * int64(l.rowBytes())

proc decodedLen*(l: PlaneLayout): int =
  let total = l.totalBytes()
  if total > MaxDecodedBytes:
    limitExceeded("decoded size " & $total & " exceeds " & $MaxDecodedBytes)
  int(total)

proc countSize*(l: PlaneLayout): int {.inline.} =
  ## Width of one RLE row count: 2 in PSD, 4 in PSB.
  if l.version.isPsb(): 4 else: 2

type
  PackedRow* = object
    ## One decoded PackBits row plus the offset just past it.
    row*: string
    next*: int

# --- PackBits ---------------------------------------------------------------

proc packbitsDecodeInto*(src: Span, expected: int, dst: var string,
    dstOffset, start = 0): int =
  ## Macintosh PackBits / TIFF, the same scheme Photoshop uses for RLE.
  ## One length byte per run, signed:
  ##   0..127   copy the next n+1 bytes literally
  ##   -127..-1 repeat the next byte 1-n times
  ##   -128     no-op
  ## Decodes exactly `expected` bytes into `dst[dstOffset ..< dstOffset +
  ## expected]` and returns the offset just past the last source byte, so a
  ## caller can walk a shared count table.
  ##
  ## Decoding straight into the destination avoids the per-row temporary that
  ## made a full plane cost `height` allocations totalling the plane size again
  ## in transient garbage.
  var written = 0
  var p = start
  while written < expected:
    if p >= src.len:
      decompressFailed("PackBits row ended early")
    let n = cast[int8](src.byteAt(p))
    inc p
    if n >= 0:
      let count = int(n) + 1
      if p + count > src.len:
        decompressFailed("PackBits literal truncated")
      if written + count > expected:
        decompressFailed("PackBits literal overflows the row")
      copyMem(addr dst[dstOffset + written],
        cast[pointer](src.bytePtr(p)), count)
      written += count
      p += count
    elif n != -128:
      let count = 1 - int(n)
      if p >= src.len:
        decompressFailed("PackBits run truncated")
      if written + count > expected:
        decompressFailed("PackBits run overflows the row")
      let v = char(src.byteAt(p))
      # a run is at most 128 bytes, so filling in place beats allocating
      let stop = dstOffset + written + count
      while written + dstOffset < stop:
        dst[dstOffset + written] = v
        inc written
      inc p
    # -128 is a documented no-op
  p

proc packbitsDecode*(src: Span, expected: int,
    start = 0): PackedRow =
  ## `packbitsDecodeInto` into a fresh row. Kept for callers that want the row
  ## on its own; the plane decoder uses `packbitsDecodeInto` directly.
  if expected == 0:
    return PackedRow(row: "", next: start)
  var buf = newString(expected)
  result.next = packbitsDecodeInto(src, expected, buf, 0, start)
  result.row = buf

proc packbitsEncode*(src: string): string =
  ## Inverse of `packbitsDecode`. A run of 2 or more identical bytes becomes
  ## a repeat; anything else accumulates into literals, stopping early when a
  ## run of three begins so the encoder cannot straddle one. `-128` is never
  ## emitted. Worst case is one header byte per 128 literal bytes.
  let n = src.len
  var i = 0
  while i < n:
    var run = 1
    while i + run < n and run < 128 and src[i + run] == src[i]:
      inc run
    if run >= 2:
      # 1-run is negative; mask so the byte lands in 0..255 as PackBits wants
      result.add(char((1 - run) and 0xFF))
      result.add(src[i])
      i += run
    else:
      let start = i
      var len = 0
      while i < n and len < 128:
        # stop before a run of three, which the repeat form handles better
        if i + 2 < n and src[i] == src[i + 1] and src[i] == src[i + 2]:
          break
        inc i
        inc len
      if len == 0:
        # a run of three starts here but the run above was too short to use
        inc i
        len = 1
      result.add(char(len - 1))
      result.add(src[start ..< start + len])

# --- prediction -------------------------------------------------------------

proc predict*(buf: var string, l: PlaneLayout) =
  ## Forward per-row delta, applied before deflating.
  if l.width <= 0 or l.height <= 0:
    return
  let rb = l.rowBytes()
  case l.depth
  of 1, 8:
    # byte-wise delta across the whole row. For depth 8 the row is one byte
    # per pixel, but at depth 1 it is ceil(width/8) bytes, so the span must
    # be the row length rather than the pixel count.
    var y = 0
    while y < l.height:
      let base = y * rb
      var x = rb - 1
      while x >= 1:
        # wrapping byte delta; the mask keeps the result in 0..255
        buf[base + x] = char((ord(buf[base + x]) - ord(buf[base + x - 1])) and
          0xFF)
        dec x
      inc y
  of 16:
    var y = 0
    while y < l.height:
      let base = y * rb
      var x = l.width - 1
      while x >= 1:
        let a = (ord(buf[base + 2 * x]) shl 8) or ord(buf[base + 2 * x + 1])
        let b = (ord(buf[base + 2 * (x - 1)]) shl 8) or
          ord(buf[base + 2 * (x - 1) + 1])
        let d = (a - b) and 0xFFFF
        buf[base + 2 * x] = char(d shr 8)
        buf[base + 2 * x + 1] = char(d and 0xFF)
        dec x
      inc y
  of 32:
    # split each row into 4 byte planes (MSB plane first), then byte-delta
    # the whole row. The stored form *is* the shuffled, delta'd buffer;
    # `unpredict` un-deltas first and only then de-shuffles.
    var y = 0
    # one scratch row for the whole plane group, not one per row
    var scratch = newString(rb)
    while y < l.height:
      let base = y * rb
      var i = 0
      while i < l.width:
        for k in 0 ..< 4:
          scratch[k * l.width + i] = buf[base + 4 * i + k]
        inc i
      var x = rb - 1
      while x >= 1:
        scratch[x] = char((ord(scratch[x]) - ord(scratch[x - 1])) and 0xFF)
        dec x
      copyMem(addr buf[base], unsafeAddr scratch[0], rb)
      inc y
  else:
    unsupported("prediction for depth " & $l.depth)

proc unpredict*(buf: var string, l: PlaneLayout) =
  ## Inverse of `predict`.
  if l.width <= 0 or l.height <= 0:
    return
  let rb = l.rowBytes()
  case l.depth
  of 1, 8:
    var y = 0
    while y < l.height:
      let base = y * rb
      for x in 1 ..< rb:
        buf[base + x] = char((ord(buf[base + x]) + ord(buf[base + x - 1])) and
          0xFF)
      inc y
  of 16:
    var y = 0
    while y < l.height:
      let base = y * rb
      for x in 1 ..< l.width:
        let a = (ord(buf[base + 2 * x]) shl 8) or ord(buf[base + 2 * x + 1])
        let b = (ord(buf[base + 2 * (x - 1)]) shl 8) or
          ord(buf[base + 2 * (x - 1) + 1])
        let v = (a + b) and 0xFFFF
        buf[base + 2 * x] = char(v shr 8)
        buf[base + 2 * x + 1] = char(v and 0xFF)
      inc y
  of 32:
    var y = 0
    # one scratch row for the whole plane group, not one per row
    var scratch = newString(rb)
    while y < l.height:
      let base = y * rb
      copyMem(addr scratch[0], unsafeAddr buf[base], rb)
      for x in 1 ..< rb:
        scratch[x] = char((ord(scratch[x]) + ord(scratch[x - 1])) and 0xFF)
      # only now de-shuffle back into sample order
      var i = 0
      while i < l.width:
        for k in 0 ..< 4:
          buf[base + 4 * i + k] = scratch[k * l.width + i]
        inc i
      inc y
  else:
    unsupported("prediction for depth " & $l.depth)

# --- inflate (pure Nim via archive) -------------------------------------------

const ZipValidateMemCap* = 1 shl 20
  ## Streams at or below this decoded size validate in memory by reusing
  ## `zipDecompress`. Larger streams validate through a temp file so a
  ## hostile payload cannot turn parse-time validation into an
  ## unbounded allocation; the old zlib loop had the same property via
  ## a fixed 64 KiB scratch buffer.

proc looksZlib(data: Span): bool =
  ## The two-byte wrapper probe, unchanged from the zlib days: CM == 8
  ## (deflate) and the FCHECK mod-31 rule. Deliberately weaker than a
  ## full header validation so historically accepted streams keep
  ## decoding the same way.
  (data.byteAt(0) and 0x0F) == 8 and
    ((int(data.byteAt(0)) shl 8) + int(data.byteAt(1))) mod 31 == 0

proc checkBound(total, expected: int) =
  ## The same `expected * 2 + 16` ceiling the zlib loop enforced while
  ## growing its buffer: Photoshop streams decode to exactly `expected`,
  ## anything far past that is a decompression bomb.
  if total > expected * 2 + 16:
    decompressFailed("ZIP: output exceeds the expected " & $expected &
      " bytes")

proc verifyAdler(outBuf: string, data: Span, bodyEnd: int) =
  ## Check the zlib trailer at `bodyEnd`, when present. A stream cut
  ## inside the deflate body never gets here (inflation fails first);
  ## a stream cut inside the 4-byte trailer still decodes in full --
  ## the trailer is a checksum over already-decoded data, so dropping
  ## it loses no pixels (see the truncation sweep in t_psd_malformed).
  if data.len - bodyEnd >= 4:
    var want = 0'u32
    for i in 0 ..< 4:
      want = (want shl 8) or uint32(data.byteAt(bodyEnd + i))
    if adler32Checksum(outBuf) != want:
      decompressFailed("ZIP: checksum mismatch")

proc zipDecompress*(data: Span, expected: int): string =
  ## Inflate one stream, requiring exactly `expected` output bytes. Tries a
  ## zlib wrapper first and falls back to raw deflate, since a few writers
  ## emit unwrapped streams. A stream that inflates past `expected * 2 + 16`
  ## is a decompression bomb and is refused rather than buffered.
  ##
  ## Pure Nim (`archive` flate): the output is inflated one-shot and then
  ## bound-checked, where the old zlib loop refused incrementally. Error
  ## behavior is identical; only the transient allocation on adversarial
  ## input differs.
  if expected == 0:
    if data.len == 0:
      return ""
    decompressFailed("ZIP: empty input for 0 expected bytes")
  if data.len == 0:
    decompressFailed("ZIP: empty input for " & $expected & " expected bytes")
  # The zlib-wrapper probe reads two bytes, so a one-byte tail would index out
  # of range. It is a truncated stream either way.
  if data.len < 2:
    decompressFailed("ZIP: " & $data.len & " byte input for " & $expected &
      " expected bytes")
  let wrapped = looksZlib(data)

  let inp = openInputBorrowed(data.base, data.len)
  let dst = newOutput(min(expected, ZipValidateMemCap))
  if wrapped:
    discard readSpan(inp, 2)
  try:
    inflateInto(inp, dst)
  except FlateError as e:
    let partial = take(dst)
    # The old loop accepted a stream that ended without a marker when the
    # input was exhausted; keep accepting exact-size results, and turn
    # short output into a clean failure instead of a downstream crash.
    if partial.len != expected:
      decompressFailed("ZIP: inflate failed (" & e.msg & ")")
    return partial
  result = take(dst)
  checkBound(result.len, expected)
  if wrapped:
    verifyAdler(result, data, inputPos(inp))

proc zipValidateStreamToFile(data: Span, expected, bound: int) =
  ## Large-stream validation with bounded memory: inflate into a temp
  ## file (fixed 96 KiB scratch inside `archive`), then size-check and
  ## checksum the bytes back. The temp file is always removed.
  let (f, path) = createTempFile("opengraphics_zv_", ".bin")
  try:
    let inp = openInputBorrowed(data.base, data.len)
    discard readSpan(inp, 2) # zlib header, already probed by the caller
    let scratch = newOutput()
    let (total, _) = inflateIntoFile(inp, f, scratch)
    if total > bound:
      decompressFailed("ZIP: output exceeds the expected " & $expected &
        " bytes")
    if total != expected:
      decompressFailed("ZIP: inflated to " & $total & " bytes, expected " &
        $expected)
    let bodyEnd = inputPos(inp)
    if data.len - bodyEnd >= 4:
      var want = 0'u32
      for i in 0 ..< 4:
        want = (want shl 8) or uint32(data.byteAt(bodyEnd + i))
      flushFile(f)
      var rf = open(path, fmRead)
      try:
        var adler = 1'u32
        var chunk = newString(64 * 1024)
        while true:
          let n = readBuffer(rf, addr chunk[0], chunk.len)
          if n <= 0:
            break
          adler = adler32Update(adler, unsafeAddr chunk[0], n)
        if adler != want:
          decompressFailed("ZIP: checksum mismatch")
      finally:
        close(rf)
    # else: trailer cut short -- decodes in full, like zipDecompress.
  finally:
    try:
      close(f)
    except CatchableError:
      discard
    try:
      removeFile(path)
    except CatchableError:
      discard

proc zipValidate*(data: Span, expected: int) =
  ## Prove a stream inflates, without materialising the output.
  ##
  ## Parse-time validation used to call `zipDecompress` and discard the
  ## result, which allocated the entire decoded plane set just to throw it
  ## away. Small streams still validate that way (reusing `zipDecompress`
  ## keeps one code path for errors); large streams inflate into a temp
  ## file instead, so validating a large composite costs a fixed buffer
  ## instead of O(decoded). The same `expected * 2 + 16` bound as
  ## `zipDecompress` applies.
  if data.len == 0:
    if expected == 0:
      return
    decompressFailed("ZIP: empty input for " & $expected & " expected bytes")
  # A zlib header is two bytes, so the check for one reads byte 1 as well.
  # A one-byte tail is a truncated stream, not a raw deflate block, and must
  # be refused rather than indexed.
  if data.len < 2:
    decompressFailed("ZIP: " & $data.len & " byte input for " & $expected &
      " expected bytes")
  let bound = expected * 2 + 16
  if expected <= ZipValidateMemCap:
    let inflated = zipDecompress(data, expected)
    # The point of validating at parse time is to catch a truncated
    # composite where it lives, so the size actually produced has to be
    # checked. Without this, a stream cut short still validated as long
    # as it happened to inflate to the right count before the cut --
    # the last bytes of a merged image could be dropped with no error
    # at all.
    if inflated.len != expected:
      decompressFailed("ZIP: inflated to " & $inflated.len &
        " bytes, expected " & $expected)
    return
  if not looksZlib(data):
    # Large raw streams have no checksum to verify against a file; fall
    # back to the in-memory path so corrupt input still fails loudly
    # rather than silently.
    let inflated = zipDecompress(data, expected)
    if inflated.len != expected:
      decompressFailed("ZIP: inflated to " & $inflated.len &
        " bytes, expected " & $expected)
    return
  try:
    zipValidateStreamToFile(data, expected, bound)
  except FlateError as e:
    decompressFailed("ZIP: inflate failed (" & e.msg & ")")

proc zipCompress*(data: string): string =
  ## zlib-wrapped deflate (level 6, the old `Z_DEFAULT_COMPRESSION`).
  ## Used for writing and for test fixtures. Pure Nim (`archive`).
  if data.len == 0:
    return ""
  let inp = openInputString(data)
  let dst = newOutput(data.len div 2 + 16)
  zlibCompressInto(inp, dst)
  take(dst)

# --- plane codecs -----------------------------------------------------------

proc decodePlanes*(comp: Compression, data: Span, l: PlaneLayout,
    limits = defaultLimits()): string =
  ## Decode an encoded plane buffer into `width * height * bytesPerSample`
  ## bytes per plane, planar and big-endian. Does not include the 2-byte
  ## compression marker, which the caller has already consumed.
  ##
  ## The decoded size is capped before any allocation, so a ZIP bomb cannot
  ## expand past `limits.maxDecodedBytes`.
  limits.checkDecoded(l.totalBytes(), "plane")
  let need = l.decodedLen()
  if need == 0:
    return ""
  case comp.kind
  of cRaw:
    if data.len < need:
      decompressFailed("Raw: have " & $data.len & " bytes, need " & $need)
    return data.head(need).clone
  of cRle:
    var r = initReader(data)
    let countSize = l.countSize()
    let nRows = int(l.rows())
    if int64(nRows) * countSize > r.remaining:
      decompressFailed("RLE: row count table does not fit")
    var counts = newSeq[int](nRows)
    for i in 0 ..< nRows:
      counts[i] = if countSize == 4: int(r.readU32BE()) else: int(r.readU16BE())
    # PackBits expands at most 64x, so a declared total far beyond the input
    # is a corrupt count table rather than a real payload
    if int64(need) > r.remaining * 64:
      decompressFailed("RLE: data too short for the declared size")
    var buf = newString(need)
    let rb = l.rowBytes()
    # rows start after the count table, not at the beginning of the buffer.
    # `offset` is relative to the span, which is what packbits indexes.
    var p = r.offset
    for rowIdx in 0 ..< nRows:
      let plane = rowIdx div l.height
      let y = rowIdx mod l.height
      let before = p
      if rb > 0:
        p = packbitsDecodeInto(data, rb, buf, (plane * l.height + y) * rb, p)
      if p - before > counts[rowIdx]:
        decompressFailed("RLE: row " & $rowIdx & " overran its declared length")
    result = buf
  of cZip, cZipPrediction:
    result = zipDecompress(data, need)
    if comp.kind == cZipPrediction:
      unpredict(result, l)
  of cUnknown:
    unsupported("compression code " & $comp.raw)

proc encodePlanes*(comp: Compression, decoded: string, l: PlaneLayout): string =
  ## Inverse of `decodePlanes`, without the compression marker.
  let need = l.decodedLen()
  if decoded.len != need:
    invalid("plane buffer is " & $decoded.len & " bytes, layout wants " & $need)
  case comp.kind
  of cRaw:
    return decoded
  of cRle:
    let countSize = l.countSize()
    let rb = l.rowBytes()
    let nRows = int(l.rows())
    var rows = newSeq[string](nRows)
    var counts = newSeq[int](nRows)
    for i in 0 ..< nRows:
      let plane = i div l.height
      let y = i mod l.height
      rows[i] = packbitsEncode(decoded[(plane * l.height + y) * rb ..<
        (plane * l.height + y + 1) * rb])
      counts[i] = rows[i].len
      if countSize == 2 and counts[i] > 0xFFFF:
        limitExceeded("RLE row exceeds 65535 bytes (use PSB)")
    var w = initWriter()
    for c in counts:
      if countSize == 4: w.putU32(uint32(c)) else: w.putU16(uint16(c))
    for row in rows:
      w.put(row)
    return w.toString()
  of cZip:
    return zipCompress(decoded)
  of cZipPrediction:
    var tmp = decoded
    predict(tmp, l)
    return zipCompress(tmp)
  of cUnknown:
    unsupported("compression code " & $comp.raw)

proc validatePlanes*(comp: Compression, data: Span, l: PlaneLayout,
    limits = defaultLimits()) =
  ## Cheap structural check at parse time, so a corrupt payload is reported
  ## where it lives instead of at some later decode. `Unknown` passes: the
  ## bytes are preserved rather than decoded.
  ##
  ## The decoded size is capped here, before any inflation, so a small
  ## compressed payload cannot expand into an unbounded buffer.
  limits.checkDecoded(l.totalBytes(), "plane")
  let need = l.totalBytes()
  case comp.kind
  of cRaw:
    if data.len < need:
      decompressFailed("Raw: have " & $data.len & " bytes, need " & $need)
  of cRle:
    var r = initReader(data)
    let countSize = l.countSize()
    let nRows = l.rows()
    if nRows * countSize > r.remaining:
      decompressFailed("RLE: row count table does not fit")
    var sum: int64 = 0
    for _ in 0 ..< nRows:
      sum += (if countSize == 4: int64(r.readU32BE()) else: int64(r.readU16BE()))
    if sum > r.remaining:
      decompressFailed("RLE: row counts exceed the available data")
  of cZip, cZipPrediction:
    # prove the stream is sound without inflating it into a throwaway buffer
    zipValidate(data, int(min(need, MaxDecodedBytes)))
  of cUnknown:
    discard
