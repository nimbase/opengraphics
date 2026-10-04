## PackBits edge cases and the channel codecs' round-trip properties.
##
## The reference has these as proptests. Nim has no proptest, so the same
## properties are checked deterministically: hand-built edge cases for the
## shapes that break encoders, then exhaustive small inputs, then a seeded
## sweep for the larger ones.
##
## PackBits is the format most likely to be wrong in a way fixtures never
## reveal, because a real file's rows are mostly gradients -- long literal runs
## and long repeats. The interesting inputs are the awkward ones: a run of
## exactly 128, a literal of exactly 128, and rows that expand or shrink by the
## worst possible amount.

import std/options
import std/strutils
import std/unittest
import ../src/opengraphics/psd
import ./psd_testgen

proc packbits(src: Span, expected: int): string =
  ## One row decoded on its own. `packbitsDecode` returns a `PackedRow` (the
  ## data plus the offset just past it); only the data is wanted here.
  packbitsDecode(src, expected).row

suite "packbits round-trip":
  # A proc, not a template: templates do no implicit conversion, so a `char`
  # argument would not reach a `string` parameter.
  proc roundTrip(data: sink string) =
    let enc = packbitsEncode(data)
    check packbits(spanOf(enc), data.len) == data

  test "empty input round-trips":
    roundTrip("")

  test "a single byte round-trips":
    for b in 0 .. 255:
      roundTrip($(char(uint8(b))))

  test "a uniform run round-trips at every length":
    # Every length is a boundary case somewhere: 2 and 3 share an encoding
    # form, 128 and 129 straddle the run-length limit.
    for n in 0 .. 300:
      var s = newString(n)
      for i in 0 ..< n: s[i] = 'A'
      roundTrip(s)

  test "a literal run round-trips at every length":
    # The mirror case: no repeats, so every byte needs a literal header. 128 is
    # the largest run one header can express.
    for n in 0 .. 300:
      var s = newString(n)
      for i in 0 ..< n: s[i] = char(uint8(i and 0xFF))
      roundTrip(s)

  test "alternating bytes round-trip":
    # Worst case for expansion: nothing repeats, so every byte is literal.
    for n in [0, 1, 2, 3, 127, 128, 129, 255, 256, 257]:
      var s = newString(n)
      for i in 0 ..< n: s[i] = char(uint8(if i mod 2 == 0: 0 else: 1))
      roundTrip(s)

  test "runs of every length in every position round-trip":
    # One repeat of length k surrounded by literals, for every k. This is the
    # shape that catches an encoder emitting a repeat where it must emit a
    # literal, or a decoder losing its place at a boundary.
    for k in 0 .. 260:
      for pad in [0, 1, 2, 127, 128]:
        var s = newString(0)
        for i in 0 ..< pad: s.add(char(uint8(i and 0xFF)))
        for _ in 0 ..< k: s.add('Z')
        for i in 0 ..< pad: s.add(char(uint8((i + 64) and 0xFF)))
        roundTrip(s)

  test "a run of exactly 128 and one of 129 round-trip":
    # 128 is the maximum a single repeat header can express, so an encoder that
    # gets the off-by-one wrong shows up only here.
    for k in [127, 128, 129, 130, 255, 256, 257]:
      var s = newString(k)
      for i in 0 ..< k: s[i] = 'Q'
      roundTrip(s)

  test "exhaustive two- and three-byte inputs round-trip":
    # Small enough to be exhaustive rather than sampled.
    for a in 0 .. 255:
      for b in 0 .. 255:
        roundTrip(char(uint8(a)) & char(uint8(b)))
    for a in 0 .. 255:
      let base = char(uint8(a))
      for b in [0'u8, 1, 127, 128, 254, 255]:
        for c in [0'u8, 1, 127, 128, 254, 255]:
          roundTrip(base & char(b) & char(c))

  test "encoding never grows a row by more than one byte per 128":
    # The worst case is all literals: one header byte per 128 data bytes. A row
    # that expands by more than that would silently double the size of a large
    # composite.
    for n in [0, 1, 127, 128, 129, 255, 256, 257, 1000, 4096]:
      var s = newString(n)
      for i in 0 ..< n: s[i] = char(uint8((i * 37) and 0xFF)) # never repeats
      let enc = packbitsEncode(s)
      check enc.len <= n + (n + 127) div 128
      check packbits(spanOf(enc), n) == s

  test "a uniform row compresses hard":
    # The sanity check in the other direction: a run must become a handful of
    # bytes, not a literal expansion.
    let s = repeat('A', 4096)
    let enc = packbitsEncode(s)
    check enc.len < s.len div 8

suite "packbits decoding rejects bad input":
  test "a truncated run is rejected":
    # A repeat header with no data byte behind it. Note that a repeat header
    # plus one byte is *valid* however many repeats it promises -- the count
    # lives in the header, not the data -- so the only truncated run is one
    # missing its single payload byte entirely.
    for header in ["\xFF", "\xFE", "\xFD", "\x81"]:
      expect PsdError:
        discard packbits(spanOf(header), 3)
    # And the valid form really does decode, which is why this is a real
    # boundary rather than a decoder that always refuses.
    check packbits(spanOf("\xFE" & "A"), 3) == "AAA"

  test "a truncated literal is rejected":
    let enc = "\x02" & "AB" # literal of 3, only 2 present
    expect PsdError:
      discard packbits(spanOf(enc), 3)

  test "output past the expected size is rejected":
    # The expected size is the bound, so a row that decodes to more is a
    # corrupt count rather than a short buffer.
    let enc = packbitsEncode(repeat('A', 100))
    expect PsdError:
      discard packbits(spanOf(enc), 10)

  test "short output is rejected":
    let enc = packbitsEncode(repeat('A', 10))
    expect PsdError:
      discard packbits(spanOf(enc), 100)

  test "arbitrary bytes never crash the decoder":
    # The reference's `packbits_decode_garbage_never_panics`. Deterministic
    # here: an exhaustive sweep over short inputs plus a seeded sweep over
    # longer ones, against a range of expected sizes.
    for n in 0 .. 40:
      for a in 0 .. 255:
        var data = newString(n)
        for i in 0 ..< n: data[i] = char(uint8((a + i * 61) and 0xFF))
        for expected in [0, 1, 7, 64, 300]:
          try:
            discard packbits(spanOf(data), expected)
          except PsdError:
            discard

  test "decoding into a known target writes the right bytes":
    # `packbitsDecodeInto` is the path the RLE decoder actually uses, and it
    # differs from `packbitsDecode` in that it writes at an offset. Check the
    # offset arithmetic across a row boundary.
    for src in ["", "A", "ABAB", repeat('X', 130), repeat('Y', 3)]:
      let enc = packbitsEncode(src)
      for offset in [0, 1, 7, 64, 200]:
        var dst = newString(offset + src.len + 16)
        discard packbitsDecodeInto(spanOf(enc), src.len, dst, offset, 0)
        check dst[offset ..< offset + src.len] == src

suite "channel codecs":
  test "planes round-trip at every depth, version and compression":
    # The property that matters end to end: whatever the geometry, encode then
    # decode returns the exact samples.
    for depth in [1, 8, 16, 32]:
      for version in AllVersions:
        for comp in AllCompressions:
          for (w, h) in [(0, 0), (1, 1), (3, 5), (17, 2)]:
            let l = newPlaneLayout(1, w, h, depth, version)
            let n = l.decodedLen()
            # A pattern with runs and gradients, so RLE and the predictor both
            # have something to work with.
            var data = newString(n)
            for i in 0 ..< n:
              data[i] = char(uint8(if (i div 8) mod 3 == 0: 0
                                   else: (i * 37) and 0xFF))
            let enc = encodePlanes(comp, data, l)
            check decodePlanes(comp, spanOf(enc), l) == data

  test "multiple planes round-trip as one buffer":
    for planes in 1 .. 4:
      for depth in [8, 16]:
        let l = newPlaneLayout(planes, 7, 3, depth, Version.Psd)
        let n = l.decodedLen()
        var data = newString(n)
        for i in 0 ..< n: data[i] = char(uint8((i * 13 + 5) and 0xFF))
        for comp in AllCompressions:
          let enc = encodePlanes(comp, data, l)
          check decodePlanes(comp, spanOf(enc), l) == data

  test "zip prediction round-trips exactly":
    # `predict`/`unpredict` is the only codec with a byte shuffle in it (depth
    # 32 splits each row into four byte planes), so it gets its own check.
    for depth in [1, 8, 16, 32]:
      for w in [1, 5, 16]:
        let l = newPlaneLayout(1, w, 4, depth, Version.Psd)
        var data = newString(l.decodedLen())
        for i in 0 ..< data.len: data[i] = char(uint8((i * 91) and 0xFF))
        var predicted = data
        predict(predicted, l)
        unpredict(predicted, l)
        check predicted == data
        # And through the real codec.
        let enc = encodePlanes(ZipPrediction, data, l)
        check decodePlanes(ZipPrediction, spanOf(enc), l) == data

  test "a zero-byte plane round-trips at every depth":
    # Degenerate geometry must not divide by zero or index past the end.
    for depth in [1, 8, 16, 32]:
      for version in AllVersions:
        let l = newPlaneLayout(1, 0, 0, depth, version)
        for comp in [Raw, Rle, Zip]:
          let enc = encodePlanes(comp, "", l)
          check decodePlanes(comp, spanOf(enc), l) == ""

  test "decoding garbage never crashes, at any depth or compression":
    # The reference's `channel_decode_garbage_never_panics`, swept
    # deterministically: every geometry in a small range against a set of
    # buffers built from a varying byte, which covers both the header and the
    # payload paths.
    for depth in [1, 8, 16, 32]:
      for comp in AllCompressions:
        for w in [0, 1, 4, 13]:
          for h in [0, 1, 3]:
            let l = newPlaneLayout(1, w, h, depth, Version.Psb)
            for filler in [0'u8, 1, 0x7F, 0x80, 0xFF]:
              let data = repeat(char(filler), 4 + w * h)
              try:
                discard decodePlanes(comp, spanOf(data), l)
              except PsdError:
                discard

  test "an unknown compression is refused rather than guessed":
    let l = newPlaneLayout(1, 4, 4, 8, Version.Psd)
    let unknown = Compression(kind: cUnknown, raw: 99'u16)
    expect PsdError:
      discard decodePlanes(unknown, spanOf(repeat('A', 16)), l)

  test "row byte counts follow the bit depth":
    # Depth 1 packs eight pixels per byte, which is the one case where the row
    # length is not `width * bytesPerSample` and where a wrong answer would
    # corrupt every Bitmap file.
    check rowBytes(8, 1) == 1
    check rowBytes(9, 1) == 2
    check rowBytes(16, 1) == 2
    check rowBytes(17, 1) == 3
    check rowBytes(8, 8) == 8
    check rowBytes(8, 16) == 16
    check rowBytes(8, 32) == 32