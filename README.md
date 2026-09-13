<p align="center">
  Open parsers and writers for popular graphics file formats<br>
</p>

<p align="center">
  <code>nimble install opengraphics</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/opengraphics/">API reference</a><br>
  <img src="https://github.com/nimbase/opengraphics/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/opengraphics/workflows/docs/badge.svg" alt="Github Actions">
</p>


## Prerequisites
- Nim toolchain plus `clue` (see repo setup); Nim deps resolve via clue
  (`zlib`, `nimcypher`, `checksums`, plus editable `harfbuzz` and
  `libvips` checkouts).
- System libraries with pkg-config files: `harfbuzz` (text shaping)
  and `vips` (image decode and color). macOS MacPorts:
  `sudo port install harfbuzz vips`.

## Features
- High-quality 
- PDF reader and Writer
  - Encryption RC4, AES-128, AES-256 (R2-R6)
  - Digital Signatures PAdES B-B, B-T, B-LT, B-LTA
  - Form Filling (Text, checkbox, radio, dropdown, signature)
  - Form flattening (fields into page content)
  - Merge & Split (Combine or extract specific pages)
  - Attachments: Embed and extract files
  - Text extraction with position info
  - Font Embedding TTF/OpenType with subsetting
  - Images JPEG PNG (supporting alpha)
  - Incremental saves: Append changes, preserve signatures
- Read Adobe Photoshop `.psd` files: headers, layers and group trees, Raw and RLE pixels, thumbnails, ICC profiles
- Read Adobe Illustrator `.ai` files (modern PDF-based, v1: kind detection, artboards, XMP metadata), pure Nim stdlib, no dependencies
- Shared pixel model (`ImageBuf`) designed for conversion from one format to another
- Unknown blocks preserved as raw bytes so future writers can round-trip files

## Roadmap
- Read support for `.eps`, `.aep`, and more
- Writers for each supported format
- Format-to-format conversion helpers
- Building blocks for high-level libraries and apps compatible with popular graphics formats

## Examples
Runnable versions live in `examples/` (run from the package root).

### Opening a .psd file
```nim
import opengraphics/psd

let doc = openPsd("tests/data/01.psd")
echo doc.width, "x", doc.height, " layers: ", doc.layerCount
for node in doc.layerTree():
  echo node.layer.displayName()
doc.composite.savePpm("preview.ppm") # stdlib only
doc.composite.saveImage("preview.jpg") # libvips: jpg/png/webp/tif/gif/heif/avif/jxl
```

### Reading a .pdf file
```nim
import opengraphics/pdf

let doc = openPdf("tests/data/pdf/m3b_text.pdf")
echo "PDF ", doc.version, " pages: ", doc.pageCount

var d = openDoc(readFile("tests/data/pdf/m3b_text.pdf"))
for run in d.extractText(0):
  echo "\"", run.text, "\" at (", run.x, ", ", run.y, ")"

var imgs = openDoc(readFile("tests/data/pdf/m5_images.pdf"))
for im in imgs.pageImages(0):
  echo im.name, ": ", im.width, "x", im.height, " ", im.encoding
  im.saveImage("/tmp/" & im.name & ".png")

echo "needs password: ", pdfNeedsPassword(readFile("tests/data/pdf/m4_rc4.pdf"))
let locked = openPdf("tests/data/pdf/m4_rc4.pdf", password = "user123")
echo "unlocked pages: ", locked.pageCount
```

### Detecting a .ai file
```nim
import opengraphics/ai

let doc = openAi("artwork.ai")
echo "kind: ", doc.kind, " pdf: ", doc.pdfVersion
for ab in doc.artboards:
  echo "  [", ab.index, "] ", ab.width, "x", ab.height, "pt"
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/opengraphics/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/opengraphics/fork)

### 🎩 License
MIT license | Nim Community.
