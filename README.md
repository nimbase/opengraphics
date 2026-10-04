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
- Initially made for [DatEngine](https://github.com/openpeeps/datengine), a Modular AI Agentic Framework written in Nim lang
- Read and write Adobe Photoshop `.psd` and `.psb` files
  - All eight colour modes, at 1, 8, 16 and 32 bits
  - Raw, RLE, ZIP and ZIP-prediction pixel data
  - Headers, layers and group trees
  - Layer masks, mask parameters and global masks
  - Vector shapes and solid-color fills
  - Smart object metadata (transform, bounds, warp)
  - Layer-stack rendering: all 27 blend modes, per-pixel dissolve,
    group pass-through, opacity, clipping and masks
  - Text engine data (text, fonts, sizes)
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
- System libraries with pkg-config files: `harfbuzz` (text shaping)
  and `libvips` (image decode and color)

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

# The flattened composite: PPM needs stdlib only, JPG needs libvips.
doc.composite.savePpm("preview.ppm")
doc.composite.saveImage("preview.jpg") # jpg/png/webp/tif/gif/heif/avif/jxl

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

## Roadmap
- Read support for `.eps` and more
- Writers for the remaining formats (PSD is done)
- Vector-mask rasterisation, knockout and blending ranges in the compositor
- Adjustment and effect layers (`lfx2` is parsed structurally, not interpreted)
- Format-to-format conversion helpers
- Building blocks for high-level libraries and apps compatible with popular graphics formats

See `plans/psd-roadmap.md` for the PSD status and its deliberate limitations.

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
