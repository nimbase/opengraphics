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
- Read Adobe Photoshop `.psd` files
  - Headers, layers and group trees
  - Raw, RLE and ZIP pixel data
  - Layer masks and global masks
  - Vector shapes and solid-color fills
  - Smart object metadata (transform, bounds, warp)
  - Layer-stack rendering (blend modes, opacity, clipping, masks)
  - Text engine data (text, fonts, sizes)
  - Thumbnails, ICC profiles
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

let doc = openPsd("tests/data/01.psd")
echo doc.width, "x", doc.height, " layers: ", doc.layerCount

# Walk the layer/group tree and print each layer's display name.
for node in doc.layerTree():
  echo node.layer.displayName()

# The flattened composite: PPM needs stdlib only, JPG needs libvips.
doc.composite.savePpm("preview.ppm")
doc.composite.saveImage("preview.jpg") # jpg/png/webp/tif/gif/heif/avif/jxl

# Text layers (TySh): raw block stays preserved, parsed view is lazy.
import std/options
for l in doc.layers:
  if l.isTextLayer():
    let t = l.layerText().get()
    echo l.displayName(), " -> ", t.displayText(), " ", t.fontNames

# Layer masks: rect + flags parse at load, -2 channel holds the pixels.
for l in doc.layers:
  if l.hasMask():
    echo l.displayName(), " mask ", l.maskWidth(), "x", l.maskHeight(),
      " enabled=", l.maskEnabled(), " bytes=", l.maskData().len

# Re-render the stack instead of trusting the stored composite
# (blend modes, opacity, clipping, group opacity, masks).
renderDocument(doc).savePpm("render.ppm")

# Vector shapes: path geometry + fill stay parsed beside the pixels.
for l in doc.layers:
  if l.hasVectorMask():
    let vm = l.vectorMask().get()
    echo l.displayName(), " subpaths=", vm.subpaths.len,
      " knots=", vm.subpaths[0].knots.len
  if l.hasFillContent():
    let fc = l.fillContent().get()
    echo l.displayName(), " fill=", fc.kindKey,
      " (", fc.red, ",", fc.green, ",", fc.blue, ")"

# Smart objects: placed-layer metadata beside the raster pixels.
for l in doc.layers:
  if l.isSmartObject():
    let pl = l.placedLayer().get()
    echo l.displayName(), " smart ", pl.kind, " id=", pl.uniqueId,
      " warp=", pl.warpStyle
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
- Writers for each supported format
- Format-to-format conversion helpers
- Building blocks for high-level libraries and apps compatible with popular graphics formats

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
