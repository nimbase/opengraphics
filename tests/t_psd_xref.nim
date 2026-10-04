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

import std/[os, osproc, strutils]
import std/unittest
import ../src/opengraphics/psd

const
  OracleEnv = "OG_ORACLE"
  DefaultOracle = "/var/folders/2k/8b2pmhg15lq6853zbt_v_1mw0000gn/T/opencode/psd-oracle/target/release/psd-oracle"
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
    if fileExists(oracle):
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
    if fileExists(oracle):
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