## `Span` and `Source`: the zero-copy primitives the parser is built on.

import std/os
import std/strutils
import std/unittest

import ../src/opengraphics/psd/span

proc alphabetSource(): Source =
  ## A 1000-byte source, `A` to `J` repeating, so any offset error shows up.
  newStringSource("ABCDEFGHIJ".repeat(100))

proc tmpPath(name: string): string =
  getTempDir() / ("opengraphics_span_" & name)

suite "span: sources":
  test "a string source shares the caller's buffer without copying":
    let text = "hello world"
    let s = newStringSource(text)
    check s.kind == skString
    check s.size == 11
    check s.buf == text
    # sharing, not a copy: the source holds the very same allocation
    check cast[int](s.base) == cast[int](unsafeAddr text[0])

  test "an empty string is a valid, zero-length source":
    let s = newStringSource("")
    check s.size == 0
    check s.base == nil
    check s.equals("")

  test "a nil source raises on size rather than crashing":
    let s = cast[Source](nil)
    expect(ValueError):
      discard s.size
    check s.base == nil
    check not s.isMapped

  test "a seq source takes exactly one copy at the boundary":
    let s = newBytesSource(@[byte(1), 2, 3, 4])
    check s.size == 4
    check s.byteAt(0) == 1'u8
    check s.byteAt(3) == 4'u8
    check newBytesSource(@[]).size == 0

  test "byteAt is bounds-checked":
    let s = newStringSource("abc")
    expect(IndexDefect):
      discard s.byteAt(3)
    expect(IndexDefect):
      discard s.byteAt(-1)

suite "span: windows":
  test "a span reports its own length, not the buffer's":
    let src = alphabetSource()
    let whole = Span(src: src, start: 0, stop: src.size)
    let mid = whole.slice(10, 20)
    check whole.len == 1000
    check mid.len == 10
    check mid.start == 10
    check mid.source == whole.source

  test "an empty span has a nil base and reads empty":
    let src = alphabetSource()
    let e = Span(src: src, start: 5, stop: 5)
    check e.isEmpty
    check e.base == nil
    check e.clone == ""

  test "slice is bounded by the source, not just by the span":
    # a Span that described bytes past the buffer would make byteAt a wild read,
    # so the window is closed at construction
    let src = alphabetSource()
    let s = Span(src: src, start: 0, stop: 4)
    check s.slice(0, 4).len == 4
    expect(IndexDefect):
      discard s.slice(0, 99)
    expect(IndexDefect):
      discard s.slice(-1, 2)
    expect(IndexDefect):
      discard s.slice(2, 1)
    expect(IndexDefect):
      discard Span(src: src, start: 0, stop: 4).slice(0, 4).slice(0, 5)
    expect(IndexDefect):
      discard Span(src: src, start: 998, stop: 1000).slice(0, 4)

  test "head and tailFrom carve the ends without advancing":
    let src = alphabetSource()
    let whole = Span(src: src, start: 0, stop: src.size)
    check whole.head(4).len == 4
    check char(whole.head(1).byteAt(0)) == 'A'
    check whole.tailFrom(996).len == 4
    check whole.tailFrom(1000).isEmpty
    # a Span is a value, so slicing never consumes: `whole` is unchanged
    check whole.len == 1000

  test "byteAt is bounds-checked against the span, not the source":
    let src = alphabetSource()
    let s = Span(src: src, start: 10, stop: 20)
    check char(s.byteAt(0)) == 'A' # 10 mod 10 in "ABCDEFGHIJ" repeating
    expect(IndexDefect):
      discard s.byteAt(10)
    expect(IndexDefect):
      discard s.byteAt(-1)

suite "span: reads":
  test "every offset lands where it should":
    let src = alphabetSource()
    for i in [0, 1, 7, 63, 512, 999]:
      let s = Span(src: src, start: i, stop: src.size)
      check s.byteAt(0) == src.byteAt(i)

  test "toString copies exactly the window":
    let src = newStringSource("0123456789")
    check Span(src: src, start: 3, stop: 7).clone == "3456"
    check Span(src: src, start: 9, stop: 9).clone == ""

  test "matchesAt compares without allocating":
    let src = newStringSource("8BIMLMsk001")
    let s = Span(src: src, start: 0, stop: src.size)
    check s.matchesAt(0, "8BIM")
    check s.matchesAt(4, "LMsk")
    check not s.matchesAt(0, "8B64")
    check not s.matchesAt(0, "8BIX")
    check not s.matchesAt(0, "9BIM")
    check not s.matchesAt(8, "1")
    check not s.matchesAt(-1, "8BIM")
    check not s.matchesAt(8, "longer than what is left")

  test "two spans over the same bytes compare equal":
    let src = newStringSource("payload")
    let a = Span(src: src, start: 0, stop: 7)
    let b = Span(src: src, start: 0, stop: 7)
    let c = Span(src: src, start: 1, stop: 7)
    check a == b
    check a != c
    check a != Span(src: src, start: 0, stop: 0)

  test "empty spans of any width are equal":
    let src = alphabetSource()
    check Span(src: src, start: 3, stop: 3) ==
      Span(src: src, start: 900, stop: 900)

  test "spans over different buffers compare by content":
    check Span(src: newStringSource("same"), start: 0, stop: 4) ==
      Span(src: newStringSource("same"), start: 0, stop: 4)

suite "span: zero-copy":
  test "a span's bytes live at the requested offset inside its source":
    let text = "0123456789".repeat(100)
    let src = newStringSource(text)
    let s = Span(src: src, start: 37, stop: 512)
    let lo = cast[int](src.base)
    let p = cast[int](s.base)
    check p - lo == 37
    check p + s.len <= lo + src.size

  test "holding many spans costs far less than copying their bytes":
    let src = alphabetSource()
    let before = getOccupiedMem()
    var keep: array[4096, Span]
    for i in 0 ..< 4096:
      keep[i] = Span(src: src, start: i mod 900, stop: i mod 900 + 8)
    let after = getOccupiedMem()
    # 4096 spans x 24 bytes is ~96 KB if the array is heap-allocated; what
    # matters is that nothing here approaches the 1000-byte source per span.
    check after - before < 1024 * 1024
    check keep[100].clone.len == 8

suite "mmap: mapped sources":
  test "a mapped source reports its size and is not a string":
    let path = tmpPath("basic.bin")
    writeFile(path, "8BIMmapped payload")
    defer: removeFile(path)

    let src = mapSource(path)
    check src.isMapped
    check src.kind == skMapped
    check src.size == "8BIMmapped payload".len
    check char(src.byteAt(0)) == '8'
    check char(src.byteAt(4)) == 'm'

  test "a mapped source reads identically to a string source":
    let path = tmpPath("cmp.bin")
    var payload = newStringOfCap(4096)
    for i in 0 ..< 4096:
      payload.add(char(i and 0xFF))
    writeFile(path, payload)
    defer: removeFile(path)

    let fromMap = mapSource(path)
    let fromString = newStringSource(readFile(path))
    check fromMap.size == fromString.size
    check fromMap.equals(payload)
    check fromString.equals(payload)
    check fromMap.kind != fromString.kind

    let a = Span(src: fromMap, start: 100, stop: 200).clone
    let b = Span(src: fromString, start: 100, stop: 200).clone
    check a == b
    check a.len == 100

  test "a mapped span's bytes come from the mapping, not a heap copy":
    let path = tmpPath("nopcopy.bin")
    writeFile(path, newString(8192).replace('\0', 'z'))
    defer: removeFile(path)

    let src = mapSource(path)
    let s = Span(src: src, start: 4096, stop: 5120)
    check cast[int](s.base) - cast[int](src.base) == 4096

  test "an empty file maps to an empty source instead of failing":
    let path = tmpPath("empty.bin")
    writeFile(path, "")
    defer: removeFile(path)
    let src = mapSource(path)
    check src.size == 0

  test "a span outlives its source variable because it holds the refcount":
    let path = tmpPath("lifetime.bin")
    writeFile(path, "lifetime")
    defer: removeFile(path)

    var s: Span
    block:
      s = Span(src: mapSource(path), start: 0, stop: 8)
    # the Source was created inside the block and had no other reference; the
    # Span keeps it alive, so the mapping is still there and still readable.
    check s.clone == "lifetime"

  test "mapFileOrRead serves a real file, mapped when possible":
    let path = tmpPath("orread.bin")
    writeFile(path, "fallback path")
    defer: removeFile(path)
    let src = mapSourceOrRead(path)
    check src.size == "fallback path".len
    check src.equals("fallback path")

  test "mapping a missing file raises":
    let path = tmpPath("missing.bin")
    removeFile(path)
    expect(OSError, IOError):
      discard mapSource(path)

  test "mapFileSize reports a file's size without reading it":
    let path = tmpPath("size.bin")
    writeFile(path, "1234567890")
    defer: removeFile(path)
    check mapSourceSize(path) == 10