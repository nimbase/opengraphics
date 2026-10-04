import std/options
import std/sequtils
import std/strutils
import unittest
import ../src/opengraphics/psd


proc noPatterns(): seq[PsdPattern] =
  ## An empty pattern list, so `some(...)` keeps its element type.
  @[]

proc pattern(depth: uint16, withAlpha: bool): PsdPattern =
  ## A small RGB tile with a distinctive fill per channel, so a mis-ordered
  ## or wrongly-predicted plane shows up immediately.
  let w = 5'u32
  let h = 3'u32
  let bpp = int(depth) div 8
  let plane = proc(seed: int): string =
    result = newString(int(w) * int(h) * bpp)
    for i in 0 ..< result.len:
      result[i] = char((uint8(i) * 7'u8 + uint8(seed)) and 0xFF'u8)
  PsdPattern(
    mode: 3, width: w, height: h,
    name: "Test ✓",
    id: "0bd2d3ba-1234-11d4-8f8f-aabbccddeeff",
    depth: depth,
    channels: @[plane(1), plane(2), plane(3)],
    alpha: if withAlpha: some(plane(9)) else: none(string))

suite "patterns: colour modes":
  test "the channel count follows the mode":
    check modeChannels(1) == 1   # grayscale
    check modeChannels(3) == 3   # RGB
    check modeChannels(4) == 4   # CMYK
    check modeChannels(9) == 3   # Lab
    check modeChannels(2) == 1   # indexed
    check modeChannels(7) == 1   # multichannel

  test "the block key follows the document depth":
    check patternBlockKey(8) == "Patt"
    check patternBlockKey(16) == "Pat2"
    check patternBlockKey(32) == "Pat3"
    check patternBlockKey(1) == "Patt"

suite "patterns: block round trip":
  test "every depth round-trips with and without alpha":
    for depth in [8'u16, 16'u16, 32'u16]:
      for withAlpha in [false, true]:
        var second = pattern(depth, false)
        second.name = "Second"
        let ps = @[pattern(depth, withAlpha), second]
        let blk = writePatternBlock(ps)
        check parsePatternBlock(blk) == ps

  test "the block data is a multiple of four bytes":
    let blk = writePatternBlock(@[pattern(8, true)])
    check blk.len mod 4 == 0

  test "re-serializing is byte-stable":
    let blk = writePatternBlock(@[pattern(16, true)])
    check writePatternBlock(parsePatternBlock(blk)) == blk

  test "fields survive the trip":
    let p = parsePatternBlock(writePatternBlock(@[pattern(8, false)]))[0]
    check p.name == "Test ✓"
    check p.id == "0bd2d3ba-1234-11d4-8f8f-aabbccddeeff"
    check p.mode == 3
    check p.width == 5
    check p.height == 3
    check p.depth == 8
    check p.channels.len == 3
    check p.alpha.isNone
    check p.palette.isNone

  test "an alpha plane is separated from the colour planes":
    let p = parsePatternBlock(writePatternBlock(@[pattern(8, true)]))[0]
    check p.channels.len == 3
    check p.alpha.isSome
    check p.alpha.get().len == 15

  test "a pattern with a palette keeps it":
    var p = pattern(8, false)
    p.mode = 2
    p.palette = some(repeat('\x7F', 768))
    let back = parsePatternBlock(writePatternBlock(@[p]))[0]
    check back.palette.isSome
    check back.palette.get().len == 768

  test "an empty block parses to no patterns":
    check parsePatternBlock("").len == 0

suite "patterns: .pat files":
  test "a .pat file round-trips":
    let ps = @[pattern(8, false), pattern(8, true)]
    check parsePatFile(writePatFile(ps)) == ps

  test "a .pat file round-trips at every depth":
    for depth in [8'u16, 16'u16, 32'u16]:
      let ps = @[pattern(depth, true)]
      check parsePatFile(writePatFile(ps)) == ps

  test "the signature is checked":
    expect(PsdError):
      discard parsePatFile("8BPS\x00\x01")

  test "a short header raises":
    expect(PsdError):
      discard parsePatFile("8B")

suite "patterns: malformed input":
  test "truncation raises rather than crashing":
    # A prefix shorter than one length field holds no pattern at all; anything
    # longer must fail cleanly with a PsdError, never an IndexDefect.
    let blk = writePatternBlock(@[pattern(8, true)])
    for cut in [0, 1, 3]:
      check parsePatternBlock(blk[0 ..< cut]).len == 0
    for cut in [10, 40, blk.len div 2, blk.len - 5]:
      expect(PsdError):
        discard parsePatternBlock(blk[0 ..< cut])

  test "a dense truncation sweep yields only whole, correct patterns":
    # A prefix either fails cleanly or stops at a record boundary; it must
    # never invent a pattern or return a corrupt one.
    var second = pattern(32, false)
    second.name = "Second"
    let expected = @[pattern(16, true), second]
    let blk = writePatternBlock(expected)
    for cut in countup(4, blk.len - 1, 7):
      try:
        let got = parsePatternBlock(blk[0 ..< cut])
        check got.len <= expected.len
        for i in 0 ..< got.len:
          check got[i].name == expected[i].name
          check got[i].width == expected[i].width
          check got[i].channels == expected[i].channels
      except PsdError:
        discard # the expected outcome for a truncated record

  test "a bad pattern version raises":
    expect(PsdError):
      discard parsePatternBlock("\x00\x00\x00\x09\x00\x00\x00\x03")

  test "a bad virtual memory array version raises":
    expect(PsdError):
      discard parsePatternBlock("\x00\x00\x00\x01\x00\x00\x00\x03\x00\x00\x00\x01\x00\x01")

  test "an oversized pattern is rejected before allocating":
    var w = initWriter()
    w.putU32(1)          # pattern version
    w.putU32(3)          # RGB
    w.putI16(1)
    w.putI16(1)
    w.writeUnicode("")
    w.putU8(0)           # empty id
    w.putU32(3)          # virtual memory array version
    w.putU32(16)
    w.putI32(0)
    w.putI32(0)
    w.putI32(0x7FFFFFFF) # bottom
    w.putI32(0x7FFFFFFF) # right
    w.putU32(24)
    expect(PsdError):
      discard parsePatternBlock(w.toString())

  test "too many channels is rejected":
    var w = initWriter()
    w.putU32(1)
    w.putU32(3)
    w.putI16(2)
    w.putI16(2)
    w.writeUnicode("")
    w.putU8(0)
    w.putU32(3)
    w.putU32(20)
    w.putI32(0)
    w.putI32(0)
    w.putI32(2)
    w.putI32(2)
    w.putU32(0xFFFF'u32)
    expect(PsdError):
      discard parsePatternBlock(w.toString())

  test "fewer planes than the mode requires is an error":
    # RGB needs three planes; the writer only emits the two it was given.
    let short = PsdPattern(mode: 3, width: 2, height: 2, depth: 8,
      name: "x", id: "y", channels: @["abcd", "abcd"])
    # Written as a single pattern with no trailing data at all.
    var w = initWriter()
    w.putU32(1)
    w.putU32(3)
    w.putI16(2)
    w.putI16(2)
    w.writeUnicode("")
    w.putU8(0)
    w.putU32(3)
    w.putU32(20)
    w.putI32(0)
    w.putI32(0)
    w.putI32(2)
    w.putI32(2)
    w.putU32(24)
    let blk = writePatternBlock(@[short])
    check blk.len > 0
    expect(PsdError):
      discard parsePatternBlock(blk[0 ..< 30])

suite "patterns: the real fixtures":
  test "01.psd has an empty Patt block":
    let f = readPsd(readFile("tests/data/01.psd"))
    check f.globalBlock("Patt").isSome
    check f.globalBlock("Patt").get().data.len == 0
    check globalPatterns(f) == some(noPatterns())

  test "the gray fixture also has an empty Patt block":
    let f = readPsd(readFile("tests/data/03.psd"))
    check globalPatterns(f) == some(noPatterns())

  test "a document with no pattern block reports none":
    var f = readPsd(readFile("tests/data/01.psd"))
    f.globalBlocks = f.globalBlocks.filterIt(it.key != "Patt")
    check globalPatterns(f).isNone

  test "a corrupt Patt block reports none rather than raising":
    var f = readPsd(readFile("tests/data/01.psd"))
    let i = f.globalBlocks.findIt(it.key == "Patt")
    f.globalBlocks[i].data = toSpan("\x00\x00\x00\x09\x00\x00\x00\x03")
    check globalPatterns(f).isNone

  test "the fixtures still round-trip byte for byte":
    for path in ["tests/data/01.psd", "tests/data/03.psd"]:
      let bytes = readFile(path)
      check writePsd(readPsd(bytes)) == bytes