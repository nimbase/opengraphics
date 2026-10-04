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
`std/memfiles` mapping that `Source` owns and unmaps on finalisation. Opening
`02.psd` (47.5 MB) costs kilobytes of peak RSS rather than two copies of the
file.

`openPsd` maps; `openPsdRead` reads into the heap, for when concurrent truncation
is a concern. A truncated mapping faults with SIGBUS, which no handler can catch,
so the fallback is not optional for anyone who lets other processes touch the
file.

## Deliberate limitations

Worth knowing before building on this, because each is a decision rather than an
oversight.

* **Blend math follows the W3C spec, not Photoshop.** They genuinely disagree.
  Photoshop's SoftLight is an approximation of the spec's, and Photoshop applies
  `1e-4` epsilons to the ColorDodge and ColorBurn extremes. The differential
  test pins the W3C definitions exhaustively, over all 65536 `(src, dst)` pairs
  for each of the 21 separable modes. Matching Photoshop instead would be a
  deliberate one-line change and would break those pins. On `02.psd`, the only
  fixture using SoftLight, the old approximation matched the stored composite
  marginally better; both figures are dominated by that file's 30 smart objects
  and 21 text layers, so neither is evidence either way.
* **Compositing is 8-bit.** Layers are downscaled through `planeToU8` before
  blending, so a 16-bit document loses precision at composite time even though
  its pixels decode exactly. No float or 16-bit compositor.
* **An isolated group costs a full-canvas buffer.** Pass-through is the default
  and composes directly into the backdrop, but a group with its own blend mode
  is rendered onto a canvas of its own before being composited. A file with many
  such groups pays for each in turn.
* **Thumbnail payloads pass through.** They are parsed and available but not
  decoded; a JPEG decoder is dependency-scale work.

## Still open

* `vogk` / `vstk` origination and stroke descriptors, adjustment layers, effect
  layers (`lfx2` is parsed structurally but not interpreted).
* Vector-mask rasterisation in the renderer, and knockout plus blending
  ranges, which need group semantics the tree does not carry yet.
* Embedded smart-object files (`SoLd` metadata is read; the linked asset is
  not).
* Read support for `.eps`.

## Suggested order

Write support is done, so the remaining work is breadth of interpretation
rather than surface area: vector masks and knockout in the compositor first,
since they change the compositing model, then the semantic blocks above, then
`.eps`.