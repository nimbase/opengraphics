## Cross-implementation conformance against the Rust reference.
##
## Descriptor parsing is the one place where this codebase and
## `photocraft/crates/psd` are genuinely independent implementations of a
## grammar the Adobe documentation does not fully specify -- `UnFl`, `ObAr` and
## the trailing-data rules were all worked out by reading real files. Two
## implementations agreeing on a round trip is much stronger evidence than
## either one passing tests written against itself, so this suite checks both
## against the other, on descriptors taken from real Photoshop files rather than
## from fixtures this repository generated.
##
## It shells out to a small harness built from the reference. If that harness
## is absent the cross-check is skipped rather than failed: the reference is a
## separate checkout on the user's machine, not a dependency of this package.
## Point `OG_ORACLE` at the binary to run it.

import std/[options, os, osproc, strutils]
import std/unittest
import ../src/opengraphics/psd

const
  OracleEnv = "OG_ORACLE"
  # Under the gitignored testresults/ rather than a temp directory: an earlier
  # version of this harness lived in one and was cleaned up underneath us, at
  # which point both cross-checks started silently skipping. A guard that stops
  # guarding without saying so is worse than no guard.
  DefaultOracle = "testresults/psd-oracle/target/release/psd-oracle"
  Fixtures = ["01.psd", "02.psd", "03.psd"]

  DescriptorKeys = ["vogk", "vstk", "GdFl", "PtFl", "lfx2", "SoCo", "SoLd",
    "PlLd", "curv", "levl", "hue2", "blnc", "expA", "vscg", "vsgm"]

type
  Blob = object
    key: string
    where: string
    data: string

proc oraclePath(): string =
  let p = getEnv(OracleEnv)
  result = if p.len > 0: p else: DefaultOracle

proc requireOracle(): bool =
  ## True when the harness is present. Echoes loudly when it is not, because
  ## `skip()` takes no message and would otherwise leave the suite quietly
  ## reporting success while checking nothing against the reference.
  if fileExists(oraclePath()):
    return true
  echo "NOTE: cross-checks against the reference are SKIPPED. Harness not built at ",
    oraclePath(), ". Build it with:"
  echo "  cd testresults/psd-oracle && cargo build --release"
  false

# `vogk` is the one key whose payload is not a bare versioned descriptor: it
# carries a leading `u32 1` marker, so it needs its own entry point. Getting
# this wrong is silent -- the marker is read as a version, and the parse then
# fails deep in the body looking for a plausible string length.
proc parseBlock(key: string, data: Span): VersionedDescriptor =
  if key == "vogk":
    return parseOriginationDescriptor(data)
  parseVersionedDescriptor(data)

proc reemit(b: Blob): string =
  if b.key == "vogk":
    return parseOriginationDescriptor(b.data).originationToBytes()
  parseVersionedDescriptor(b.data).toBytes()

proc xrefPattern(depth: uint16, mode: uint32, withAlpha, paletted: bool): PsdPattern =
  ## A tile with distinctive, depth- and mode-dependent contents so that a
  ## mis-sized plane or a swapped channel cannot survive a round trip.
  let cc = modeChannels(mode)
  let w = if mode == 1: 4'u32 else: 7'u32
  let h = 3'u32
  let bpp = max(int(depth) div 8, 1)
  result = PsdPattern(
    mode: mode, width: w, height: h,
    name: "d" & $depth & " m" & $mode & (if withAlpha: " a" else: "") &
      (if paletted: " p" else: ""),
    id: "0bd2d3ba-1234-11d4-8f8f-aabbccddeeff",
    depth: depth)
  let n = int(w) * int(h) * bpp
  for c in 0 ..< cc:
    var buf = newSeq[byte](n)
    for i in 0 ..< n:
      buf[i] = (uint8(i) * 7'u8 + uint8(c) * 53'u8 + uint8(mode)) and 0xFF'u8
    result.channels.add cast[string](buf)
  if withAlpha:
    var buf = newSeq[byte](n)
    for i in 0 ..< n:
      buf[i] = (uint8(i) * 3'u8 + 11'u8) and 0xFF'u8
    result.alpha = some(cast[string](buf))
  if paletted:
    var buf = newSeq[byte](768)
    for i in 0 ..< 768:
      buf[i] = uint8(i) and 0xFF'u8
    result.palette = some(cast[string](buf))

proc collectDescriptors(): seq[Blob] =
  ## Every tagged block in every fixture whose payload parses as a descriptor.
  ## Parsing is the filter, not a fixed key list, so a block we learn to
  ## recognise later is picked up here without touching this suite.
  for f in Fixtures:
    let path = "tests/data/" & f
    if not fileExists(path): continue
    let doc = readPsd(readFile(path))
    for layer in doc.layers:
      for b in layer.blocks:
        try:
          discard parseBlock(b.key, b.data)
          result.add Blob(key: b.key, where: f & "/" & layer.name,
            data: b.data.clone)
        except PsdError:
          discard # not a descriptor, or a layout we do not model
    for b in doc.globalBlocks:
      try:
        discard parseBlock(b.key, b.data)
        result.add Blob(key: b.key, where: f & "/global", data: b.data.clone)
      except PsdError:
        discard

proc filterBlocks(key: string): seq[Blob] =
  for b in collectDescriptors():
    if b.key == key: result.add b

suite "descriptor round trip on real Photoshop files":
  test "the fixtures contain a spread of descriptors":
    let blobs = collectDescriptors()
    check blobs.len > 0
    # Guard against the suite going vacuous if fixtures are replaced.
    check blobs.len >= 3
    # Both descriptor-bearing fill keys must be present, or the origination
    # case below is never exercised.
    var keys: seq[string]
    for b in blobs:
      if b.key notin keys: keys.add b.key
    check "vogk" in keys
    check "vstk" in keys

  test "every descriptor re-serialises to exactly the input bytes":
    # The property that lets tagged blocks be typed without breaking byte-exact
    # file round trips: an untyped block is emitted verbatim, so a typed one has
    # to be indistinguishable.
    for b in collectDescriptors():
      check b.reemit() == b.data

suite "descriptor agreement with the reference implementation":
  test "the reference round-trips every descriptor it can read":
    # Cross-check: our parse and the reference's parse of the same real
    # Photoshop descriptor must both be faithful. Disagreement is a bug in one
    # of the two, which is the entire reason for having two.
    # Note: `skip()` only marks a test skipped, it does not stop the body, so the
    # guard has to be a branch rather than an early return. Otherwise a declared
    # skip carries on and execs a missing binary, which fails the very test it
    # just said was not applicable.
    let oracle = oraclePath()
    if requireOracle():
      var checked = 0
      for b in collectDescriptors():
        if b.key == "vogk":
          continue # see the next test; the reference cannot read these at all
        let tmpIn = getTempDir() / ("xref_in_" & $checked & ".bin")
        let tmpOut = getTempDir() / ("xref_out_" & $checked & ".bin")
        writeFile(tmpIn, b.data)
        let (_, code) = execCmdEx(oracle & " roundtrip " & quoteShell(tmpIn) &
          " " & quoteShell(tmpOut))
        check code == 0
        check readFile(tmpOut) == b.data
        removeFile(tmpIn)
        removeFile(tmpOut)
        inc checked
      check checked >= 3
    else:
      skip() # reference harness not built; see OG_ORACLE

  test "vogk is readable here and rejected by the reference":
    # The one known divergence, pinned in both directions so it cannot change
    # silently. `vogk` wraps its descriptor in a `u32 1` marker; the reference
    # requires the version to be 16, so it rejects the block. If a future
    # reference fixes this, or Photoshop changes the layout, this fails and the
    # difference gets looked at instead of rotting.
    let blobs = filterBlocks("vogk")
    check blobs.len > 0
    # Ours first, unconditionally: this half does not need the reference.
    for b in blobs:
      check b.reemit() == b.data
      check parseOriginationDescriptor(b.data).descriptor.items.len > 0
    let oracle = oraclePath()
    if requireOracle():
      for b in blobs:
        # Theirs: refuses it.
        let tmpIn = getTempDir() / "xref_vogk.bin"
        let tmpOut = getTempDir() / "xref_vogk_out.bin"
        writeFile(tmpIn, b.data)
        let (_, code) = execCmdEx(oracle & " roundtrip " & quoteShell(tmpIn) &
          " " & quoteShell(tmpOut))
        check code != 0
    else:
      skip() # reference harness not built; see OG_ORACLE
suite "pattern block agreement with the reference implementation":
  test "the reference reads a Patt block exactly as we wrote it":
    # The round-trip tests in `t_psd_core_patterns` already cover every depth and
    # the alpha/palette variants, but writer and reader share one model of the
    # format, so they agree with each other even when both are wrong. This is the
    # only check that says anything: the reference is an independent reading of
    # the same specification, so agreement is evidence and disagreement is a bug
    # in one of the two. It is still consensus rather than ground truth --
    # nothing here has been validated against bytes Photoshop wrote, because no
    # fixture has a populated `Patt`.
    if not requireOracle():
      skip()
    let oracle = oraclePath()
    var checked = 0
    for depth in [8'u16, 16, 32]:
      for mode in [1'u32, 2, 3, 4, 7, 8, 9]:
        for withAlpha in [false, true]:
          for paletted in [false, true]:
            let blk = writePatternBlock(@[xrefPattern(depth, mode, withAlpha, paletted)])
            let tmpIn = getTempDir() / ("pat_in_" & $checked & ".bin")
            let tmpOut = getTempDir() / ("pat_out_" & $checked & ".bin")
            writeFile(tmpIn, blk)
            let (_, code) = execCmdEx(oracle & " patterns " & quoteShell(tmpIn) &
              " " & quoteShell(tmpOut))
            check code == 0
            check readFile(tmpOut) == blk
            removeFile(tmpIn)
            removeFile(tmpOut)
            inc checked
    check checked == 3 * 7 * 2 * 2

  test "several patterns in one block agree too":
    # Order matters: a pattern fills reference its index and id by position, so a
    # block whose patterns come back reordered would resolve fills wrongly even
    # though every individual pattern survived.
    if not requireOracle():
      skip()
    let oracle = oraclePath()
    let ps = @[
      xrefPattern(8, 3, false, false),
      xrefPattern(8, 3, true, false),
      xrefPattern(16, 3, false, false),
      xrefPattern(32, 4, true, true)]
    let blk = writePatternBlock(ps)
    let tmpIn = getTempDir() / "pat_multi_in.bin"
    let tmpOut = getTempDir() / "pat_multi_out.bin"
    writeFile(tmpIn, blk)
    let (outp, code) = execCmdEx(oracle & " patterns " & quoteShell(tmpIn) &
      " " & quoteShell(tmpOut))
    check code == 0
    check readFile(tmpOut) == blk
    # And the reference saw the same names in the same order.
    for p in ps:
      check outp.find(p.name) >= 0
    removeFile(tmpIn)
    removeFile(tmpOut)
