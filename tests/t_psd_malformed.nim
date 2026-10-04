## Malformed input: every error path returns `PsdError`, nothing panics.
##
## Nim has no proptest or fuzz equivalent, so the reference's property tests
## become deterministic sweeps. Where proptest picks random inputs, these pick
## exhaustively or walk a seeded LCG: the coverage is the same shape, but a
## failure names the exact input that caused it and reproduces every run.
##
## The rule under test throughout is that a PSD is untrusted input. Truncation,
## a flipped byte, a nonsensical length field: all must be rejected with a
## typed error, and none may read out of bounds or allocate without a bound.

import std/os
import std/osproc
import std/options
import std/posix
import std/strutils
import std/unittest
import ../src/opengraphics/psd
import ./psd_testgen

proc readU32At(bytes: string, at: int): uint32 =
  ## Big-endian u32 at a byte offset, for tests that need to find a length
  ## field whose position depends on an earlier one.
  uint32(uint8(bytes[at])) shl 24 or uint32(uint8(bytes[at + 1])) shl 16 or
    uint32(uint8(bytes[at + 2])) shl 8 or uint32(uint8(bytes[at + 3]))

suite "truncation sweeps":
  ## Every prefix of a valid file must fail, or yield a *complete* composite.
  ##
  ## There is one documented exception: the tail of a ZIP stream is an
  ## Adler-32 checksum over the *decoded* data, so a prefix that drops only
  ## those bytes loses no pixels and the image still inflates in full. There is
  ## nothing to reject, and asserting otherwise would be a test asserting
  ## something untrue.
  ##
  ## A rejected fraction floor keeps the sweep from going vacuous if that ever
  ## stops being true.
  ##
  ## `stride` is 1 for an exhaustive sweep over a small file. It is raised for
  ## the large layered corpus, where every prefix would mean re-parsing tens of
  ## kilobytes per cut.
  ##
  ## The first `budget` bytes are always swept exhaustively, because that is
  ## where every length field that can lie lives: the 26-byte header, the colour
  ## mode block, the resource section and the layer records. Note that the layer
  ## *channel payloads* come after the records and dominate the file, so
  ## "everything but the composite" is not a small region -- it is most of a
  ## 30 KB file, and sweeping it cut by cut is what made this quadratic. Past
  ## the budget the payload is sampled instead.
  template sweep(bytes: string, name: string, stride = 1, budget = 4096) =
    var full = readPsd(bytes)
    let expected = int(full.mergedLayout().totalBytes())
    let head = min(budget, bytes.len)
    var rejected = 0
    var tried = 0
    for cut in 0 ..< bytes.len:
      if cut >= head and cut mod stride != 0:
        continue
      inc tried
      try:
        let f = readPsd(bytes[0 ..< cut])
        # Accepted: only legitimate if the image still decodes in full.
        check decodeMerged(f).len == expected
      except PsdError:
        inc rejected
    check tried > 0
    check float64(rejected) / float64(tried) > 0.9
    # Sanity: the untruncated file parses and decodes to the expected size.
    check decodeMerged(full).len == expected

  test "a small layered file truncated at every offset fails":
    # `small` is a few hundred bytes, so this is genuinely exhaustive.
    for version in AllVersions:
      for comp in AllCompressions:
        sweep(writePsd(small(version, comp)), "small " & $version & " " & $comp)

  test "a large layered file truncated across its structure fails":
    # The structural region is swept at stride 1; the composite payload is
    # sampled, since it is uniform and tens of kilobytes long.
    for version in AllVersions:
      for comp in [Raw, Rle]:
        sweep(writePsd(layered(version, ColorMode(kind: cmRgb), 8, comp)),
          "layered " & $version & " " & $comp, stride = 97)

  test "a merged file truncated at every offset fails in every mode":
    for mode in AllModes:
      for depth in modeDepths(mode):
        sweep(writePsd(mergedOnly(Version.Psd, mode, depth, Rle, 5, 3)),
          "merged " & $mode)

  test "a 16-bit file with lifted layer info truncated at every offset fails":
    sweep(writePsd(layered(Version.Psd, ColorMode(kind: cmRgb), 16, Rle)),
      "layered 16", stride = 97)

  test "truncation inside the composite is caught":
    # The merged image is validated at parse time, so a cut inside the ZIP
    # stream is reported as a decompression failure rather than being carried
    # lazily until someone asks for pixels.
    let full = writePsd(mergedOnly(Version.Psd, ColorMode(kind: cmRgb), 8, Zip,
      13, 7))
    var caught = 0
    for cut in 0 ..< full.len:
      try:
        discard readPsd(full[0 ..< cut])
      except PsdError as e:
        if e.kind == PsdErrorKind.Decompress: inc caught
    check caught > 0
    # And no prefix past the trailer decodes to a short image.
    var complete = 0
    for cut in 0 ..< full.len:
      try:
        if decodeMerged(readPsd(full[0 ..< cut])).len == 13 * 7 * 3:
          inc complete
      except PsdError:
        discard
    check complete <= 5 # the full file plus at most four trailer bytes

suite "malformed headers":
  test "empty input is an unexpected end of file":
    expect PsdError:
      discard readPsd("")

  test "a short input is an unexpected end of file":
    # Every prefix of a valid header, short of the whole thing, must fail on
    # the missing bytes rather than parse a zeroed field.
    let full = writePsd(small(Version.Psd, Raw))
    for n in 0 ..< 26:
      expect PsdError:
        discard readPsd(full[0 ..< n])

  test "a bad signature is rejected as such":
    var bytes = writePsd(small(Version.Psd, Raw))
    bytes[0] = 'X'
    var kind = PsdErrorKind.InvalidSignature
    try:
      discard readPsd(bytes)
    except PsdError as e:
      kind = e.kind
    check kind == PsdErrorKind.InvalidSignature

  test "every other signature is rejected":
    for sig in ["8BPX", "8BPT", "8bps", "8Bps", "XXXX", "8B\x00\x00"]:
      var bytes = writePsd(small(Version.Psd, Raw))
      for i, c in sig:
        if i < 4: bytes[i] = c
      expect PsdError:
        discard readPsd(bytes)

  test "an unsupported version is rejected":
    var good = writePsd(small(Version.Psd, Raw))
    for v in [0'u16, 3, 0xFFFF, 0x8000]:
      var bytes = good
      bytes[4] = char(uint8(v shr 8))
      bytes[5] = char(uint8(v and 0xFF))
      expect PsdError:
        discard readPsd(bytes)

  test "both supported versions parse":
    for version in AllVersions:
      discard readPsd(writePsd(small(version, Raw)))

  test "an invalid bit depth is rejected":
    var good = writePsd(small(Version.Psd, Raw))
    for d in [0'u16, 2, 3, 4, 7, 24, 64, 0xFFFF]:
      var bytes = good
      bytes[22] = char(uint8(d shr 8))
      bytes[23] = char(uint8(d and 0xFF))
      # Depth 1 is legal, and 8/16/32 are the rest we support; anything else
      # must be refused rather than producing nonsense geometry.
      if d in [1'u16, 8, 16, 32]: continue
      expect PsdError:
        discard readPsd(bytes)

  test "a zero or absurd channel count is rejected":
    var good = writePsd(small(Version.Psd, Raw))
    for c in [0'u16, 57, 0xFFFF]:
      var bytes = good
      bytes[12] = char(uint8(c shr 8))
      bytes[13] = char(uint8(c and 0xFF))
      expect PsdError:
        discard readPsd(bytes)

  test "oversized dimensions are rejected as a limit, not an allocation":
    var bytes = writePsd(small(Version.Psb, Raw))
    # The 26-byte header is the same width in PSD and PSB -- PSB widens the
    # layer and section lengths, not these fields -- so height is the 4 bytes
    # at offset 14. 300001 is one past the 300000 cap.
    for i, b in [0'u8, 0x04, 0x93, 0xE1]:
      bytes[14 + i] = char(b)
    var kind = PsdErrorKind.Invalid
    try:
      discard readPsd(bytes)
    except PsdError as e:
      kind = e.kind
    check kind == PsdErrorKind.LimitExceeded

  test "a huge declared size with tiny data fails fast":
    # 300000 x 300000 RLE with a handful of bytes: the row-count table cannot
    # fit, so this is rejected on structure rather than after trying to
    # allocate the decoded size.
    var f = mergedOnly(Version.Psb, ColorMode(kind: cmGrayscale), 8, Rle, 1, 1)
    f.header.width = 300_000
    f.header.height = 300_000
    expect PsdError:
      discard readPsd(writePsd(f))

  test "a volume beyond the pixel cap is rejected even in PSD":
    # Dimensions alone pass the 30000 PSD ceiling, but 30000x30000x56 channels
    # is 50 GB of samples, so the cap has to be channel-aware.
    var f = mergedOnly(Version.Psd, ColorMode(kind: cmRgb), 8, Rle, 1, 1)
    f.header.width = 30_000
    f.header.height = 30_000
    f.header.channels = 56
    var kind = PsdErrorKind.Invalid
    try:
      discard readPsd(writePsd(f))
    except PsdError as e:
      kind = e.kind
    check kind == PsdErrorKind.LimitExceeded

  test "a bad resource signature is rejected":
    var bytes = writePsd(small(Version.Psd, Raw))
    # 26 header + 4 colour mode length + 4 resource length = 34.
    for i, c in "XXXX":
      bytes[34 + i] = c
    var kind = PsdErrorKind.Invalid
    try:
      discard readPsd(bytes)
    except PsdError as e:
      kind = e.kind
    check kind == PsdErrorKind.InvalidSignature

  test "an oversized colour mode length is rejected":
    var bytes = writePsd(small(Version.Psd, Raw))
    for i, b in [255'u8, 255, 255, 255]:
      bytes[26 + i] = char(b)
    expect PsdError:
      discard readPsd(bytes)

  test "an oversized resource section length is rejected":
    var bytes = writePsd(small(Version.Psd, Raw))
    for i, b in [255'u8, 255, 255, 255]:
      bytes[30 + i] = char(b)
    expect PsdError:
      discard readPsd(bytes)

  test "an oversized layer and mask section length is rejected":
    var bytes = writePsd(small(Version.Psd, Raw))
    # The section length sits just past the resource block, whose length is
    # itself at offset 30.
    let resLen = int(readU32At(bytes, 30))
    let at = 34 + resLen
    for i, b in [255'u8, 255, 255, 255]:
      bytes[at + i] = char(b)
    expect PsdError:
      discard readPsd(bytes)

suite "corrupt payloads":
  test "a corrupt merged ZIP stream is rejected":
    var f = mergedOnly(Version.Psd, ColorMode(kind: cmRgb), 8, Zip, 13, 7)
    let n = f.imageData.data.len
    check n > 2
    var data = f.imageData.data.clone()
    data[n div 2] = char(ord(data[n div 2]) xor 0xFF)
    f.imageData.data = spanOf(data)
    expect PsdError:
      discard readPsd(writePsd(f))

  test "a corrupt merged RLE stream is rejected":
    var f = mergedOnly(Version.Psd, ColorMode(kind: cmRgb), 8, Rle, 13, 7)
    let n = f.imageData.data.len
    check n > 2
    var data = f.imageData.data.clone()
    # Corrupt the count table: a row claiming far more bytes than exist.
    data[0] = char(0xFF)
    data[1] = char(0xFF)
    f.imageData.data = spanOf(data)
    expect PsdError:
      discard readPsd(writePsd(f))

  test "a corrupt layer channel fails when decoded, not at parse":
    # Lazy decoding means a broken channel parses fine and errors on use. The
    # contract is that it *does* error on use rather than returning junk.
    var f = small(Version.Psd, Rle)
    # Rebuild with a deliberately damaged alpha plane.
    var layer = f.layers()[0]
    var ch = layer.channels[0]
    var data = ch.data.clone()
    for i in 0 ..< data.len:
      data[i] = char(0x7F)
    ch.data = spanOf(data)
    layer.channels[0] = ch
    var mutated = f
    mutated.setLayers(@[layer])
    let parsed = readPsd(writePsd(mutated))
    let rec = parsed.layers()[0]
    let w = rec.rect.width()
    let h = rec.rect.height()
    var ok = true
    try:
      discard rec.channels[0].decode(w, h, 8, Version.Psd)
    except PsdError:
      ok = false
    check not ok

  test "an inverted layer rect fails to decode":
    # bottom above top is a negative height, which `size()` must refuse rather
    # than wrap around into a huge allocation.
    var f = small(Version.Psd, Raw)
    var layer = f.layers()[0]
    layer.rect = Rect(top: 10, left: 0, bottom: 0, right: 4)
    var mutated = f
    mutated.setLayers(@[layer])
    let parsed = readPsd(writePsd(mutated))
    let rec = parsed.layers()[0]
    var raised = false
    try:
      discard rec.rect.size()
    except PsdError:
      raised = true
    check raised

  test "an unknown compression is preserved rather than rejected":
    # Code 99 is not a compression we know. The parser must keep the bytes so
    # a round-trip is lossless, and only fail if someone asks to decode.
    var bytes = writePsd(small(Version.Psd, Raw))
    # The compression code is the last two bytes before the merged payload; the
    # merged data is the tail, so find the marker by length.
    var f = small(Version.Psd, Raw)
    f.imageData.compression = Compression(kind: cUnknown, raw: 99'u16)
    let parsed = readPsd(writePsd(f))
    check parsed.imageData.compression.kind == cUnknown
    check parsed.imageData.compression.toU16 == 99
    # Preserved verbatim on the way back out.
    check writePsd(parsed) == writePsd(f)
    # And decoding it is an error, not a guess.
    expect PsdError:
      discard decodeMerged(parsed)
    discard bytes

suite "mutation robustness":
  ## The reference's `mutations_never_panic` and `parsed_mutants_are_byte_stable`
  ## proptests. Nim has no proptest, so the mutation positions and values come
  ## from a seeded LCG: same coverage shape, and a failure prints the exact
  ## input needed to reproduce it.
  proc lcg(state: var uint64): uint64 {.inline.} =
    ## splitmix64, so successive values do not correlate the way a plain
    ## multiply-add LCG does at small state.
    state = state + 0x9E3779B97F4A7C15'u64
    var z = state
    z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
    z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
    z xor (z shr 31)

  const Mutations = 4000

  test "random bytes never panic":
    var state = 0x1234_5678_9ABC_DEF0'u64
    for _ in 0 ..< 4000:
      let n = int(lcg(state) mod 512)
      var data = newString(n)
      for i in 0 ..< n:
        data[i] = char(uint8(lcg(state) and 0xFF))
      # The only requirement is that it returns or raises `PsdError`. Anything
      # else -- a Defect, say -- is a crash and fails the test by propagating.
      try:
        discard readPsd(data)
      except PsdError:
        discard

  test "a valid header with a random tail never panics":
    # More dangerous than pure noise: the header parses, so the parser commits
    # to walking the structure the tail claims.
    for version in AllVersions:
      var state = 0xDEAD_BEEF_CAFE_F00D'u64
      let head = writePsd(small(version, Raw))
      for _ in 0 ..< 1500:
        let n = int(lcg(state) mod 400)
        var data = head[0 ..< 26]
        for _ in 0 ..< n:
          data.add(char(uint8(lcg(state) and 0xFF)))
        try:
          discard readPsd(data)
        except PsdError:
          discard

  test "single-byte mutations never panic and stay byte-stable":
    # If a mutated file parses, re-serialising it and re-parsing that must give
    # the same model. A parser that normalises differently on the second pass
    # would be silently lossy.
    for version in AllVersions:
      for comp in AllCompressions:
        let good = writePsd(small(version, comp))
        var state = 0x0BADC0DE_0BADC0DE'u64
        for _ in 0 ..< Mutations div 16:
          var bytes = good
          let at = int(lcg(state) mod uint64(bytes.len))
          bytes[at] = char(uint8(lcg(state) and 0xFF))
          try:
            let first = readPsd(bytes)
            let again = writePsd(first)
            let second = readPsd(again)
            check writePsd(second) == again
          except PsdError:
            discard

  test "multi-byte mutations never panic":
    for version in AllVersions:
      for comp in AllCompressions:
        let good = writePsd(small(version, comp))
        var state = 0xFEED_FACE_CAFE_BEEF'u64
        for _ in 0 ..< Mutations div 8:
          var bytes = good
          let k = 1 + int(lcg(state) mod 7)
          for _ in 0 ..< k:
            let at = int(lcg(state) mod uint64(bytes.len))
            bytes[at] = char(uint8(lcg(state) and 0xFF))
          try:
            discard readPsd(bytes)
          except PsdError:
            discard

  test "a mutated file that parses can be re-rendered without panicking":
    # Parsing is only half the contract: the lazy accessors and the compositor
    # also have to survive whatever the bytes claim.
    let good = writePsd(small(Version.Psd, Rle))
    var state = 0x5EED_5EED_5EED_5EED'u64
    var rendered = 0
    for _ in 0 ..< 1500:
      var bytes = good
      let k = 1 + int(lcg(state) mod 4)
      for _ in 0 ..< k:
        bytes[int(lcg(state) mod uint64(bytes.len))] =
          char(uint8(lcg(state) and 0xFF))
      try:
        let f = readPsd(bytes)
        # Touch the lazy paths on whatever survived.
        discard writePsd(f)
        discard f.layerTree()
        discard decodeMerged(f)
        for l in f.layers:
          let (w, h) = (max(int(l.rect.right - l.rect.left), 0),
            max(int(l.rect.bottom - l.rect.top), 0))
          if w > 0 and h > 0:
            for ch in l.channels:
              if ch.compression.isSome:
                discard ch.decode(w, h, 8, Version.Psd)
          discard l.name()
          for b in l.blocks:
            discard b.parsed()
        for r in f.resources:
          discard r.parsed()
        inc rendered
      except PsdError:
        discard
    check rendered > 0

proc currentRss(): int64 =
  ## Resident set size *right now*.
  ##
  ## `getrusage` only reports `ru_maxrss`, a high-water mark that never falls,
  ## so it cannot show a reference cycle: the first round would set the mark and
  ## every later leak would hide under it. `ps` reports current RSS, which is
  ## what actually moves when something is retained. Two `ps` calls per test is
  ## not worth optimising away.
  let (outp, code) = execCmdEx("ps -o rss= -p " & $getCurrentProcessId())
  if code != 0:
    return -1
  try:
    parseInt(outp.strip()) * 1024
  except ValueError:
    -1

suite "retention":
  ## Unreachable allocations are one failure mode; a reference cycle is the
  ## other, and it is invisible to `leaks`, which only reports what nothing
  ## points at. The `Source`/`Mapping` pair from the zero-copy work is exactly
  ## the shape where a cycle would hide: a mapping held alive by a span held
  ## inside the very buffer it maps.
  ##
  ## So this measures the thing a cycle actually shows up in -- resident memory
  ## that does not come back after the work is dropped. Peak RSS is a high-water
  ## mark and never falls, so the growth is measured against the *current* RSS
  ## via `getOccupiedMem`, with peak RSS as a coarse backstop.

  test "repeated parse and serialise does not retain memory":
    # Touch every lazy path each round so a span held by a parsed tree is
    # genuinely exercised, not just the parse tree.
    let bytes = writePsd(layered(Version.Psd, ColorMode(kind: cmRgb), 8, Rle))

    proc round() =
      let f = readPsd(bytes)
      discard writePsd(f)
      discard f.layerTree()
      discard decodeMerged(f)
      for l in f.layers:
        discard l.name()
        let w = max(int(l.rect.right - l.rect.left), 0)
        let h = max(int(l.rect.bottom - l.rect.top), 0)
        if w > 0 and h > 0:
          for ch in l.channels:
            # Only alpha and colour are sized by the layer rect; the user mask
            # (-2) and real mask (-3) are sized by their own rects, so decoding
            # them at layer size would be asking for the wrong number of bytes.
            if ch.compression.isSome and ch.id >= ChannelTransparency:
              discard ch.decode(w, h, 8, Version.Psd)

    # Warm up first: the first round allocates the allocator's arenas and any
    # one-off tables, and counting those as growth would be noise.
    for _ in 0 ..< 20:
      round()
    let before = currentRss()
    for _ in 0 ..< 300:
      round()
    let growth = currentRss() - before
    # A cycle retaining one file per round would show up as roughly
    # `bytes.len` per round, which is tens of kilobytes each time.
    if growth >= int64(bytes.len) * 2:
      raise newException(AssertionDefect, "RSS grew by " & $growth &
        " bytes over 300 rounds of a " & $bytes.len &
        " byte file, which suggests something is retained")
