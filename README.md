<p align="center">
  Open parsers and writers for popular graphics file formats<br>
</p>

<p align="center">
  <code>nimble install opengraphics</code> | <code>clue install opengraphics</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/opengraphics/">API reference</a><br>
  <img src="https://github.com/nimbase/opengraphics/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/opengraphics/workflows/docs/badge.svg" alt="Github Actions">
</p>

> [!NOTE]
> opengraphics unifies popular graphics formats under a single API: one shared pixel model, the same open/read patterns for PSD and AI, plus helpers to convert between formats.

## Features
- Read and write Adobe Photoshop `.psd` and `.psb` files
  - All eight colour modes, at 1, 8, 16 and 32 bits
  - Raw, RLE, ZIP and ZIP-prediction pixel data
  - Headers, layers and group trees
  - Layer masks, mask parameters and global masks
  - Vector shapes and solid-color fills
  - Adjustment layers: all 16 keys typed (`levl`, `curv`, `hue2`, `brit`,
    `nvrt`, `thrs`, `post`, `expA`, `vibA`, `blnc`, `mixr`, `grdm`, `phfl`,
    `selc`, `blwh`, `clrL`); anything unreadable stays raw. Nine evaluate
    live when rendering (invert, threshold, posterize, levels,
    brightness/contrast legacy and modern, curves, exposure, channel mixer,
    black & white, photo filter, gradient map, color balance, selective color,
    hue/saturation, vibrance); all but color lookup evaluate live
  - Layer effects: `lfx2` master switch + 10 kinds (drop/inner shadow,
    outer/inner glow, bevel, satin, color/gradient/pattern overlay,
    stroke), including multi-lists
  - Type layers: style runs, run lengths, fonts/sizes, tracking/leading,
    justifications, warp + text-space bounds
  - Smart objects: `SoLd`/`SoLE`/`PlLd` metadata, embedded/linked files
    (`lnk2`/`lnk3`/`lnkD`), filter stacks (54 mapped commands, the rest
    kept raw)
  - Fill layers: `SoCo`, `GrFl` (angle, stops, opacity stops) and `PtFl`
    (pattern reference, scale, angle, phase)
  - Document metadata: guides (1032 + 1092 colors), layer comps (1065),
    duotone (+1066 alternates), channel names, notes (`Anno`)
  - Indexed palette mapping and Lab-to-sRGB previews; multichannel falls
    back to a 3-plane preview instead of refusing to open
  - Layer-stack rendering: all 27 blend modes, per-pixel dissolve,
    group pass-through, opacity, clipping and masks
  - Thumbnails, ICC profiles
  - Zero-copy reads: parsed payloads are windows into the caller's buffer or a
    memory mapping, never copies
  - Byte-exact round-trip: an unmodified file written back is identical
    to the bytes that were read
- Read Adobe Illustrator `.ai` files
  - modern PDF-based, v1: kind detection, artboards, XMP metadata
- Read After Effects `.aep` projects
  - project structure, compositions, layers, properties
- Shared pixel model (`ImageBuf`) designed for conversion from one format to another
- Unknown blocks preserved as raw bytes so future writers can round-trip files

## Prerequisites
- Pure Nim throughout: `harfnim` (text shaping), `archive`
  (compression), `image` (image encode). No system libraries.

## Examples
Runnable versions live in `examples/` (run from the package root).

### PSD Documents
#### Opening a .psd file
```nim
import opengraphics/psd

# `openPsd` memory-maps the file; `openPsdRead` reads it into the heap
# instead. Prefer the read path if another process may truncate the file
# while it is open: a truncated mapping faults with SIGBUS, which no
# handler can catch.
let doc = openPsd("tests/data/01.psd")
echo doc.width, "x", doc.height, " layers: ", doc.layerCount

# Walk the layer/group tree and print each layer's name.
for node in doc.layerTree():
  echo node.layer.name()
echo "index of \"nim-lang\": ", doc.layerByName("nim-lang")

# The flattened composite: PPM needs stdlib only, JPG needs the image package.
doc.composite.savePpm("preview.ppm")
doc.composite.saveImage("preview.jpg") # jpg/png/webp/tif/gif (heif/avif/jxl have no pure-Nim encoder yet)

# Text layers (TySh): raw block stays preserved, parsed view is lazy.
for l in doc.layers:
  if l.isTextLayer():
    let t = l.textOf().get()
    echo l.name(), " -> ", t.engineText, " ", t.fontNames

# Layer masks: the rect sizes the -2 channel, so read it before decoding.
for l in doc.layers:
  if l.mask.kind == mdMask:
    let r = l.mask.maskRect()
    echo l.name(), " mask ", r.width(), "x", r.height(),
      " default=", l.mask.mask.defaultColor

# Vector shapes: path geometry + fill stay parsed beside the pixels.
for l in doc.layers:
  if l.hasVectorMask():
    let vm = l.vectorMask().get()
    echo l.name(), " path records=", vm.path.records.len,
      " version=", vm.version
  if l.hasFillContent():
    let fc = l.fillContent().get()
    if fc.solid.isSome:
      let sf = fc.solid.get()
      echo l.name(), " fill=", fc.key,
        " (", sf.red, ",", sf.green, ",", sf.blue, ")"

# Smart objects: placed-layer metadata beside the raster pixels.
for l in doc.layers:
  if l.isSmartObject():
    let pl = l.placedLayer().get()
    echo l.name(), " smart ", pl.kind, " id=", pl.uniqueId,
      " warp=", pl.warpStyle

# Re-render the stack instead of trusting the stored composite: all 27
# blend modes, per-pixel dissolve, group pass-through, opacity,
# clipping and masks.
renderDocument(doc).savePpm("render.ppm")

# Write it back. An unmodified file round-trips byte for byte, which is
# what makes read-modify-write safe: only what you actually change
# differs in the output.
import std/os
writeFile("copy.psd", writePsd(doc.file))
```

### Illustrator files (.ai)

### Detecting a .ai file
```nim
import opengraphics/ai

# Modern .ai files are PDFs: detect the kind, then read artboards.
let doc = openAi("artwork.ai")
echo "kind: ", doc.kind, " pdf: ", doc.pdfVersion
for ab in doc.artboards:
  echo "  [", ab.index, "] ", ab.width, "x", ab.height, "pt"
```

### Vector artwork: read, manipulate, write
```nim
import opengraphics/ai

# PDF-compatible .ai content streams become editable vector artwork:
# one artboard per page, paths with fills and strokes, clipping groups,
# axial/radial shadings as gradients, placed-image references, and
# decoded text gathered into point-type lines (spaces inferred from
# gaps, runs split on font/size/paint changes). Illustrator layers
# arrive as one layer per optional content group (name, visibility,
# lock, print state, shared across pages); unmarked art stays on a
# per-page layer. ICCBased paints resolve through their alternate
# space.
# Runs from embedded fonts also carry harfnim-shaped glyphs and baked
# outlines, which is what the writer emits (text without outlines is
# skipped loudly, images are skipped loudly).
# Everything approximated is listed in `vec.warnings`, never dropped
# silently.
var vec = readAiVectors("artwork.ai")
echo "artboards: ", vec.artboards.len, " warnings: ", vec.warnings.len
for layer in vec.layers:
  for n in layer.children:
    if n.kind == vnkPath:
      echo "path with ", n.path.subs.len, " subpaths"

# Write it back as PDF-compatible .ai (one page per artboard).
var rep = writeAi(vec)
writeFile("copy.ai", rep.bytes)
for w in rep.warnings:
  echo "write: ", w
```

Legacy EPS-based `.ai` (pre-Illustrator 9) reads its envelope only
(bounding box, preview, version markers); interpreting the PostScript
program is out of scope and fails loudly. No `/AIPrivateData` is ever
written: generated files carry PDF-compatible artwork, not native
Illustrator edit state.

## Roadmap
Extended version of what is left, grouped by area. The PSD model is
read-complete for the documented format; what remains is mostly the
compositor catching up with the model, plus write-side authoring.

### Render from the parsed model
- [x] All 27 blend modes, dissolve, group pass-through, opacity, clipping,
  masks, Blend If, vector-mask rasterisation
- [ ] Layer effects composited per effect (shadows, glows, overlays, stroke)
- [x] Adjustment layers applied as live adjustments instead of transparent layers
  (live: invert, threshold, posterize, levels, brightness/contrast legacy and
  modern, curves, exposure, channel mixer, black & white, photo filter,
  gradient map, color balance, selective color, hue/saturation, vibrance;
  color lookup stays transparent, its profile payload carries no table)
- [ ] Smart-filter stacks evaluated (params are parsed; `FEid`/`FXid` caches
  are preserved raw today)
- [ ] Gradient/pattern fills regenerated from descriptors
- [ ] Knockout (`knko` is parsed, not applied) and a bitmap-1 polarity oracle
  against Photoshop-written bytes

### PSD model (read)
- [x] All 16 adjustment keys typed, unknown kept raw
- [x] `lfx2` effects (master + 10 kinds, multi-lists)
- [x] Text runs/paragraphs/warp/bounds
- [x] `SoLd`/`SoLE`/`PlLd`, `lnk2/3/D` files, 54 filter commands
- [x] `GrFl`/`PtFl` fill content
- [x] Indexed/Lab previews, multichannel fallback
- [x] Guides, comps, duotone, channel names, notes
- [ ] `FEid`/`FXid` cache use, book-ink preview wiring, sound annotations

### Write-side authoring
- [x] PSD write done; unmodified files round-trip byte for byte
- [ ] Authoring type/shape/smart-object/effect/pattern content (today:
  verbatim blocks plus generic constructors; unknown descriptor types
  still abort instead of round-tripping)
- [ ] Heavier composites: isolated groups already cost one full-canvas
  buffer each; effects/adjustments will add to that

### Formats
- [ ] Read support for `.eps` and more (writers for the remaining formats)
- [ ] Format-to-format conversion helpers
- [ ] Building blocks for high-level libraries and apps compatible with popular graphics formats

See `plans/psd-roadmap.md` for the PSD status and its deliberate limitations.
`audits/` holds dated audits: measurements taken against real files, what they
prove, and where they were wrong. `audits/psd-fidelity-2026-10-05.md` records
how closely the compositor matches Photoshop and why a single match percentage is
the wrong thing to track.

### References
- https://github.com/TheNicker/libpsd
- https://github.com/forticheprod/py-aep
- https://github.com/boltframe/aftereffects-aep-parser
- https://github.com/EbookFoundation/free-programming-books/

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/opengraphics/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/opengraphics/fork)

### 🎩 License
MIT license | Nimbase Community
