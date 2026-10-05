# PSD roadmap

Status: read and write both done and tested. 39 suites, three real fixtures
pinned byte for byte, plus a synthetic corpus covering every colour mode and bit
depth the format allows.

Constraints honoured: PSD and PSB, 1/8/16/32-bit reading, all eight colour modes,
Raw + RLE + ZIP + ZIP-prediction.

## Done

* **Header and sections.** Both container formats, colour mode data passthrough
  (the 768-byte Indexed palette included), generic `8BIM` resource blocks, the
  layer and mask section in either place, and `Lr16` / `Lr32` / `Layr` lifted out
  of the global blocks when that is where a document keeps its layer info.
* **Layer records.** `luni`, `lyid`, `lsct` / `lsdk`, group tree builder,
  `flattenTree`. `lsct` wins over `lsdk`, matching Photoshop.
* **Pixels.** Raw, RLE (PackBits with a measured row count table), ZIP and
  ZIP-prediction, at 1 / 8 / 16 / 32 bits, across every colour mode. Bitmap's
  one-bit row packing and the 32-bit predictor's byte-plane shuffle are both
  covered.
* **Masks.** 20- and 36-byte records, mask parameters, the user-mask channel
  (id -2) and real mask (id -3) decoded at their own rects, global mask with its
  typed accessors. Unparseable mask data is kept as raw bytes rather than
  dropped.
* **Compositing** (`psd/render`). All 27 blend modes, including the six
  non-separable HSL modes plus DarkerColor and LighterColor, per-pixel
  Dissolve, group PassThrough against isolated blending, opacity, clipping,
  alpha and mask application. `01.psd` renders 97.86% of pixels identical to its
  stored composite; the remainder is text layer effects.
* **Semantic blocks.** `TySh` text (engine data, fonts, sizes, transform),
  vector path records and `SoCo` solid fills, smart-object `SoLd` / `PlLd`
  metadata, slices, patterns, image resources including resolution, thumbnail
  and ICC.
* **Writing.** `writePsd` returns an unmodified file byte for byte. Two
  documented normalisations: Pascal-name pad bytes are written as zeros, and a
  layer-and-mask section holding only a zero layer-info length becomes an empty
  section.
* **Untrusted input.** Every length prefix is checked before allocation,
  channel-aware volume caps, block-count caps, and typed `PsdError` for every
  failure path. See `psd-rewrite.md` phase 9 for the specific bugs the sweeps
  caught.

## Zero-copy and memory-mapped opening

Done, see `psd-zero-copy-2026-10-04.md`. The parser holds `Span`s, 24-byte
windows into one `Source`, which is either a shared caller string or a
`std/memfiles` mapping that `Source` owns and unmaps on finalisation. Opening a
40 MB file costs kilobytes of peak RSS rather than two copies of it.

`openPsd` maps; `openPsdRead` reads into the heap, for when concurrent truncation
is a concern. A truncated mapping faults with SIGBUS, which no handler can catch,
so the fallback is not optional for anyone who lets other processes touch the
file.

The large-file evidence comes from a generated fixture, not a committed one.
`02.psd` was replaced by a 600x600 three-layer document, which is far too small
to show that opening costs kilobytes rather than a copy. `psd_testgen` now emits
a ~40 MB file into the gitignored `testresults/` directory instead, which also
carries the nested groups, masks and reserved flag bits that no committed
fixture has any more.

## Compositor, phase by phase

The reference implementation does not composite at all -- it explicitly leaves
that to the caller -- so the compositor is the one area with no upstream to
check against, and it was built in stages.

* **`iSO` group isolation.** Phase 8 decided pass-through versus isolated from a
  group's blend key alone, which is wrong: Photoshop writes an `iSO` block on a
  group whose mode is still `pass`. Two things followed. The renderer had to
  consult the block, and the *parser* had to learn that `iSO` is a three-byte
  key where every other tagged-block key has four -- reading four bytes ate the
  low byte of the length field, so any file containing one failed to parse. The
  reference shares that four-byte assumption and has the same blind spot.
* **Vector mask rasterisation.** `vmsk` / `vsms` store Bezier knots, and a
  layer with a vector mask used to render its whole rectangle. There is now a
  scanline rasteriser (`psd/raster`) producing the same shape of coverage plane
  as a raster mask channel, so both feed one code path and a layer carrying both
  intersects them. Coverage is exact horizontally and supersampled vertically:
  correct shape, approximate edge, and not a claim of matching Photoshop's own
  anti-aliasing sample for sample.
* **Blend If.** The blending-ranges records now drive per-pixel coverage. A layer
  whose ranges are the Photoshop default short-circuits, so the common case
  costs one comparison.
* **Knockout is parsed but not applied.** `knko` is typed and exposed. Its
  semantics are the least well documented of the four: the value selects which
  surrounding layers are knocked out of the group's backdrop, and the behaviour
  differs between Photoshop versions. A partial implementation that is subtly
  wrong would be worse than none, so it stays a known gap.

## Deliberate limitations

Worth knowing before building on this, because each is a decision rather than an
oversight.

* **Blend math follows the W3C spec, not Photoshop.** They genuinely disagree.
  Photoshop's SoftLight is an approximation of the spec's, and Photoshop applies
  `1e-4` epsilons to the ColorDodge and ColorBurn extremes. The differential
  test pins the W3C definitions exhaustively, over all 65536 `(src, dst)` pairs
  for each of the 21 separable modes. Matching Photoshop instead would be a
  deliberate one-line change and would break those pins.
  An earlier measurement suggesting the old approximation matched better was
  taken against the previous 47.5 MB `02.psd`, which had SmartLight layers and
  21 text layers. That file has been replaced and the measurement no longer
  describes anything present, so it has been struck rather than carried
  forward.
* **Compositing is 8-bit.** Layers are downscaled through `planeToU8` before
  blending, so a 16-bit document loses precision at composite time even though
  its pixels decode exactly. No float or 16-bit compositor.
* **An isolated group costs a full-canvas buffer.** Pass-through is the default
  and composes directly into the backdrop, but a group with its own blend mode
  is rendered onto a canvas of its own before being composited. A file with many
  such groups pays for each in turn.
* **Thumbnail payloads pass through.** They are parsed and available but not
  decoded; a JPEG decoder is dependency-scale work.

## Fixture coverage, and what it no longer proves

No committed fixture now contains a group, a layer mask, or an undefined
layer-flag bit. `01.psd` supplies a shape layer with a vector mask and a smart
object; `02.psd` and `03.psd` each supply a text layer. Those three properties
are exactly the ones a reader is most likely to get subtly wrong, so the
generated large fixture carries them and `t_psd_fixtures` pins them there.

## Still open

* Applying the fill and stroke descriptions when *editing* a layer -- changing
  a shape's colour, gradient or outline. `psd/fills` reads origination (`vogk`)
  and stroke (`vstk`) and answers questions about them. This is not a rendering
  gap: the compositor blends stored layer pixels, which Photoshop has already
  rasterised the fill into, so fills render correctly today and drawing them
  from descriptors would change nothing.
* Gradient (`GdFl`) and pattern (`PtFl`) fills, adjustment layers (`curv`,
  `levl`, `hue2`, `blnc`, `expA`), and effect layers (`lfx2` is preserved raw,
  not interpreted).
* Knockout, as above.
* Embedded smart-object files (`SoLd` and `PlLd` metadata are read; the linked
  asset is not).
* Read support for `.eps`.

### Traps in the shape-layer blocks

All three of these fail silently -- a wrong lookup returns nothing, the accessor
substitutes a zero, and the caller cannot tell that from a real value. Each is
covered by a test in `t_psd_fills`.

* `vogk` is not a bare versioned descriptor. It is `u32 1` followed by an
  ordinary version-16 descriptor, so the generic entry point reads the marker as
  a version and rejects the block. The reference implementation makes the same
  assumption and cannot read `vogk` at all; `t_psd_xref` pins that divergence in
  both directions.
* Inside `vogk` the descriptor is wrapped in a `keyDescriptorList` even when
  there is exactly one entry. Reading `vogk` as though it were the descriptor
  yields an empty descriptor and no error.
* The `unitRect` keys are `"Top "`, `Left`, `Btom` and `Rght`. Descriptor keys
  are a fixed four bytes, so `Top ` is space-padded; `Btom` and `Rght` are
  misspellings. Read any of them wrong and the bounding box is 0,0,0,0.

### Where the compositor actually differs from Photoshop

Measured per pixel by `t_psd_fidelity`. The headline is that it is exact
everywhere except type layers:

| fixture | exact match | worst delta | pixels off by > 8 | all inside a `TySh` rect |
| --- | --- | --- | --- | --- |
| `01.psd` | 97.86% | 31 | 9,422 | yes |
| `02.psd` | 59.79% | 40 | 4,107 | yes |
| `03.psd` | 60.36% | 2 | 0 | vacuously |

The percentages mislead and the deltas do not. `03.psd` differs from Photoshop by
at most 2 levels anywhere while matching exactly on only 60% of pixels, purely
because one type layer covers most of the canvas. The meaningful statement is the
last column: across all three fixtures **every** pixel differing by more than 8
lies inside a text layer's rect, and none lies anywhere else.

The cause is **not** layer effects, which an earlier version of this file
claimed. `01.psd` contains no `lfx`, `lrFX` or `lfx2` bytes at all. Recomputing
the type layer by hand with plain 8-bit straight-alpha "source over" reproduces
our render to within a rounding level, so our blend is right; Photoshop's stored
composite is simply *lighter* than any blend of the pixels it stored, consistent
with a gamma-aware composite, though no single exponent fits every case. In other
words Photoshop's type-layer composite is not a function of the stored layer
data, so it cannot serve as a pixel-exact oracle for text, and closing the gap
would mean guessing at Photoshop's text rasteriser rather than fixing anything
here. Left as a documented difference.

Two limits on that guard, both measured rather than assumed. Forcing every layer
to half opacity makes the attribution assertion report 426,301 offending pixels,
so it does catch real regressions. But the committed fixtures **cannot** detect a
broken vector mask at all, because `01.psd`'s only vector mask covers essentially
its whole layer rect: disabling mask application leaves all three rendering
identically. That is what the generated fixture is for.

### Pattern data: agreement reached, ground truth still missing

Every committed fixture writes a **zero-length** `Patt` block -- Photoshop emits
the block with a length of 0 when a document has no patterns, which is not a
parsing bug. The generated fixture now writes a **populated** one instead, with
three tiles at whichever depth the document uses.

What that leaves covered, and what it does not:

* `t_psd_core_patterns` round-trips the module against itself at 8/16/32 bits,
  with and without alpha, plus `.pat` files and malformed input. This cannot
  catch a misunderstanding of the format, because writer and reader share one
  model and so agree even when both are wrong.
* `t_psd_xref` cross-checks against the reference implementation, which is an
  independent reading of the same specification. 84 blocks -- three depths times
  seven colour modes, with and without alpha and with and without a palette --
  come back byte-identical through it, as does a multi-pattern block whose
  ordering matters because patterns resolve references by position. This is real
  evidence, but it is consensus between two implementations, not ground truth.
* `t_psd_patternfile` covers what neither of the others does: the block surviving
  the *file* path. `Patt` vs `Pat2` vs `Pat3` selection, the per-pattern length
  prefix, 4-byte padding, and global-block placement all live in `file.nim` and
  `tagged.nim` rather than in `patterns.nim`, and a file with patterns now
  round-trips byte for byte at every depth.

Still missing, and not fixable here: no pattern data has been validated against
bytes Photoshop actually wrote, because no available file has a populated `Patt`.
That would need a real document with patterns in it.

A dump of the tagged-block keys present in the committed fixtures is worth
keeping in mind when choosing: `01.psd` carries `vogk`, `vstk`, `vowv`,
`lvyr`, `lnk2` and `lnkE`. Of these only `vogk` and `vstk` are interpreted. That
file is the only fixture with a shape layer, so it is the natural fixture for
the fill work above -- and the only one, which is why the tests lean on it so
heavily.

## Suggested order

Write support is done, so the remaining work is breadth of interpretation
rather than surface area. Vector masks are done and knockout is a deliberate
gap, so the compositor no longer leads. The order is: render the fill and stroke
descriptions that `psd/fills` can now read, then adjustment layers, then
`.eps`. Pattern fills slot in wherever it is convenient, but only once the
generator can write a populated `Patt` to test against.