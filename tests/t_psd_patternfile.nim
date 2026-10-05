## Pattern data inside a real file.
##
## The round-trip tests in `t_psd_core_patterns` cover `patterns.nim` against
## itself at every depth, but writer and reader share one model of the format, so
## they would agree even if both were wrong. The cross-check in `t_psd_xref` adds
## a second, independent implementation. What neither can do is show that the
## pattern block survives being written into a *file* and read back out through
## the ordinary path -- the tagged-block length, the 4-byte padding, the choice
## of `Patt` / `Pat2` / `Pat3`, and the global-block placement are all part of
## `file.nim` and `tagged.nim`, not of `patterns.nim`.
##
## That is what this suite covers, using the generated fixture, because every
## committed fixture writes a zero-length `Patt`. Photoshop does that correctly
## for a document with no patterns, so it is not a bug -- but it means a
## populated block had no coverage anywhere until now.

import std/options
import std/unittest
import ../src/opengraphics/psd
import ./psd_testgen

proc generated(): PsdFile =
  ## The large fixture, built in memory rather than read back, so this suite
  ## tests the writer. The zero-copy suite covers reading it back.
  largeLayered(600, 600, 6)

suite "patterns in a file: the block is written, not stubbed":
  test "the fixture carries a populated Patt block":
    let f = generated()
    var found = false
    for b in f.globalBlocks:
      if b.key == "Patt":
        found = true
        check b.data.len > 0
        check parsePatternBlock(b.data).len == 3
    check found

  test "globalPatterns resolves the fixture's tiles":
    let f = generated()
    # `globalPatterns` looks the block up by depth, so this also pins that the
    # generator chose the right key.
    let pats = f.globalPatterns()
    check pats.isSome
    check pats.get().len == 3

  test "the tiles carry their names, sizes and planes":
    let pats = generated().globalPatterns().get()
    check pats[0].name == "Checker"
    check pats[0].width == 8 and pats[0].height == 8
    check pats[0].alpha.isNone
    check pats[1].name == "Diagonal"
    check pats[1].alpha.isSome
    check pats[2].name == "Solid Ramp"
    check pats[2].width == 4 and pats[2].height == 16
    for p in pats:
      check p.mode == 3
      check p.depth == 8
      check p.channels.len == 3
      for plane in p.channels:
        check plane.len == int(p.width) * int(p.height)

  test "the block key follows the document depth":
    # A 16-bit document must write `Pat2`, and the reader must look for `Pat2`.
    # Getting this wrong does not fail a round trip -- it fails to *find* the
    # patterns -- so it is asserted directly.
    for depth in [16, 32]:
      let f = largeLayered(600, 600, 4, depth = depth)
      var sawKey = false
      for b in f.globalBlocks:
        if b.key == patternBlockKey(uint16(depth)): sawKey = true
      check sawKey
      let pats = f.globalPatterns()
      check pats.isSome
      check pats.get().len == 3
      for p in pats.get():
        check p.depth == uint16(depth)
        # 16- and 32-bit tiles carry two and four bytes per sample.
        let bpp = int(depth) div 8
        check p.channels[0].len == int(p.width) * int(p.height) * bpp

suite "patterns in a file: byte-exact through the whole writer":
  test "a file with patterns round-trips byte for byte":
    # The load-bearing property. A pattern block is length-prefixed per pattern
    # and padded to 4 bytes; if the writer and the block-length accounting ever
    # disagree, everything after the global blocks shifts and the file stops
    # matching, which is exactly what this catches.
    let f = generated()
    let bytes = writePsd(f)
    let reparsed = readPsd(bytes)
    check writePsd(reparsed) == bytes

  test "the patterns survive the round trip intact":
    let f = generated()
    let reparsed = readPsd(writePsd(f))
    let before = f.globalPatterns().get()
    let after = reparsed.globalPatterns().get()
    check before.len == after.len
    for i in 0 ..< before.len:
      check before[i].name == after[i].name
      check before[i].width == after[i].width
      check before[i].height == after[i].height
      check before[i].channels == after[i].channels
      check before[i].alpha == after[i].alpha

  test "the file stays byte-exact at 16 and 32 bits":
    for depth in [16, 32]:
      let f = largeLayered(600, 600, 4, depth = depth)
      let bytes = writePsd(f)
      check writePsd(readPsd(bytes)) == bytes