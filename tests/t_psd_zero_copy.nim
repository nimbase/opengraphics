## Proving the parser is zero-copy, rather than asserting it from reading code.
##
## Three kinds of evidence:
##
## - Pointer identity. A span's bytes must lie at exactly `source.base + start`.
##   A deep copy would land somewhere else, so these tests fail the moment one
##   sneaks back in.
## - Accounting. The tree's windows must account for every payload byte in the
##   file, so identity plus accounting is a complete proof: if nothing is
##   copied, nothing can be duplicated either.
## - Peak RSS via `getrusage`, for the process-level claim.
##
## Note on `getOccupiedMem`: it is *not* used here. Measured on nim 2.2.12 it
## charges the full size of a string every time a new reference to it is
## created -- aliasing a 1 MiB string costs 1,081,360 bytes -- so it cannot
## distinguish a copy from a reference and is worse than useless for this.

import std/os
import std/options
import posix
import unittest

import ../src/opengraphics/psd

const BigFixture = "tests/data/02.psd"

proc peakRss(): int64 =
  ## Peak resident set size in bytes. Monotonic, so it answers "how much more
  ## memory did this cost" as a lower bound rather than an exact figure.
  var ru: Rusage
  if getrusage(RUSAGE_SELF, addr ru) == 0:
    # Linux reports kilobytes; the BSDs and macOS report bytes.
    when defined(linux):
      result = int64(ru.ru_maxrss) * 1024
    else:
      result = int64(ru.ru_maxrss)
  else:
    result = -1

proc inside(s: Span, src: Source): bool =
  ## True when `s`'s bytes are inside `src`'s own buffer rather than a copy.
  if s.len == 0:
    return true
  let lo = cast[int](src.base)
  let p = cast[int](s.base)
  p >= lo and p + s.len <= lo + src.size

proc atStart(s: Span, src: Source): bool =
  ## Stronger than `inside`: the window begins exactly where its offset says.
  if s.len == 0:
    return true
  cast[int](s.base) == cast[int](src.base) + s.start

proc payloadBytes(f: PsdFile): int64 =
  ## Every payload byte the tree points at.
  for l in f.layers():
    for c in l.channels: result += int64(c.data.len)
    for b in l.blocks: result += int64(b.data.len)
    result += int64(l.extraTrailing.len) + int64(l.blendingRanges.data.len)
    if l.mask.kind == mdMask:
      result += int64(l.mask.mask.trailing.len)
    elif l.mask.kind == mdRaw:
      result += int64(l.mask.raw.len)
  for b in f.globalBlocks: result += int64(b.data.len)
  for r in f.resources: result += int64(r.data.len)
  if f.globalLayerMask.isSome:
    result += int64(f.globalLayerMask.get().data.len)
  result += int64(f.imageData.data.len) + int64(f.layerMaskTrailing.len) +
    int64(f.colorModeData.len)
  if f.layerInfo.isSome and f.layerInfo.get().padding.isSome:
    result += int64(f.layerInfo.get().padding.get().len)

suite "zero-copy: every payload is a window into the file":
  test "02.psd's payloads sit at the offsets their lengths describe":
    let f = readPsd(readFile(BigFixture))
    let src = f.source

    var checked = 0
    proc touch(s: Span) =
      check inside(s, src)
      check atStart(s, src)
      inc checked

    # the merged composite, the largest single payload in any PSD
    touch(f.imageData.data)
    # every channel of every layer
    for l in f.layers():
      for c in l.channels: touch(c.data)
    # every tagged block, on the layers and in the global region
    for l in f.layers():
      for b in l.blocks: touch(b.data)
      touch(l.extraTrailing)
      touch(l.blendingRanges.data)
      if l.mask.kind == mdMask: touch(l.mask.mask.trailing)
      elif l.mask.kind == mdRaw: touch(l.mask.raw)
    for b in f.globalBlocks: touch(b.data)
    # resources, colour data, the global mask, the section tail
    for r in f.resources: touch(r.data)
    touch(f.colorModeData)
    touch(f.layerMaskTrailing)
    if f.globalLayerMask.isSome: touch(f.globalLayerMask.get().data)

    check checked > 1000
    check f.layers().len == 75

  test "all payloads of one file share a single source":
    let f = readPsd(readFile(BigFixture))
    let src = f.source
    check src.kind == skString
    check src.size == BigFixture.getFileSize.int
    for l in f.layers():
      for c in l.channels: check c.data.source == src
      for b in l.blocks: check b.data.source == src
    for b in f.globalBlocks: check b.data.source == src
    for r in f.resources: check r.data.source == src
    check f.imageData.data.source == src

  test "the composite window starts after the header, not at zero":
    # If anything about the offsets were wrong this would read the signature
    let f = readPsd(readFile(BigFixture))
    check f.imageData.data.start > 26
    check atStart(f.imageData.data, f.source)
    check f.imageData.data.len == 1280 * 640 * 3 # raw, 8-bit, three channels

  test "the tree's windows account for the whole file":
    # Identity plus accounting is the complete argument: nothing was copied, so
    # nothing can be holding a duplicate.
    let f = readPsd(readFile(BigFixture))
    let total = payloadBytes(f)
    let fileSize = BigFixture.getFileSize.int64
    # within a percent: the remainder is layer records, length fields and
    # padding, none of which are stored as payload spans
    check total > fileSize * 98 div 100
    check total <= fileSize

suite "zero-copy: peak memory does not scale with file size":
  test "re-parsing 02.psd does not raise peak RSS by the file's size":
    # Warm up first, so the allocator's arena is already large enough that a
    # fresh 47 MB allocation cannot hide inside reused pages.
    discard readPsdFile(BigFixture)
    GC_fullCollect()
    let before = peakRss()
    check before > 0
    var trees: array[3, PsdFile]
    for i in 0 ..< 3:
      trees[i] = readPsdFile(BigFixture)
    let growth = peakRss() - before

    # Three trees held at once. A copying parser needs 3 x 45 MB more; a
    # zero-copy one needs only the tree overhead, which is kilobytes.
    let fileSize = BigFixture.getFileSize.int64
    check growth < fileSize
    # and the trees really are all there
    for t in trees:
      check t.layers().len == 75
      check atStart(t.imageData.data, t.source)

  test "a string source and a mapped source give the same tree":
    let fromMap = readPsdFile(BigFixture)
    let fromString = readPsd(readFile(BigFixture))
    check fromMap.width == fromString.width
    check fromMap.height == fromString.height
    check fromMap.layers().len == fromString.layers().len
    check fromMap.resources.len == fromString.resources.len
    check fromMap.globalBlocks.len == fromString.globalBlocks.len
    check payloadBytes(fromMap) == payloadBytes(fromString)
    check fromMap.imageData.data == fromString.imageData.data
    for i in 0 ..< fromMap.layers().len:
      check fromMap.layers()[i].name == fromString.layers()[i].name
      check fromMap.layers()[i].rect == fromString.layers()[i].rect
      check fromMap.layers()[i].channels.len ==
        fromString.layers()[i].channels.len

  test "both routes round-trip byte for byte":
    let original = readFile(BigFixture)
    check writePsd(readPsd(original)) == original
    check writePsd(readPsdFile(BigFixture)) == original

  test "reading many small trees does not scale with their bytes":
    # 03.psd is 1 MB; twenty trees of it must cost tree overhead, not 20 MB.
    let bytes = readFile("tests/data/03.psd")
    discard readPsd(bytes) # warm up
    GC_fullCollect()
    let before = peakRss()
    var trees: array[20, PsdFile]
    for i in 0 ..< 20:
      trees[i] = readPsd(bytes)
    let growth = peakRss() - before
    for t in trees:
      check t.layers().len == 3
    check growth < int64(bytes.len) * 4

suite "mmap: opening from disk":
  test "openPsd maps and still decodes":
    let d = openPsd(BigFixture, ReadOptions(skipCompositeImageData: true))
    check d.file.layers().len == 75
    check not d.hasComposite

  test "openPsdRead is the heap-reading fallback":
    let d = openPsdRead(BigFixture, ReadOptions(skipCompositeImageData: true))
    check d.file.layers().len == 75
    check not d.hasComposite

  test "a window read after its file is unreferenced still works":
    # `Source` owns the mapping and unmaps on finalisation; a Span holds a
    # reference, so this must not touch unmapped pages.
    var channelData: Span
    block:
      let f = readPsdFile(BigFixture)
      for l in f.layers():
        for c in l.channels:
          if c.data.len > 100_000:
            channelData = c.data
            break
        if channelData.len > 0:
          break
    check channelData.len > 100_000
    # read it well after the PsdFile went out of scope
    var sum = 0'u64
    for i in 0 ..< channelData.len:
      sum += uint64(channelData.byteAt(i))
    check sum > 0