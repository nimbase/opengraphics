import std/strutils
import std/unicode
import unittest
import ../src/opengraphics/psd/error
import ../src/opengraphics/psd/io

suite "reader: big-endian primitives":
  test "reads scalars of every width":
    var r = initReader("\x01\x02\x03\x04\x05\x06\x07\x08\xFF")
    check r.readU8() == 0x01'u8
    check r.readU16BE() == 0x0203'u16
    check r.readU16BE() == 0x0405'u16
    check r.readU16BE() == 0x0607'u16
    check r.readU16BE() == 0x08FF'u16
    check r.atEnd()

  test "signed reads reinterpret the same bits":
    var r = initReader("\xFF\xFF\x80\x00")
    check r.readI16BE() == -1'i16
    check r.readI16BE() == -32768'i16

  test "readU64BE assembles all eight bytes":
    var r = initReader("\x01\x02\x03\x04\x05\x06\x07\x08")
    check r.readU64BE() == 0x0102030405060708'u64

  test "readF64BE round-trips through putF64":
    var w = initWriter()
    w.putF64(1.5)
    var r = initReader(w.toString())
    check r.readF64BE() == 1.5

  test "readF32BE round-trips through putF32":
    var w = initWriter()
    w.putF32(0.5'f32)
    var r = initReader(w.toString())
    check r.readF32BE() == 0.5'f32

  test "readStr4 reads a four-byte tag":
    var r = initReader("8BIMnorm")
    check r.readStr4() == "8BIM"
    check r.readStr4() == "norm"

suite "reader: bounds":
  test "short read raises UnexpectedEof naming what was needed":
    var r = initReader("\x01\x02")
    discard r.readU8()
    try:
      discard r.readU32BE()
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.UnexpectedEof
      check "3 more bytes" in e.msg

  test "require accepts an exact fit and rejects one more":
    var r = initReader("abcd")
    r.require(4)
    expect(PsdError):
      r.require(5)

  test "skip past the end raises":
    var r = initReader("ab")
    expect(PsdError):
      r.skip(3)

suite "reader: sub-readers":
  test "sub scopes the view and consumes from the parent":
    var r = initReader("AABBCC")
    var s = r.sub(4)
    check s.len() == 4
    check s.readStr4() == "AABB"
    check s.isEmpty()
    # parent resumes right after the sub-view, with only "CC" left
    check r.remaining() == 2
    check r.bytes(2).clone == "CC"

  test "sub raises when the request overruns the parent":
    var r = initReader("ab")
    expect(PsdError):
      discard r.sub(3)

  test "reading past a sub boundary raises even when the root has more":
    var r = initReader("AABBCC")
    var s = r.sub(2)
    expect(PsdError):
      discard s.readStr4()
    # the root still holds all six bytes; only the view is short
    check r.root.size == 6

  test "nested subs each scope their own window":
    var r = initReader("\x00\x01\x02\x03\x04\x05\x06\x07")
    var outer = r.sub(8)
    check (outer.start, outer.stop) == (0, 8)
    var mid = outer.sub(6)
    check (mid.start, mid.stop) == (0, 6)
    var inner = mid.sub(4)
    check (inner.start, inner.stop) == (0, 4)
    check inner.readU32BE() == 0x00010203'u32
    # each parent keeps the tail it did not hand to its child
    check mid.remaining() == 2
    check outer.remaining() == 2

suite "reader: length fields":
  test "lenField reads 32 bits in PSD and 64 in PSB":
    var r = initReader("\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02")
    check r.lenField(false) == 1
    check r.lenField(true) == 2

suite "reader: pascal strings":
  test "align 2 pads a name whose length is even":
    # 1 length byte + 2 chars = 3 consumed, padded up to 4
    var r = initReader("\x02AB\x00tail")
    check r.readPascal(2) == "AB"
    check r.bytes(4).clone == "tail"

  test "align 2 leaves an odd name unpadded":
    # 1 + 1 = 2, already a multiple of 2
    var r = initReader("\x01A\x00\x00")
    check r.readPascal(2) == "A"
    check r.bytes(2).clone == "\x00\x00"

  test "align 4 pads to a multiple of four":
    # 1 + 1 = 2 consumed, padded up to 4
    var r = initReader("\x01A\x00\x00")
    check r.readPascal(4) == "A"
    check r.atEnd()

  test "zero length reads as an empty name":
    var r = initReader("\x00\x00\x00\x00")
    check r.readPascal(4) == ""
    check r.atEnd()

  test "truncated padding raises rather than being silently accepted":
    # claims a 3-byte pad-4 name but supplies no pad byte at all
    var r = initReader("\x02AB")
    expect(PsdError):
      discard r.readPascal(4)

  test "round-trips through writePascal":
    for name in ["", "A", "AB", "ABC", "ABCD", "layer name"]:
      for align in [2, 4]:
        var w = initWriter()
        w.writePascal(name, align)
        var r = initReader(w.toString())
        check r.readPascal(align) == name
        check r.atEnd()

  test "a 255-byte name still fits the length byte":
    let long = "x".repeat(255)
    var w = initWriter()
    w.writePascal(long, 4)
    var r = initReader(w.toString())
    check r.readPascal(4) == long
    check r.atEnd()

  test "an over-long name is clipped to 255 bytes":
    var w = initWriter()
    w.writePascal("y".repeat(300), 4)
    var r = initReader(w.toString())
    check r.readPascal(4).len == 255

suite "reader: unicode strings":
  test "reads code units and drops trailing NULs":
    var r = initReader("\x00\x00\x00\x02\x00A\x00B\x00\x00")
    check unicodeToString(r.readUnicodeUnits()) == "AB"

  test "round-trips BMP and astral characters through UTF-16BE":
    # explicit UTF-8 bytes: Nim's \U escape does not emit UTF-8
    let s = "a\xC3\xA9\xE4\xB8\xAD\xF0\x9F\x98\x80z"
    var w = initWriter()
    w.writeUnicode(s)
    var r = initReader(w.toString())
    check unicodeToString(r.readUnicodeUnits()) == s

  test "an astral character becomes a surrogate pair":
    let units = toUtf16Units("\xF0\x9F\x98\x80") # U+1F600
    check units.len == 2
    check units[0] == 0xD83D'u16
    check units[1] == 0xDE00'u16

  test "a BMP character stays a single unit":
    check toUtf16Units("\xE4\xB8\xAD") == @[0x4E2D'u16]

  test "an unpaired high surrogate becomes U+FFFD":
    var r = initReader("\x00\x00\x00\x01\xD8\x00")
    check unicodeToString(r.readUnicodeUnits()) == "\uFFFD"

  test "an unpaired low surrogate becomes U+FFFD":
    var r = initReader("\x00\x00\x00\x01\xDC\x00")
    check unicodeToString(r.readUnicodeUnits()) == "\uFFFD"

  test "a bogus unit count raises rather than over-allocating":
    var r = initReader("\xFF\xFF\xFF\xFF")
    expect(PsdError):
      discard r.readUnicodeUnits()

suite "reader: legacy names":
  test "isValidUtf8 agrees with the raw validator":
    # validateUtf8 returns -1 for valid and 0 for invalid, which reads
    # backwards; the wrapper must state it plainly
    check isValidUtf8("na\xC3\xAFve")
    check isValidUtf8("")
    check not isValidUtf8("\xE9")

  test "valid UTF-8 passes through unchanged":
    check decodeLegacyName("na\xC3\xAFve") == "na\xC3\xAFve"

  test "invalid UTF-8 is read as Latin-1, widening the byte":
    # 0xE9 alone is a Latin-1 "e-acute", invalid as UTF-8
    check decodeLegacyName("\xE9") == "\xE9"
    # a valid two-byte sequence must NOT be widened into two Latin-1 chars
    check decodeLegacyName("\xC3\xAF").len == 2

  test "encodeLegacyName replaces non-printables and clips":
    check encodeLegacyName("ok name") == "ok name"
    check encodeLegacyName("a\u0001b") == "a?b"
    check encodeLegacyName("x".repeat(400)).len == 255

suite "writer: length back-patching":
  test "beginLen and endLen fill in the payload size":
    var w = initWriter()
    let at = w.beginLen(false)
    w.put("abcd")
    w.endLen(at, false)
    check w.toString() == "\x00\x00\x00\x04abcd"

  test "the 64-bit form back-patches eight bytes":
    var w = initWriter()
    let at = w.beginLen(true)
    w.put("ab")
    w.endLen(at, true)
    check w.toString() == "\x00\x00\x00\x00\x00\x00\x00\x02ab"

  test "an empty payload writes a zero length":
    var w = initWriter()
    let at = w.beginLen(false)
    w.endLen(at, false)
    check w.toString() == "\x00\x00\x00\x00"

  test "a 32-bit length overflow reports the need for PSB":
    var w = initWriter()
    expect(PsdError):
      w.putLen(int64(high(uint32)) + 1, false)

suite "writer: primitives":
  test "putStr4 rejects a tag that is not four bytes":
    var w = initWriter()
    expect(PsdError):
      w.putStr4("toolong")

  test "integers round-trip through the writer":
    var w = initWriter()
    w.putU8(0x12'u8)
    w.putI16(-2'i16)
    w.putI32(-70000'i32)
    w.putI64(-5'i64)
    var r = initReader(w.toString())
    check r.readU8() == 0x12'u8
    check r.readI16BE() == -2'i16
    check r.readI32BE() == -70000'i32
    check r.readI64BE() == -5'i64

suite "limits":
  test "checkDimensions accepts at the cap and rejects past it":
    let lim = defaultLimits()
    lim.checkDimensions(1, 1, "doc")
    expect(PsdError):
      lim.checkDimensions(0, 10, "doc")
    expect(PsdError):
      lim.checkDimensions(lim.maxWidth + 1, 10, "doc")

  test "checkDimensions reports the pixel cap":
    let lim = Limits(maxWidth: 30000, maxHeight: 30000, maxPixels: 1000,
      maxLayers: 10, maxSectionBytes: 1000, maxBlocks: 10,
      maxDecodedBytes: 1000)
    expect(PsdError):
      lim.checkDimensions(100, 100, "doc") # 10_000 > 1000

  test "checkSection rejects a negative and an oversized length":
    let lim = defaultLimits()
    lim.checkSection(10, "sec")
    expect(PsdError):
      lim.checkSection(-1, "sec")
    expect(PsdError):
      lim.checkSection(int64(lim.maxSectionBytes) + 1, "sec")

  test "checkCount rejects a count that cannot fit in the input":
    let lim = defaultLimits()
    lim.checkCount(10, 1000, 8, "layers")
    expect(PsdError):
      lim.checkCount(10_000, 16, 8, "layers") # 80_000 > 16 remaining
    expect(PsdError):
      lim.checkCount(-1, 1000, 8, "layers")

  test "the error kind distinguishes the failure classes":
    try:
      defaultLimits().checkDimensions(0, 0, "doc")
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.Invalid
    try:
      limitExceeded("too big")
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.LimitExceeded
