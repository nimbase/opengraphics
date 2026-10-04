## A `Source` is one immutable buffer of bytes, and a `Span` is a window into
## it. Together they are what make parsing zero-copy.
##
## The reason this exists rather than passing `string` around is that Nim string
## slicing copies. `substr` is `newStringUninit` plus `copyMem` (nim 2.2.12
## system.nim:2948), with no identity fast path, so `s[a ..< b]` allocates
## `b - a` bytes every time. A `Span` is instead a pair of offsets, 24 bytes,
## and creating one allocates nothing.
##
## A buffer is either a string or a memory-mapped file. Mapping is what makes
## opening a huge PSD cheap: the pages are demand loaded by the OS and never
## occupy the heap, so a 500 MB PSD opens with a few kilobytes of parse tree
## instead of a 500 MB buffer plus 500 MB of copies.
##
## `memfiles.MemFile` is a plain object, not refcounted, so nothing keeps a
## mapping alive on its own. That is why the mapping lives inside `Source`
## rather than being handed out by a factory: `Source` is a `ref`, and its
## finaliser unmaps. Every `Span` holds a reference to its `Source`, so a window
## cannot outlive the bytes it points at.

import std/os
import std/memfiles

type
  SourceKind* = enum
    skString   ## heap memory, usually the caller's own buffer
    skMapped   ## pages of a memory-mapped file, nothing on the heap

  MappingStorage = object
    ## Owns one mapping. Split out and refcounted separately so that
    ## `SourceStorage` itself needs no destructor: an object with a
    ## user-defined `=destroy` cannot have its variant discriminant assigned,
    ## and more importantly the object-constructor path that then becomes
    ## necessary *deep-copies* the string it is given, which would defeat the
    ## whole point of a shared source.
    mf: MemFile

  Mapping* = ref MappingStorage

  SourceStorage* = object
    ## The buffer itself.
    case kind*: SourceKind
    of skString:
      buf*: string
    of skMapped:
      mapping*: Mapping ## unmapped when the last reference goes

  Source* = ref SourceStorage
    ## One immutable buffer. Holds a reference rather than a copy of a string,
    ## so wrapping the caller's own buffer costs one atomic refcount bump and
    ## no bytes.
    ##
    ## Since a `Source` is immutable once built, a parsed file can be shared
    ## across threads for reads.

  Span* = object
    ## A half-open window `[start, stop)` into a `Source`. 24 bytes, and
    ## copying one is a refcount bump plus two integer copies.
    src*: Source
    start*: int
    stop*: int

proc `=destroy`(m: var MappingStorage) =
  ## Unmap when the last reference goes. A file truncated by another process
  ## while mapped makes `munmap` unhappy, which is not worth propagating: the
  ## mapping is being discarded either way.
  if m.mf.mem != nil and m.mf.size > 0:
    try:
      m.mf.close()
    except IOError, OSError:
      discard

# --- construction ------------------------------------------------------------

proc newStringSource*(data: string): Source =
  ## Wrap `data` without copying it: the caller's buffer is shared, so mutating
  ## it afterwards would change what every `Span` sees; treat it as frozen.
  ##
  ## Field assignment rather than `Source(kind: ..., buf: data)` on purpose.
  ## The object-constructor form builds a temporary `SourceStorage` and copies
  ## it into the new reference, and with a nested-mapping source that copy is
  ## deep, so `readPsd` ended up allocating a whole extra copy of the file.
  new(result)
  result.kind = skString
  result.buf = data

proc emptySpan*(): Span {.inline.} =
  ## An empty window into an empty source. For the many fields that mean "no
  ## payload at all": a divider's channels, a record's trailing bytes, a
  ## document with no colour mode data.
  Span(src: newStringSource(""), start: 0, stop: 0)

proc newBytesSource*(data: openArray[byte]): Source =
  ## One copy at the `seq[byte]` boundary; spans over it stay copy-free.
  if data.len == 0:
    return newStringSource("")
  var s = newString(data.len)
  copyMem(addr s[0], unsafeAddr data[0], data.len)
  newStringSource(s)

proc newMapping(mf: MemFile): Mapping =
  new(result)
  result.mf = mf

proc mapSource*(path: string): Source =
  ## Map `path` read-only, for the whole file, into a source that owns it.
  ##
  ## Raises `OSError` if the file cannot be mapped. A zero-length file becomes
  ## an empty source rather than an error, since `mmap` rejects a zero length
  ## and "no bytes" is a legitimate PSD payload to report.
  if int(getFileSize(path)) == 0:
    return newStringSource("")
  let mf = memfiles.open(path, mode = fmRead, mappedSize = -1)
  # Built through the object constructor rather than field assignment: a fresh
  # `ref` is zero-initialised, so `kind` would already be `skString` and
  # assigning `skMapped` is a discriminant *change*, which nim 2.2 rejects.
  # No copy results here: the only field is a `ref`.
  Source(kind: skMapped, mapping: newMapping(mf))

proc mapSourceOrRead*(path: string): Source =
  ## Map `path`, falling back to reading it into memory.
  ##
  ## The fallback earns its keep twice. A file that cannot be mapped at all
  ## should still open. And reading is the safe choice against a file being
  ## truncated while mapped, where touching a page past the new end raises
  ## SIGBUS rather than an exception we could catch.
  try:
    return mapSource(path)
  except IOError, OSError:
    return newStringSource(readFile(path))

proc mapSourceSize*(path: string): int =
  ## Size of `path` without reading or mapping it.
  int(getFileSize(path))

proc offsetPtr(p: pointer, n: int): pointer {.inline.} =
  ## Pointer arithmetic, which Nim spells as an integer offset. Nil-tolerant so
  ## an empty span yields nil rather than an address just past the buffer.
  if p == nil:
    return nil
  cast[pointer](cast[uint](p) + uint(n))

proc toSpan*(s: string): Span {.inline.} =
  ## A window over bytes we already hold, for handing synthesised payloads to
  ## the parsers. Parsed file data keeps its own window into the file.
  Span(src: newStringSource(s), start: 0, stop: s.len)

# --- Source ------------------------------------------------------------------

proc size*(s: Source): int {.inline.} =
  ## Bytes in the buffer. Raises on nil, which is a bug rather than something a
  ## malformed file can cause.
  if s.isNil:
    raise newException(ValueError, "nil Source")
  case s.kind
  of skString: s.buf.len
  of skMapped: s.mapping.mf.size

proc base*(s: Source): pointer {.inline.} =
  ## The first byte of the buffer, for handing to C code. Nil when empty.
  if s.isNil:
    return nil
  case s.kind
  of skString:
    if s.buf.len == 0: nil else: cast[pointer](unsafeAddr s.buf[0])
  of skMapped:
    if s.mapping.mf.size <= 0: nil else: s.mapping.mf.mem

proc isMapped*(s: Source): bool {.inline.} =
  not s.isNil and s.kind == skMapped

proc byteAt*(s: Source, i: int): uint8 {.inline.} =
  ## One byte, bounds-checked. This is the hot path of structure parsing, so it
  ## goes through `unsafeAddr` on the string side to avoid a second check.
  if s.isNil:
    raise newException(ValueError, "nil Source")
  if i < 0 or i >= s.size:
    raise newException(IndexDefect, "Source byte " & $i &
      " out of range 0.." & $(s.size - 1))
  case s.kind
  of skString: uint8(ord(s.buf[i]))
  of skMapped: cast[ptr UncheckedArray[uint8]](s.mapping.mf.mem)[i]

proc equals*(s: Source, other: string): bool {.inline.} =
  ## Byte-for-byte comparison of the whole buffer, for equivalence tests.
  if s.isNil or s.size != other.len:
    return false
  if s.size == 0:
    return true
  equalMem(s.base, unsafeAddr other[0], s.size)

# --- Span --------------------------------------------------------------------

proc len*(s: Span): int {.inline.} = s.stop - s.start

proc isEmpty*(s: Span): bool {.inline.} = s.stop <= s.start

proc source*(s: Span): Source {.inline.} = s.src

proc base*(s: Span): pointer {.inline.} =
  ## Pointer to the first byte of the span, for zero-copy reads. Nil when empty.
  if s.src.isNil or s.len == 0:
    return nil
  offsetPtr(s.src.base, s.start)

proc byteAt*(s: Span, i: int): uint8 {.inline.} =
  ## One byte at `start + i`, bounds-checked against the span, not the buffer.
  if i < 0 or i >= s.len:
    raise newException(IndexDefect, "Span byte " & $i &
      " out of range 0.." & $(s.len - 1))
  s.src.byteAt(s.start + i)

proc slice*(s: Span, first, last: int): Span =
  ## A span over `[first, last)` relative to this one.
  ##
  ## Checked once here rather than on every read, against both this span and
  ## the source. A `Span` describing bytes past the end of the buffer would turn
  ## `byteAt` into a wild pointer read, so that window is closed at
  ## construction. The parent check keeps a sub-view from quietly reaching
  ## outside the region it was carved from.
  if first < 0 or last < first or last > s.len:
    raise newException(IndexDefect, "Span slice [" & $first & ", " & $last &
      ") is not within the " & $s.len & "-byte span")
  if s.src.isNil or s.start + last > s.src.size:
    raise newException(IndexDefect, "Span slice [" & $first & ", " & $last &
      ") leaves the source")
  Span(src: s.src, start: s.start + first, stop: s.start + last)

proc head*(s: Span, n: int): Span {.inline.} =
  ## The first `n` bytes of this span.
  slice(s, 0, n)

proc tailFrom*(s: Span, at: int): Span {.inline.} =
  ## Everything from `at` to the end of this span.
  slice(s, at, s.len)

proc clone*(s: Span): string =
  ## An owning copy. Only for the places that genuinely need one: the compat
  ## layer's string accessors, and handing bytes to a C API.
  ##
  ## Named `clone` because neither obvious alternative works in method syntax:
  ## `toString` is a magic function, and `system.copy` is a template, so
  ## `span.copy` would not resolve.
  let n = s.len
  if n == 0:
    return ""
  result = newString(n)
  copyMem(addr result[0], s.base, n)

proc bytePtr*(s: Span, i: int): pointer {.inline.} =
  ## Pointer to byte `i`, for handing a run of bytes to `copyMem`. Not checked:
  ## the caller is mid-decode with the layout already validated.
  offsetPtr(s.base, i)

proc matchesAt*(s: Span, off: int, lit: string): bool {.inline.} =
  ## Compare `lit` against the bytes at `off` without copying either side.
  if off < 0 or lit.len > s.len - off:
    return false
  let p = cast[ptr UncheckedArray[char]](offsetPtr(s.base, off))
  for i in 0 ..< lit.len:
    if p[i] != lit[i]:
      return false
  true

proc `==`*(a, b: Span): bool {.inline.} =
  ## Same bytes, regardless of which buffer they came from.
  if a.len != b.len:
    return false
  if a.len == 0:
    return true
  equalMem(a.base, b.base, a.len)

proc `==`*(s: Span, lit: string): bool {.inline.} =
  ## Compare a window against a literal, so a block's payload can be asserted
  ## against expected bytes without copying the window out first.
  if s.len != lit.len:
    return false
  if lit.len == 0:
    return true
  equalMem(s.base, unsafeAddr lit[0], lit.len)

proc `==`*(lit: string, s: Span): bool {.inline.} = s == lit