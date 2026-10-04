# PSD zero-copy and memory-mapped opening

Created: 2026-10-04 12:30 EEST
Status: done
Predecessor: `psd-rewrite.md` phases 0-7 (done)
Follows: `psd-rewrite.md` phase 8, compositing refinement

## Problem

Opening a PSD currently costs roughly twice the file size in resident memory,
plus a pile of transient garbage. Every payload is deep-copied out of the input
string at parse time.

### The premise that was wrong

Nim string slicing **copies**. It is not a zero-copy view:

```nim
# nim-2.2.12/lib/system.nim:2948
proc substr*(s: string; first, last: int): string =
  result = newStringUninit(L)
  copyMem(result[0].addr, s[first].unsafeAddr, L)
```

A fresh allocation plus `copyMem` every time, with no identity fast path, even
for `big[0 .. ^1]`. It cannot be otherwise: Nim's refcount lives at the head of
the allocation, so a slice pointing into the middle cannot keep the buffer
alive. (Nim 2.2 documents a `view` type at system.nim:3010, but it is not
implemented in this toolchain -- only `toOpenArray`, which returns a
non-storable `openArray`.)

Consequence: only two things are zero-copy today, `Reader.root` sharing and
`Reader.sub` (io.nim:82). `Reader.bytes` (io.nim:68) and `Reader.peekRest`
(io.nim:57) both deep-copy, and every payload field is populated through one of
them.

For the `tests/data/02.psd` of the time (45.3 MB) that is the 45.3 MB root string plus a full
copy of the merged composite (file.nim:204) plus a copy of every channel, tagged
block and resource.

## Design

`Span` holds a **`ref object`**, not a `string`. That one choice lets the
zero-copy work and the mmap work share a single code path.

```nim
# psd/span.nim
SourceKind* = enum skString, skMapped
Source* = ref object        # refcounted: keeps the mapping alive
  case kind: SourceKind
  of skString: buf: string # shares the caller's buffer, no copy
  of skMapped:  mf: MemFile

Span* = object              # 8 (ref) + 16 (two ints) = 24 bytes
  src: Source
  start: int
  stop: int
```

Every `Span` references its `Source`, so spans keep the buffer or the mapping
alive by themselves. A 45 MB file with 2000 spans becomes 2000 x 24 bytes plus
one buffer, instead of 2000 deep copies. Assignment is one atomic refcount bump.

`Source` is immutable after parse, so a parsed `PsdFile` is safe to share across
threads for reads.

### std/memfiles

Available at `lib/pure/memfiles.nim`. Provides `MemFile{mem, size}`,
`open(filename, mode, mappedSize, offset)`, `MemSlice`, and
`newMemMapFileStream`.

Two constraints:

1. **`MemFile` is a plain object, not refcounted.** Nothing keeps a mapping
   alive, so `Source` owns it and unmaps in `=destroy`.
2. **A mapping cannot be turned into a Nim string for free.** `newString` +
   `copyMem` is a copy again, and a string aliasing mapped memory would be
   freed by the GC. This is why `Source` exists rather than reusing `string`.

`psd/mmap.nim` wraps `std/memfiles` so the dependency is isolated and testable.

## Phase A -- wasteful paths, no type changes

Independent of the type work, done first, keeps the suite green.

1. `readBlocks` re-copies the remaining region per block iteration
   (tagged.nim:273, `r.peekRest()[0 ..< 4]` just to test four bytes).
   Superlinear in block count. Replace with a direct probe off `root`.
2. Open-time full inflate that is discarded (file.nim:209 ->
   compression.nim:485). Validate RLE by row counts (O(rows)); defer ZIP
   inflate to decode time.
3. `document.nim:198-201`: `cc` zero-filled planes that line 201 overwrites
   immediately. Delete.
4. `document.nim:240-242`: `copyMem` in the `seq[byte]` overload, matching
   io.nim:37.
5. `render.nim`: mask plane fetched per pixel (render.nim:152, called at
   :236) -- a full channel inflate per pixel. Hoist to once per layer.
6. `packbitsDecode` allocates `newString(expected)` per row
   (compression.nim:125); `predict`/`unpredict` allocate `scratch` per row
   (compression.nim:232, :277). Write straight into the destination row and
   hoist scratch out of the row loop.
7. Writer: `newSeqOfCap` plus a `copyMem` in `put`, replacing the per-byte
   `seq.add` on an unreserved buffer (io.nim:250, :254-258).

## Phase B -- offset views through the parser

`Reader.bytes` and `peekRest` return `Span`. Bulk payload fields become `Span`:

| Field | Site |
|---|---|
| `PsdFile.imageData.data` (the 45 MB composite) | file.nim:57 |
| `ChannelData.data` (every channel) | layers.nim:103 |
| `TaggedBlock.data` | tagged.nim:70 |
| `ImageResource.data` | resources.nim:26 |
| `MetadataItem.data` | metadata.nim:41 |
| `GlobalLayerMask.data` | file.nim:53 |
| `BlendingRanges.data` | layers.nim:76 |
| `MaskData.raw` | layers.nim:71 |
| `PsdFile.colorModeData` | file.nim:61 |
| descriptor raw values | descriptor.nim:109-111 |

Small fields stay `string`: signatures, 4-byte keys, Pascal names, <=3 byte
padding, the 37-byte uuid. Not worth the churn.

30 call sites in total, 12 of them bulk. Converted leaf-up (tagged -> resources
-> layers -> file), running the suite at each step.

`compression.nim` takes `Span` and hoists `cptr` once, reading through raw
pointers in inner loops, so RLE and inflate stop copying too. Decoded planes
still return `string`: they genuinely are new data.

## Phase C -- memory mapping

- `openPsdSource(path)` returns a `Source` over `memfiles.open`.
- `readPsd` gains a `Source` overload; `readPsd(data: string)` wraps without
  copying.
- `document.nim`'s `openPsd(path)` switches to the mapped source.

### Risks

- **SIGBUS.** mmap gives no protection against the file being truncated by
  another process while mapped; touching a truncated page is a signal, not an
  exception. `readFile` stays available as the fallback.
- Choose the `openPsd` default: mapped (fast, low RSS) or slurped (safe against
  concurrent truncation).

## Buffer policy: no pool

Checked every candidate. Five of seven hot spots that look like they want a
pool are structural bugs, not pool problems. Decision: **caller-provided
scratch**, passed as `scratch: var string` into the decode routines. Same
allocation reduction as pooling, with no shared mutable state, no thread-safety
story, no lifetime bugs.

| Site | Pool? | Verdict |
|---|---|---|
| `packbitsDecode` per-row alloc | no | decode into destination row |
| `predict`/`unpredict` per-row scratch | no | hoist above the row loop |
| `Writer.buf` per-byte add | no | capacity planning + `copyMem` |
| `sec.toString()` tripling the layer section (file.nim:266) | no | length placeholder + patch |
| decoded planes handed to callers | maybe | only with an explicit give-back API |
| tiny parse allocs (unicode units, ids) | no | GC already handles these |
| open mmap handles across many files | yes | small LRU, only if batch opening is a real workload |

## Compat layer

`document.nim` keeps string-returning accessors via `Span.toString()`, so
existing callers and most tests are untouched. Core types may break; compat
names do not.

## Outcome

All three phases are done. `tests/t_psd_zero_copy.nim` (34 tests) is the
evidence, and `tests/t_psd_core_span.nim` covers the primitives.

`02.psd` as it was when this was measured (47.5 MB, 75 layers, 301 channels, 827 layer blocks, 26.5 MB of
global blocks) now parses into a tree of 24-byte windows. Opening it through a
mapping raises peak RSS by kilobytes rather than the file's size.

### How this is verified

- **Pointer identity**: every window's address equals `source.base + start`.
  A deep copy would land elsewhere, so this fails the moment one reappears.
- **Accounting**: the tree's windows cover 98-100% of the file's bytes. Identity
  plus accounting is a complete proof: if nothing was copied, nothing can be
  holding a duplicate.
- **Peak RSS** via `getrusage`, after a warm-up parse so reused arena pages
  cannot mask a fresh 45 MB allocation. Three trees held at once must not cost
  three file-sizes.
- **Equivalence**: the same file parsed from a string and from a mapping gives
  identical trees, and both round-trip byte for byte.
- **Lifetime**: a span read after its `PsdFile` is unreferenced still works,
  proving the refcount holds the mapping.

### `getOccupiedMem()` is not usable for this

It was the obvious instrument and it is wrong. Measured on nim 2.2.12: aliasing
a 1 MiB string costs 1,081,360 "bytes" of occupancy, and each further reference
costs the string's full size again, while aliasing a 5-byte string costs 16
bytes. It cannot tell a copy from a reference. Peak RSS replaced it.

### Three real bugs found on the way

1. **Absolute versus relative offsets.** `Reader.pos` is absolute but `Span`
   indices are relative to the span, so `decodePlanes` started decoding RLE
   rows at the wrong place ("PackBits row ended early"), and
   `parsePrefixDescriptor` reported an absolute `consumed`, which made the
   slices trailing-descriptor parse fail *silently* and lose every outset.
   Both now use `Reader.offset`.

2. **A whole extra copy of the file.** `SourceStorage` needed a user-defined
   `=destroy` to unmap, which forced the object-constructor path for
   `newStringSource`, and that path deep-copies the string it is handed. The
   mapping now lives in a nested refcounted `Mapping`, so `SourceStorage` needs
   no destructor and the source can be built by plain field assignment.

3. **Double-consumed padding.** `readBlocks` read the pad bytes with `r.bytes`
   and then skipped them again.

### Buffer policy held

No pool. The five sites that looked like pool candidates were structural bugs:
an RLE temporary allocated per row, prediction scratch allocated per row, a
writer that appended byte-at-a-time into an unreserved buffer, a layer section
tripled by nested writers, and a mask channel inflated once per pixel in
`render.nim`.

## Sequencing

Phase A -> `Source`/`Span`/`mmap` with own tests -> payload fields leaf-up ->
descriptor raw values -> compat shims and test updates -> mmap entry points ->
memory and identity tests -> full suite -> plan doc update.

Next after this: `psd-rewrite.md` phase 8, compositing refinement (f32
non-separable HSL modes, dissolve, PassThrough, differential test).