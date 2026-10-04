import std/strutils
import unittest
import ../src/opengraphics/psd


proc makeHeader(sig = "8BPS", version = 1'u16, channels = 3'u16,
    height = 10'u32, width = 20'u32, depth = 8'u16,
    mode = 3'u16): string =
  var w = initWriter()
  w.putStr4(sig)
  w.putU16(version)
  for _ in 0 ..< 6:
    w.putU8(0)
  w.putU16(channels)
  w.putU32(height)
  w.putU32(width)
  w.putU16(depth)
  w.putU16(mode)
  w.toString()

proc parse(s: string): Header =
  ## Convenience wrapper: readHeader needs a var Reader, tests do not.
  var r = initReader(s)
  readHeader(r)

suite "header: wire layout":
  test "a 26-byte header parses in spec order":
    var r = initReader(makeHeader())
    let h = readHeader(r)
    check h.width == 20
    check h.height == 10   # height precedes width on the wire
    check h.channels == 3
    check h.depth == 8
    check h.colorMode.kind == cmRgb
    check h.version == Version.Psd
    check r.atEnd()

  test "round-trips through writeHeader byte for byte":
    let bytes = makeHeader(channels = 1'u16, height = 7'u32, width = 9'u32,
      depth = 16'u16, mode = 1'u16)
    var r = initReader(bytes)
    let h = readHeader(r)
    var w = initWriter()
    w.writeHeader(h)
    check w.toString() == bytes


  test "PSB parses as version 2":
    let psb = parse(makeHeader(version = 2'u16))
    check psb.version == Version.Psb
    check psb.version.isPsb()
    check not parse(makeHeader()).version.isPsb()

  test "reserved bytes are preserved verbatim":
    var w = initWriter()
    w.putStr4("8BPS")
    w.putU16(1)
    for b in [1'u8, 2, 3, 4, 5, 6]:
      w.putU8(b)
    w.putU16(3)
    w.putU32(1)
    w.putU32(1)
    w.putU16(8)
    w.putU16(3)
    var h = parse(w.toString())
    check h.reserved == [1'u8, 2, 3, 4, 5, 6]
    var buf = initWriter()
    buf.writeHeader(h)
    check buf.toString() == w.toString()

suite "header: validation":
  test "a bad signature is rejected":
    try:
      discard parse(makeHeader(sig = "8BPT"))
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.InvalidSignature
      check "8BPS" in e.msg

  test "versions outside 1 and 2 are rejected":
    for v in [0'u16, 3'u16, 0xFFFF'u16]:
      expect(PsdError):
        discard parse(makeHeader(version = v))

  test "channel counts outside 1..56 are rejected":
    for c in [0'u16, 57'u16]:
      expect(PsdError):
        discard parse(makeHeader(channels = c))

  test "an unsupported bit depth is rejected":
    for d in [0'u16, 7'u16, 9'u16, 24'u16]:
      expect(PsdError):
        discard parse(makeHeader(depth = d))

  test "oversize dimensions are rejected":
    expect(PsdError):
      discard parse(makeHeader(width = 300_001'u32))
    expect(PsdError):
      discard parse(makeHeader(height = 300_001'u32))

  test "a truncated header raises rather than reading past the end":
    expect(PsdError):
      discard parse("\x38\x42\x50\x53\x00\x01")

suite "header: color modes":
  test "every documented mode round-trips through its code":
    let pairs = [
      (cmBitmap, 0'u16), (cmGrayscale, 1'u16), (cmIndexed, 2'u16),
      (cmRgb, 3'u16), (cmCmyk, 4'u16), (cmMultichannel, 7'u16),
      (cmDuotone, 8'u16), (cmLab, 9'u16),
    ]
    for (kind, code) in pairs:
      let m = colorModeFromU16(code)
      check m.kind == kind
      check m.toU16() == code

  test "an unmodelled mode keeps its raw code":
    let m = colorModeFromU16(42'u16)
    check m.kind == cmUnknown
    check m.raw == 42'u16
    check m.toU16() == 42'u16

  test "colorChannelCount matches the spec":
    check colorModeFromU16(1'u16).colorChannelCount() == 1  # grayscale
    check colorModeFromU16(3'u16).colorChannelCount() == 3  # rgb
    check colorModeFromU16(4'u16).colorChannelCount() == 4  # cmyk
    check colorModeFromU16(9'u16).colorChannelCount() == 3  # lab
    check colorModeFromU16(7'u16).colorChannelCount() == 0  # multichannel
    check colorModeFromU16(42'u16).colorChannelCount() == 0 # unknown

  test "the mode predicates pick the right cases":
    check colorModeFromU16(3'u16).isRgb()
    check colorModeFromU16(1'u16).isGray()
    check colorModeFromU16(0'u16).isGray()  # bitmap
    check colorModeFromU16(8'u16).isGray()  # duotone
    check colorModeFromU16(2'u16).isIndexed()

suite "header: row bytes":
  test "depth 1 packs eight pixels per byte":
    check rowBytes(8, 1) == 1
    check rowBytes(9, 1) == 2
    check rowBytes(0, 1) == 0

  test "byte depths scale with the sample size":
    check rowBytes(20, 8) == 20
    check rowBytes(20, 16) == 40
    check rowBytes(20, 32) == 80

  test "the header overload defaults to the document width":
    let h = parse(makeHeader(width = 20'u32, depth = 16'u16))
    check h.rowBytes() == 40
    check h.rowBytes(5) == 10

suite "header: model validation":
  test "PSD is capped at 30000 by validate, unlike readHeader":
    var h = parse(makeHeader(width = 40_000'u32))
    check h.width == 40_000 # parse allows it
    expect(PsdError):
      h.validate()
    h.version = Version.Psb
    h.validate() # PSB may go wider

  test "Indexed needs a 768-byte palette":
    var h = parse(makeHeader(mode = 2'u16))
    expect(PsdError):
      h.validate(0)
    expect(PsdError):
      h.validate(767)
    h.validate(768)
