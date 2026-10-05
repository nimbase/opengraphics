# PSD compositor fidelity audit

Date: 2026-10-05. Suites: 47, all passing. Reproduced by
`timeout 1500 clue test`.

## Why this audit exists

The only fidelity figure in this repository was a line in `psd-rewrite.md`:
`01.psd` renders 97.86% of pixels matching the stored composite, "the 2% is text
layer effects". Nothing in the test suite measured it, so nothing protected it.
Both halves turned out to be wrong, and the audit below replaces the claim with a
measurement.

## What the renderer actually does

`render.nim` never reads the stored flattened composite. It walks the layer tree
and blends stored layer pixels. Two consequences run through this whole document:

1. Photoshop has already rasterised each layer's fill, stroke and text into that
   layer's pixel data. Interpreting a layer's fill descriptor therefore has
   **no effect on rendered output**. Fill support is an editing and
   reconstruction API, not a fidelity concern.
2. The stored composite is the closest thing to an independent oracle available,
   so it is the right thing to compare against -- with the caveats in the next
   section.

## Measurement

Per pixel over the full canvas, comparing `renderDocument(doc)` against
`doc.compositeImage()`. "Worst delta" is the largest single-channel difference
anywhere in the image, including alpha.

| fixture | size | exact match | worst delta | pixels off by > 8 | all inside a `TySh` rect |
| --- | --- | --- | --- | --- | --- |
| `01.psd` | 700x700 | 97.86% | 31 | 9,422 | yes |
| `02.psd` | 600x600 | 59.79% | 40 | 4,107 | yes |
| `03.psd` | 700x700 | 60.36% | 2 | 0 | vacuously |

Every pixel differing by more than 8 lies inside a text layer's rect, in all three
fixtures. None lies anywhere else.

### The percentages are misleading and the deltas are not

`03.psd` is within 2 levels of Photoshop **everywhere in the image** while
matching exactly on only 60% of pixels. The reason is that a single type layer
covers most of its canvas. A percentage floor of 60% would look alarming and
would catch nothing; a worst-delta bound of 8 is both tight and meaningful.

This is the single most important conclusion of the audit: **report the
distribution and the location of the error, not a single ratio.**

### What causes the type-layer difference

Not layer effects. `01.psd` contains no `lfx`, `lrFX`, `lfx2` or `lfxs` bytes
anywhere, so there is no effect layer present to explain anything.

The decisive experiment: at a differing pixel, take the type layer's own stored
pixels and the pixel beneath it, blend them with plain 8-bit straight-alpha
"source over", and compare three things.

```
(94,328)  text=(254,254,254,a=96)   base=(23,25,33)
  hand-computed blend  (110,111,116)
  our render            (109,111,116)    <- matches, within rounding
  Photoshop's composite (140,141,143)
```

The hand-computed blend reproduces our renderer to within a rounding level. So the
compositor's arithmetic is correct, and Photoshop's stored value is *lighter*
than any blend of the pixels Photoshop itself stored.

Fitting an exponent to the discrepancy gives values around 1.65, and no single
exponent fits every case:

| exponent | predicts at a=96 | predicts at a=128 | Photoshop |
| --- | --- | --- | --- |
| 1.0 (naive) | 110.0 | 139.0 | 140 / 167 |
| 1.6 | 137.8 | 164.7 | |
| 2.2 (sRGB) | 159.5 | 183.0 | |

The result is *lighter* than naive and *darker* than linear-light, consistently.
The honest conclusion is that Photoshop's composite for a type layer is not a
function of that layer's stored pixels. It cannot be used as a pixel-exact oracle
for text, and closing the gap would mean reverse-engineering Photoshop's text
rasteriser rather than fixing anything in this codebase. Recorded as a known
difference.

## Validating the guard

A green fidelity test proves nothing until it has been seen to go red. Two
mutations were applied to `render.nim` and reverted:

| mutation | result |
| --- | --- |
| every layer composited at half opacity | **caught**: 426,301 offending pixels, first at (0,0) |
| vector mask application disabled entirely | **not caught**: all three fixtures render identically |

The first confirms the attribution assertion has teeth.

The second is a real gap in test coverage and is the more useful finding.
`01.psd`'s only vector mask covers essentially its entire layer rect, so ignoring
it changes no pixel. **The committed fixtures cannot detect a broken vector mask
at all.** Combined with the earlier finding that no committed fixture contains a
group, a layer mask or an undefined flag bit, the conclusion is that the
generated fixture in `testresults/` is not redundant -- it is currently the only
source of coverage for several compositor behaviours.

## What the suite now asserts

`tests/t_psd_fidelity.nim`:

* Non-vacuity: composite present, sizes equal, render dimensions match the header,
  text layers present, and differences actually exist to attribute. A fidelity
  test comparing nothing would otherwise pass forever.
* **Attribution:** no pixel differs by more than 8 outside a `TySh` rect. This is
  the load-bearing assertion.
* **Structural bound:** worst delta <= 48 on `01.psd` and `02.psd`, <= 8 on
  `03.psd`. Measured maxima are 31, 40 and 2.
* Percentage floors (97.5 / 59.0 / 60.0) are recorded as informational, with an
  upper bound below 100 so the comparison cannot silently stop testing anything.
* Independent recomposition: a hand-written straight-alpha blend of a type layer
  and the layer below reproduces `renderDocument` to within a rounding level. This
  is the strongest available statement about our own arithmetic, because it does
  not depend on Photoshop's composite at all.

## Fixture coverage gaps found

| gap | consequence |
| --- | --- |
| no fixture has a layer mask, group or undefined flag bit | covered only by the generated fixture |
| vector masks cover ~100% of their layer rect | vector mask regressions undetectable |
| no fixture has `lfx` / `lrFX` / `lfx2` | layer effects completely untested and uninterpreted |
| no fixture has `curv` / `levl` / `hue2` / `blnc` / `expA` | adjustment layers untestable |
| every fixture writes a **zero-length** `Patt` | pattern data never validated against anything Photoshop wrote |
| only `01.psd` has a shape layer | all fill and stroke expectations rest on one file |

The zero-length `Patt` deserves a note, and so does a claim this audit initially
got wrong. It is correct Photoshop behaviour, not a parsing bug: a document with
no patterns still emits the block, with a length of zero. Verified by reading the
raw bytes at the block offset.

The audit first wrote that `patterns.nim` and its writer were "untested". That was
overstated. `t_psd_core_patterns.nim` round-trips patterns at 8, 16 and 32 bits,
with and without an alpha plane, checks 4-byte alignment, byte stability, `.pat`
files and malformed input. What those tests cannot do is catch a misunderstanding
of the format: the writer and the reader share one model, so they agree with each
other even when both are wrong. They prove self-consistency, not correctness.

So the accurate statement is narrower and more interesting: pattern data has never
been validated against bytes Photoshop actually wrote. A cross-check against the
reference implementation would establish that two independent readings of the spec
agree, which is real evidence but still consensus rather than ground truth.

## Reference implementation

`photocraft/crates/psd` has no compositor at all -- it explicitly leaves
compositing to the caller -- so it could not inform any part of this audit. Its
value here was different and is now permanent: descriptor grammar is one of the
few places with two genuinely independent implementations, and `tests/t_psd_xref.nim`
cross-checks them against real Photoshop descriptors. It currently proves us
ahead on one point: `vogk` is `u32 1` followed by an ordinary version-16
descriptor, and the reference rejects it.

## Follow-ups

1. ~~Cross-check `patterns.nim` against the reference, and teach the generator to
   write a populated `Patt`.~~ Done. 84 pattern blocks agree byte-for-byte
   through the reference across three depths, seven colour modes and the
   alpha/palette variants; the generator now emits three real tiles; and
   `t_psd_patternfile` covers the block through the file writer, which is where
   the depth-key selection and 4-byte padding actually live. What none of it can
   supply is ground truth: no pattern data has been compared against bytes
   Photoshop wrote, because no available file has a populated `Patt`.
2. Teach the generator masks whose coverage is well below 100%, so vector mask
   regressions become detectable rather than only present in generated files.
3. Adjustment layers and layer effects need fixtures before they can be tested at
   all, in that order.

## A note on how the cross-check harness is kept honest

The first version of the reference harness lived in a system temp directory, and
it was cleaned up underneath us. Both descriptor cross-checks then skipped, the
suite still reported success, and nothing said so. A guard that stops guarding
without complaint is worse than no guard, so the harness now lives at
`testresults/psd-oracle/` -- gitignored, next to the other generated artifacts --
and a missing harness prints a build command instead of skipping quietly. Nim's
`skip()` takes no message, which is what made the silence possible in the first
place.