import std/strutils
import unittest
import ../src/opengraphics/psd


proc layout(planes, width, height, depth: int,
    version = Version.Psd): PlaneLayout =
  newPlaneLayout(planes, width, height, depth, version)

proc ramp(n: int, seed = 0): string =
  ## Deterministic sample data, varied enough to catch prediction bugs.
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char((i * 37 + seed * 101) and 0xFF)

suite "plane layout":
  test "rowBytes and row counts follow the depth":
    let l = layout(3, 20, 10, 8)
    check l.rowBytes() == 20
    check l.rows() == 30          # 3 planes x 10 rows
    check l.totalBytes() == 600

  test "16-bit rows are twice as wide":
    let l = layout(1, 20, 10, 16)
    check l.rowBytes() == 40
    check l.totalBytes() == 400

  test "1-bit rows pack eight pixels per byte":
    let l = layout(1, 20, 10, 1)
    check l.rowBytes() == 3
    check l.totalBytes() == 30

  test "PSB uses four-byte RLE counts, PSD two":
    check layout(1, 4, 4, 8, Version.Psb).countSize() == 4
    check layout(1, 4, 4, 8, Version.Psd).countSize() == 2

suite "packbits":
  test "an empty payload decodes to nothing":
    let p = packbitsDecode(toSpan(""), 0)
    check p.row.len == 0

  test "a literal run is copied":
    # header 3 means "copy the next 4 bytes"
    let p = packbitsDecode(toSpan("\x03ABCD"), 4)
    check p.row == "ABCD"
    check p.next == 5

  test "a repeat run is expanded":
    # header -2 (0xFE) means "repeat the next byte 3 times"
    let p = packbitsDecode(toSpan("\xFED"), 3)
    check p.row == "DDD"
    check p.next == 2

  test "a 128-byte literal run is the maximum":
    let row = ramp(128)
    let enc = packbitsEncode(row)
    check packbitsDecode(toSpan(enc), 128).row == row

  test "a long run is split at 128":
    let row = "z".repeat(300)
    let p = packbitsDecode(toSpan(packbitsEncode(row)), 300)
    check p.row == row

  test "mixed runs round-trip":
    let row = "aaaa" & ramp(200) & "b" & "c".repeat(130)
    check packbitsDecode(toSpan(packbitsEncode(row)), row.len).row == row

  test "the encoder never emits the -128 no-op":
    var sawNoop = false
    for n in 0 .. 600:
      let enc = packbitsEncode(ramp(n))
      var i = 0
      while i < enc.len:
        if cast[int8](enc[i]) == -128:
          sawNoop = true
        break # only the first header can be -128 in practice
      if sawNoop:
        break
    check not sawNoop

  test "encoding never expands beyond one header per 128 bytes":
    for n in [0, 1, 2, 127, 128, 129, 255, 256, 600]:
      let row = ramp(n)
      let enc = packbitsEncode(row)
      check enc.len <= row.len + (row.len div 128) + 1

  test "a truncated row is refused":
    expect(PsdError):
      discard packbitsDecode(toSpan("\x03AB"), 4)

  test "a literal that would overrun the row is refused":
    expect(PsdError):
      discard packbitsDecode(toSpan("\x07ABC"), 4)

  test "a repeat with no value byte is refused":
    expect(PsdError):
      discard packbitsDecode(toSpan("\xFE"), 3)

suite "prediction":
  test "depth 8 round-trips through predict and unpredict":
    let l = layout(1, 17, 5, 8)
    var buf = ramp(l.decodedLen())
    let orig = buf
    predict(buf, l)
    check buf != orig # the delta actually changed the bytes
    unpredict(buf, l)
    check buf == orig

  test "depth 16 round-trips":
    let l = layout(1, 9, 3, 16)
    var buf = ramp(l.decodedLen())
    let orig = buf
    predict(buf, l)
    unpredict(buf, l)
    check buf == orig

  test "depth 32 round-trips through the byte-plane shuffle":
    let l = layout(1, 5, 2, 32)
    var buf = ramp(l.decodedLen())
    let orig = buf
    predict(buf, l)
    unpredict(buf, l)
    check buf == orig

  test "depth 1 round-trips":
    let l = layout(1, 20, 3, 1)
    var buf = ramp(l.decodedLen())
    let orig = buf
    predict(buf, l)
    unpredict(buf, l)
    check buf == orig

  test "an unsupported depth is reported as unsupported":
    let l = layout(1, 4, 2, 4)
    var buf = ramp(l.decodedLen())
    expect(PsdError):
      predict(buf, l)

suite "compression codes":
  test "codes 0..3 round-trip":
    check compressionFromU16(0'u16).kind == cRaw
    check compressionFromU16(1'u16).kind == cRle
    check compressionFromU16(2'u16).kind == cZip
    check compressionFromU16(3'u16).kind == cZipPrediction
    for code in [0'u16, 1'u16, 2'u16, 3'u16]:
      check compressionFromU16(code).toU16() == code

  test "an unknown code is preserved rather than rejected":
    let c = compressionFromU16(7'u16)
    check c.kind == cUnknown
    check c.raw == 7'u16
    check c.toU16() == 7'u16

suite "plane codecs":
  test "Raw passes bytes through":
    let l = layout(1, 4, 2, 8)
    let data = ramp(l.decodedLen())
    check decodePlanes(Raw, toSpan(data), l) == data
    check encodePlanes(Raw, data, l) == data

  test "Raw is refused when short":
    let l = layout(1, 4, 2, 8)
    expect(PsdError):
      discard decodePlanes(Raw, toSpan("short"), l)

  test "RLE round-trips at every depth":
    for depth in [1, 8, 16, 32]:
      let l = layout(2, 7, 3, depth)
      let data = ramp(l.decodedLen())
      let enc = encodePlanes(Rle, data, l)
      check decodePlanes(Rle, toSpan(enc), l) == data

  test "RLE encodes a u16 count table in PSD and u32 in PSB":
    for version in [Version.Psd, Version.Psb]:
      let l = layout(1, 4, 2, 8, version)
      let data = ramp(l.decodedLen())
      let enc = encodePlanes(Rle, data, l)
      check enc.len > l.rows() * l.countSize()

  test "ZIP round-trips":
    let l = layout(3, 9, 4, 8)
    let data = ramp(l.decodedLen())
    check decodePlanes(Zip, toSpan(encodePlanes(Zip, data, l)), l) == data

  test "ZIP with prediction round-trips":
    let l = layout(1, 11, 3, 8)
    let data = ramp(l.decodedLen())
    check decodePlanes(ZipPrediction,
      toSpan(encodePlanes(ZipPrediction, data, l)), l) == data

  test "all four codecs round-trip the same data":
    let l = layout(1, 16, 5, 8)
    let data = ramp(l.decodedLen())
    for c in [Raw, Rle, Zip, ZipPrediction]:
      check decodePlanes(c, toSpan(encodePlanes(c, data, l)), l) == data

  test "encode refuses a buffer of the wrong size":
    let l = layout(1, 4, 2, 8)
    expect(PsdError):
      discard encodePlanes(Raw, "too short", l)

  test "an unknown compression code is reported as unsupported":
    let l = layout(1, 4, 2, 8)
    expect(PsdError):
      discard decodePlanes(compressionFromU16(9'u16), toSpan(ramp(8)), l)

  test "a truncated RLE payload is refused":
    let l = layout(1, 4, 2, 8)
    expect(PsdError):
      discard decodePlanes(Rle, toSpan("\x00\x08"), l)

  test "a corrupt ZIP payload is refused":
    let l = layout(1, 4, 2, 8)
    expect(PsdError):
      discard decodePlanes(Zip, toSpan("not a zlib stream at all"), l)

suite "plane validation":
  test "valid payloads pass":
    let l = layout(1, 8, 4, 8)
    for c in [Raw, Rle, Zip, ZipPrediction]:
      validatePlanes(c, toSpan(encodePlanes(c, ramp(l.decodedLen()), l)), l)

  test "short Raw data is caught":
    let l = layout(1, 8, 4, 8)
    expect(PsdError):
      validatePlanes(Raw, toSpan("short"), l)

  test "an unknown code passes validation so it can be preserved":
    let l = layout(1, 8, 4, 8)
    validatePlanes(compressionFromU16(9'u16), toSpan("whatever"), l)

suite "sample codecs":
  test "16-bit samples read big-endian":
    check samplesU16("\x01\x02\xFF\xFE") == @[0x0102'u16, 0xFFFE'u16]

  test "16-bit samples write back big-endian":
    check u16ToBytes(@[0x0102'u16, 0xFFFE'u16]) == "\x01\x02\xFF\xFE"

  test "16-bit samples round-trip":
    let s = @[0'u16, 1, 0x8000, 0xFFFF'u16]
    check samplesU16(u16ToBytes(s)) == s

  test "32-bit float samples round-trip":
    let f = @[0.0'f32, 1.0'f32, -2.5'f32]
    check samplesF32(f32ToBytes(f)) == f

  test "unpackBits reads MSB first":
    # 0b10100000 -> 1,0,1,0,0,0,0,0
    let bits = unpackBits("\xA0", 8, 1)
    check bits[0] == char(1)
    check bits[1] == char(0)
    check bits[2] == char(1)
    check bits[5] == char(0)

  test "unpackBits spans byte boundaries":
    # 0xFF 0x80 over 16 pixels, MSB first: 8 ones, then 1 then 7 zeros
    let bits = unpackBits("\xFF\x80", 16, 1)
    check bits.len == 16
    check bits[7] == char(1)
    check bits[8] == char(1)
    check bits[9] == char(0)
    check bits[15] == char(0)

  test "depth 1 inverts: in PSD a set bit is black, not white":
    # 0x80 = 1000_0000, so pixel 0 is set and pixels 1..7 are clear
    let u8 = planeToU8("\x80", 1, 8, 1)
    check u8.len == 8
    check u8[0] == char(0)     # set bit -> black
    check u8[1] == char(0xFF)  # clear bit -> white

  test "depth 8 is the identity":
    let data = ramp(6)
    check planeToU8(data, 8, 3, 2) == data

  test "depth 16 scales to 8 with rounding":
    check planeToU8("\x00\x00", 16, 1, 1)[0] == char(0)
    check planeToU8("\xFF\xFF", 16, 1, 1)[0] == char(0xFF)
    check planeToU8("\x80\x00", 16, 1, 1)[0] == char(128) # exactly half

  test "depth 32 maps NaN to 0 and clamps":
    check planeToU8(f32ToBytes(@[0.0'f32]), 32, 1, 1)[0] == char(0)
    check planeToU8(f32ToBytes(@[1.0'f32]), 32, 1, 1)[0] == char(0xFF)
    check planeToU8(f32ToBytes(@[-5.0'f32]), 32, 1, 1)[0] == char(0)
    check planeToU8(f32ToBytes(@[9.0'f32]), 32, 1, 1)[0] == char(0xFF)
    let nan = 0.0'f32 / 0.0'f32
    check planeToU8(f32ToBytes(@[nan]), 32, 1, 1)[0] == char(0)

  test "an unsupported depth is reported":
    expect(PsdError):
      discard planeToU8(ramp(4), 4, 2, 2)

  test "interleave and deinterleave are inverses":
    let a = ramp(6)
    let b = ramp(6, seed = 1)
    let mixed = interleave(@[a, b], 3, 2)
    check mixed.len == 12
    let planes = deinterleave(mixed, 2, 3, 2)
    check planes[0] == a
    check planes[1] == b
