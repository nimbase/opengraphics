# PSD rewrite plan

## Goal

Replace `src/opengraphics/psd/` with an implementation modeled on the reference
crate at `references/photocraft/crates/psd`, whose primary guarantee is
**byte-exact round-trip** (`read(b).write == b` for unmodified files), while
preserving Nim's current strengths that the reference lacks: compositing, and
typed `TySh` / vector / smart-object parsing.

Reference: clean-room implementation from Adobe's public *Photoshop File
Formats Specification*, cross-checked against psd-tools / ag-psd. Where the spec
is silent the reference's documented decisions stand and this plan follows them.

## Starting state

- 16 PSD test suites pass. `psd/` is 16 modules / ~2.5k lines, read-only,
  PSD v1 + 8-bit + RGB/Gray only.
- Reference is 21 files / 8.4k LOC, read + write, PSD + PSB, depth 1/8/16/32,
  all eight color modes plus `Unknown`.
- **Blocker:** `src/opengraphics/psd.nim` does not compile. Commit `38d223d`
  ("cleanup") deleted all 71 `pdf/` files but left `exporting.nim` importing
  `./pdf/vipsimg`, which `psd.nim` re-exports. Tests pass only because they
  import submodules directly.

## Three architectural changes this drives

| Concern | Now | Target | Why |
|---|---|---|---|
| **Channels** | eager decode to `seq[byte]` planes | lazy `ChannelData { id, compression: Option[Compression], data }`, decode on demand | **Required** for round-trip; preserved encoded bytes must survive a read/write cycle |
| **Padding** | discarded after each block | `Option[seq[byte]]` per block, `none` only when the file used the canonical zero-pad | Round-trip |
| **Reader** | one flat `BinReader` plus manual `extraEnd` / `sectionEnd` bookkeeping | zero-copy `sub(n)` scoping plus a `Writer` with back-patching `beginLen` / `endLen` | PSB length fields and write-back |

## Module layout

```
psd.nim              entry point: new core + compatibility re-exports
psd/
  types.nim          PsdError, Limits (extended with maxDecodedBytes)
  reader.nim         Reader{sub,bytes,bytesU64,lenField,checkCount,readPascal,...}
                     Writer{putU16...,putLen,beginLen,endLen,writePascal},
                     unicode and legacy-name codecs
  header.nim         Version{Psd,Psb}, ColorMode (+ Unknown(u16)), Header,
                     rowBytes, validate
  compression.nim    Compression, PlaneLayout, decodePlanes/encodePlanes,
                     packbits encode/decode, predict/unpredict (1/8/16/32-bit)
  pixels.nim         sample helpers (samplesU16/F32, unpackBits, planeToU8);
                     ImageBuf / Rgba retained as the compatibility pixel model
  file.nim           PsdFile, parse order, LayerInfoPlacement, GlobalLayerMask,
                     toBytes
  layers.nim         Rect, LayerFlags, MaskData/LayerMask/MaskParameters/RealMask,
                     BlendingRanges, ChannelData, LayerRecord, LayerInfo,
                     layer tree
  tagged.nim         TaggedBlock{padding}, BlockData (12 keys), SectionDivider,
                     PSB_LONG_KEYS
  resources.nim      ImageResource, ResourceData (11 ids), ResolutionInfo,
                     VersionInfo
  descriptor.nim     Descriptor, Value (all 18 OSTypes), Id, Class,
                     ReferenceItem (7), UnicodeString, ObjectArray,
                     VersionedDescriptor
  path.nim           PathData, PathRecord, selectors, VectorMaskBlock,
                     fixed824 <-> f64
  blend.nim          BlendMode (28 variants) + key mapping
  slices.nim         SlicesResource, v6 binary + v7/8 descriptor
  patterns.nim       PsdPattern, Patt/Pat2/Pat3 blocks, .pat file
  metadata.nim       shmd MetadataItem
  builder.nim        PixelData, LayerSpec, GroupSpec, MaskSpec, PsdBuilder
  render.nim         compositor (ported)
  text.nim           TySh, retargeted onto the real descriptor parser
  vector.nim         vsms/vscg semantic layer, built on path.nim + descriptor.nim
  smartobject.nim    SoLd/PlLd, retargeted onto the real descriptor parser
  compat.nim         Document, readPsdBytes, openPsd, layerText, placedLayer, ...
```

## Phases

### Phase 0 — Unblock

Remove the dead `./pdf/vipsimg` import from `exporting.nim` along with the
`PdfImage` overloads. Restore a green baseline.

### Phase 1 — Foundation

`types` (structured `PsdError` mirroring the reference's seven variants),
`reader` (sub-readers plus `Writer`), `header` (`Version`, `ColorMode.Unknown`,
PSB-aware), `compression` (`PlaneLayout`; promote Nim's proven PackBits and
`zip.nim`; add PSB u32 RLE counts, 16-bit sample delta, 32-bit byte-plane
shuffle plus delta), `pixels` (sample codecs).

### Phase 2 — Structural core

`tagged` (with padding capture), `resources`, `layers` (lazy `ChannelData`),
`file` (`PsdFile` plus `to_bytes`), layer tree.

**Milestone: byte-exact round-trip on `tests/data/01.psd` and
`tests/data/unifies-popular-graphics-gray.psd`.**

### Phase 3 — Descriptors

Full grammar: 18 OSTypes (including `obj `, `ObAr`, `Pth `, `GlbO`, `UnFl`,
`tdta`, `alis`), 7 reference item types, depth 64. Replaces the current parser
that *raises* on unknown OSTypes.

### Phase 4 — Extended read (done)

`slices`, `patterns`, `metadata`, `path` resources (1025, 2000-2997), and
`Lr16` / `Lr32` / `Layr` lifting with positional re-insertion.

- `core/slices.nim`: resource 1050. Version 6 binary, versions 7/8 as a
  versioned descriptor. `writeSlices` emits version 6, which every Photoshop
  reads. Verified against the real fixtures (both carry a version 6 resource
  with one auto-generated 700x700 slice). Note the rewrite is *not* byte-exact:
  the fixtures' 841-byte payloads hold a 724-byte trailing descriptor that
  this module does not model. The files still round-trip because image
  resources are preserved verbatim.
- `core/patterns.nim`: `Patt` / `Pat2` / `Pat3` global blocks and `.pat` files,
  with sub-rect channel placement and the 24-slot virtual memory array list.
  Round-trips at 8/16/32 bits with and without alpha.
- `core/metadata.nim`: the `shmd` block, byte-exact on every layer of both
  fixtures (72 bytes, one `cust` item each). `compositorInfo` parses `cust`
  with a prefix parse because Photoshop writes its pad byte *outside* the
  descriptor.
- `core/path.nim`: added `WorkPathId`, `parsePathResource`, `savedPaths` and
  `workPath`. Neither fixture has a saved or work path, so these are covered
  synthetically.
- `Lr16` / `Lr32` / `Layr` lifting was already done in phase 2.

Two parser bugs found while porting, both from real data rather than review:
the `shmd` reserved field is 3 bytes (reading 4 desynchronised every item),
and `readUnicodeUnits` consumes its own u32 length.

### Phase 5 — Semantic layers retargeted

`text`, `vector`, `smartobject` move from byte-scanning (today `text.nim` hunts
for `"tdta"` substrings) onto the real descriptor parser. A strict improvement
in correctness.

### Phase 6 — Builder (done)

`core/pixeldata.nim` and `core/builder.nim`.

- `PixelData` variants Rgba8/16, GrayA8/16, Cmyka8/16. CMYK values are ink
  amounts and are inverted on the way to disk; alpha is not inverted. Each
  variant is a `case` field so only the active one is readable.
- `PsdBuilder`: colour mode, depth (8/16), PSD or PSB, compression, layers,
  nested groups, per-layer masks, resolution / ICC / raw resources.
- The builder never composites. Without a composite it writes a white
  placeholder and sets `hasRealMergedData = false` in resource 1057.
- 16-bit documents put their layer info in an `Lr16` global block, 8-bit in
  the section, matching what Photoshop does.
- Built files re-serialize byte-for-byte, verified for RGB, CMYK, grayscale,
  PSB, 16-bit, grouped and masked cases.

Notes:
- `LayerMask` records must be built with `newLayerMask` (the 20-byte form).
  A bare 18-byte record is rejected by `parseLayerMask` and comes back as
  `mdRaw`, which silently loses the typed mask.
- `Compression` needed an explicit `==`; Nim's derived equality cannot
  compare variant objects.
- The legacy Pascal name field is lossy ASCII (`é` becomes `?`). The display
  name via `LayerRecord.name()` prefers the `luni` block.

### Phase 7 — Compatibility shim (done)

`core/` is promoted to `psd/` and `core/` is gone. The seventeen old modules
are replaced by the promoted core plus two:

- `psd/pixels.nim`: `ImageBuf`, `Rgba`, `savePpm`, `saveBmp`. Compositing
  surface only; unchanged apart from depending on the new `error.nim`.
- `psd/document.nim`: the compatibility layer. `Document`, `readPsdBytes`,
  `openPsd`, `layerTree`, `layerByName`, `visibleLayers`, `compositeImage`,
  `layerImage`, `layerPlane`, `Thumbnail` / `saveThumbnailJpeg` /
  `hasThumbnail`, `iccProfile`.
- `psd/render.nim`: ported onto the new core. `blendModeFromKey` and
  `blendChannel` keep their integer arithmetic; phase 8 refines them.

`psd.nim` is the facade and still re-exports `exporting`, which depends on
`ImageBuf`.

Retired suites, each superseded: `t_psd_reader`, `t_psd_rle`, `t_psd_zip`,
`t_psd_header` (by `t_psd_core_io` / `_compression` / `_header`), and
`t_psd_text`, `t_psd_vector`, `t_psd_smartobject`, `t_psd_realfile` (by
`t_psd_core_semantic`, `t_psd_core_path` and `t_psd_fixtures`).

Four bugs found while porting, three of them silent data loss:

- **Layer flag bits 5-7 were dropped.** `rawFlags` rebuilt the byte from the
  five bits the spec defines, so a file setting bit 5 came back without it.
  `02.psd` sets it on many records and no longer round-trips. `LayerFlags`
  now carries a `reserved` field for the undefined bits.
- **`maxBlocks` and `maxDecodedBytes` were declared but never enforced.** A
  resource or tagged-block section could expand into millions of records, and
  a small ZIP payload could inflate past any bound. Both are now checked.
- **A layer with no alpha channel rendered fully transparent.** `layerImage`
  indexed channels positionally; it now looks up `-1` by id and treats its
  absence as opaque.
- **`planesToImage` indexed colour planes without bounds-checking**, so an RGB
  header over a one-channel merged image raised `IndexDefect` instead of
  `PsdError`. It now raises `invalid`.

Two behaviour corrections where the old code disagreed with the reference:

- `lsct` takes priority over `lsdk`; the old reader had `lsdk` winning.
- An unknown compression code is preserved rather than rejected, so such a file
  still round-trips.

`PlLd` was supported by the old `smartobject.nim` but not by the reference, and
was dropped in the port. It is restored in `semantic.nim`: `01.psd` really does
carry both `SoLd` and `PlLd` on its smart-object layer.

### Phase 8 — Compositing port (done)

`blendChannel` stays integer and `pure` for the 21 separable modes.
`blendRgb` takes the whole pixel in f32 for the six non-separable ones: the four
W3C HSL modes plus DarkerColor and LighterColor, which pick a whole colour and so
cannot be expressed per channel. `blendModeKey` was added so a parsed blend mode
round-trips. Dissolve is resolved in the compositor as a deterministic
position-keyed dither, and a group with a blend mode of its own is isolated onto
its own canvas and composited as one layer, while pass-through groups blend
straight into the backdrop.

Three formulas were wrong and are now W3C-correct, each caught by the
differential test rather than by eye:

- **SoftLight** was an approximation, and its branch threshold was off by one.
  The spec's threshold is a normalised 0.5, and 128/255 is 0.50196, so `cs <=
  128` sent exactly 128 down the wrong branch -- off by up to 64 LSB. Now
  `sqrt(Cb)` at the top end, and `cs <= 127`.
- **PinLight** used `2*(Cs - 128)`, which is `2Cs - 256`, where the spec says
  `2Cs - 255`.
- **Overlay** was not `HardLight` with the operands swapped.

Compositing happens at 8-bit via the `planeToU8` downscale; precision loss is
documented. No float or 16-bit compositor.

**Measured against Photoshop.** `01.psd` (all-normal) renders 97.86% of pixels
exactly matching the stored composite; the 2% is text layer effects. `02.psd`
reaches only 0.9% at best, because its 30 smart objects, 21 text layers, masks
and vector shapes are not modelled yet -- phase 8 does not touch any of them.
One honest caveat: on `02.psd`, which is the only fixture using SoftLight, the
old approximation matched Photoshop's stored composite marginally better
(0.9% vs 0.45%). Both figures are dominated by that file's unmodelled features,
so neither is evidence about SoftLight. The exhaustive differential test against
the W3C definitions is the stronger signal; matching Photoshop's own 8-bit
SoftLight approximation instead would be a deliberate, separate choice.

### Phase 9 — Test hardening (done)

`tests/psd_testgen.nim` generates the corpus at the model level rather than
through `PsdBuilder`, because the builder is deliberately narrow: it takes
interleaved RGBA / GrayA / CMYKA buffers at 8 or 16 bits. The corpus has to
reach the modes and depths the *parser* accepts but the builder will not
produce -- Bitmap, Indexed, Lab, Multichannel, Duotone, and 1 / 32 bits -- since
those are the paths with the least other coverage. Every generator is a pure
function of its arguments, so a failing case reproduces from its own inputs.

Nim has no proptest or fuzz equivalent, so the reference's property tests become
deterministic sweeps: mutation positions and values come from a seeded
splitmix64 rather than a random draw, which covers the same shape and prints the
exact input that caused any failure.

**Truncation sweeps** assert that a prefix either fails or yields a *complete*
composite. "Fails at every offset" turned out to be the wrong claim: the tail of
a ZIP stream is an Adler-32 checksum over the *decoded* data, so a prefix that
drops only those bytes loses no pixels and there is nothing to reject. Asserting
otherwise would be a test asserting something untrue, so the sweep holds the
stronger, actually-true property instead, with a rejection-rate floor to stop it
going vacuous.

**Four real bugs, all found by the sweeps rather than by reading:**

- `zipValidate` never checked the size it inflated to. A composite truncated in
  its last few bytes still validated, because the missing tail was checksum
  rather than pixels. It now requires exactly the expected count.
- `zipValidate` and `zipDecompress` both probed for a zlib wrapper by reading
  bytes 0 *and* 1, so a one-byte tail raised `IndexDefect` and crashed instead
  of returning a `PsdError`.
- `Reader.lenField` range-converted the 64-bit PSB length with `.int64`, which
  raised `RangeDefect` on any field with its sign bit set -- escaping as a crash.
  Reinterpreting the bits would have been worse: a negative count reads as
  "smaller than what is here" and walks off the end.
- The corpus generator's first `small` rewrote a layered file's header without
  re-encoding its channels, which is not a valid file. Caught because the
  truncation sweep accepted far more prefixes than it should have.

**Leaks.** `leaks --atExit` reports zero unreachable allocations for the whole
suite (816 nodes, 110 KB live at exit, none leaked). That check cannot see a
reference cycle, though, and the `Source` / `Mapping` pair from the zero-copy
work is exactly the shape where one would hide -- a mapping held alive by a span
held inside the buffer it maps. So there is a retention guard that measures
*current* RSS across 300 rounds of parse, serialise, tree-build and channel
decode. `getrusage` is no use here: `ru_maxrss` is a high-water mark that never
falls, so the first round would set it and every later leak would hide underneath.
The guard was verified to fire on deliberate retention (9.9 MB of growth against
a 60 KB threshold) rather than passing vacuously.

### Phase 10 — Docs

Rewrite the README PSD section; rewrite `plans/psd-roadmap.md`.

## Decisions

### Blend math changes semantics

Nim's `render.nim` uses integer W3C formulas. The reference uses f32 with four
Photoshop-specific overrides and a 1e-4 epsilon. These genuinely diverge:

- `SoftLight` — Nim is W3C; the reference uses the PS variant
  (`2cb*cs + cb^2*(1-2cs)` for `cs <= 0.5`).
- `HardMix` at `(128, 128)` — Nim gives `0`; the reference's thresholded generic
  Vivid Light gives `255`.
- `Divide` at `(0, 0)` — Nim gives `255`; the reference gives `0`.
- `ColorBurn` / `ColorDodge` gain an `EDGE = 1e-4` epsilon so near-extreme 8-bit
  values behave as exact 0 / 1.

Adopting the reference's formulas should improve the ~98% fixture match, but it
breaks the pinned integer assertions in `t_psd_render.nim`. Those pins get
updated to the new expected values rather than keeping both.

### Integer arithmetic survives contact with the reference

`EDGE` guards read `cb >= 1.0 - 1e-4`. For 8-bit input, normalized values are
`k/255` and only `k == 255` satisfies that (`254/255 = 0.99608` falls short). So
**at 8-bit every `EDGE` guard is exactly equivalent to an integer `== 255` test.**
The epsilon exists to make near-extreme float inputs behave as exact extremes;
quantized integer inputs have no such near-extremes.

At 16-bit the guard does bite (it covers `k >= 65529`, a band of ~7 values), which
matters only if we composite at 16-bit depth. We do not.

Nim's `compositeOver` was checked against the W3C general formula the reference
uses. It computes `mix = alphaS / alphaO`, giving
`Co = (1-alphaS)*alphaB*Cb + alphaS*Cs` for Normal, exactly what W3C reduces to.
It also handles `dst.a == 0` explicitly rather than blending against black. The
existing integer composite stands.

### Mode coverage goes 20 to 28

Adds `PassThrough`, `Dissolve` (per-pixel dither, resolved in the compositor),
`DarkerColor`, `LighterColor`, and the non-separable HSL family
(`Hue` / `Saturation` / `Color` / `Luminosity`, using
`lum = 0.3R + 0.59G + 0.11B`, not Rec.709).

### Deferred

- **Text gamma** (`TEXT_GAMPA = 1.45`, Photoshop's "Blend Text Colors Using
  Gamma"). A Photoshop preference requiring an f32 path; text is already the ~2%
  of the fixture that does not match. Add later as an opt-in per-layer flag and
  measure whether it closes that gap.
- **CIELAB `LAB_MIX`.** Only relevant for Lab documents, which produce no RGBA8
  in our model anyway.
- **A float or 16-bit compositor.** Composite at 8-bit via `planeToU8`.

### Known-naive areas carried over with docs, not fixed

CMYK to RGB (`r = c*k/255` on stored inverted values), no ICC color management,
Lab / Multichannel / `Unknown` produce no RGBA8, mask feather unimplemented,
blending ranges parsed raw with no compositing effect, knockout parsed (`knko`)
but not composited.

### Byte-exactness caveats

Mirroring the reference's documented caveats: Pascal-name pad bytes are written
as zeros; a layer-and-mask section containing only a zero layer-info length is
normalized to an empty section. Both are pathological. `Descriptor` is *not*
lossless for unknown OSTypes — it errors rather than preserving, unlike tagged
blocks and resources.
