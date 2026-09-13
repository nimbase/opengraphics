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
- Read Adobe Photoshop `.psd` files
  - Headers, layers and group trees
  - Raw and RLE pixels
  - Thumbnails, ICC profiles
- Read Adobe Illustrator `.ai` files
  - modern PDF-based, v1: kind detection, artboards, XMP metadata
- Shared pixel model (`ImageBuf`) designed for conversion from one format to another
- Unknown blocks preserved as raw bytes so future writers can round-trip files

## Roadmap
- Read support for `.eps`, `.aep`, and more
- Writers for each supported format
- Format-to-format conversion helpers
- Building blocks for high-level libraries and apps compatible with popular graphics formats

## Examples
Runnable versions live in `examples/` (run from the package root).

### PSD Documents
#### Opening a .psd file
```nim
import opengraphics/psd

let doc = openPsd("tests/data/01.psd")
echo doc.width, "x", doc.height, " layers: ", doc.layerCount
for node in doc.layerTree():
  echo node.layer.displayName()
doc.composite.savePpm("preview.ppm") # stdlib only
doc.composite.saveImage("preview.jpg") # libvips: jpg/png/webp/tif/gif/heif/avif/jxl
```

### PDF Documents
#### Reading a .pdf file
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

#### Writing a .pdf file
```nim
import opengraphics/pdf

var b = newPdfBuilder() # catalog 1, page tree 2, content from 3 up
let cnum = b.addContentStream(
  "BT /F1 24 Tf 72 720 Td (Hello writer) Tj ET") # Flate by default
let res = CosObj(kind: coDict, keys: @["Font"],
  vals: @[CosObj(kind: coDict, keys: @["F1"], vals: @[CosObj(kind: coDict,
    keys: @["Type", "Subtype", "BaseFont"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type1"),
      CosObj(kind: coName, name: "Helvetica")])])])
discard b.addPage(612.0, 792.0, cnum, res)
writeFile("hello.pdf", b.buildPdf())

var d = openDoc(rewritePdf(readFile("hello.pdf"))) # defrag round-trip
echo "pages: ", d.pageCount()

var u = beginUpdate(readFile("hello.pdf")) # incremental: appends + /Prev
# ... u.addObject(...) / u.updateObject(...) ...
writeFile("hello-v2.pdf", u.finishUpdate())
```

#### Embedding a font (harfbuzz)
```nim
import opengraphics/pdf
import std/tables

let prog = readFile("../harfbuzz/tests/data/DejaVuSans.ttf")
var sf = openShapedFont(prog) # one cached face per program
defer: close(sf)
var use = FontUse(fontBytes: prog, baseName: "DejaVuSans")
var content = ""
for i, line in wrapText(sf, "Hello embedded writer", 24.0, 468.0):
  use.noteUse(line) # WinAnsi only; anything else fails loudly
  content.add(drawTextLine(72.0, 720.0 - float64(i) * 28.0,
    "F2", 24.0, line) & "\n")
var b = newPdfBuilder()
let fonts = b.finalizeFonts({"F2": use}.toTable) # subsets + embeds
let cnum = b.addContentStream(content)
discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
writeFile("embedded.pdf", b.buildPdf())
```

#### Document text and search
```nim
import opengraphics/pdf

var d = openMappedDoc("tests/data/pdf/file-example_PDF_500_kB.pdf")
let doc = d.extractDocumentText("1.4") # pages with runs, lines, blocks
echo "pages: ", doc.pageCount
for h in doc.searchText("Lorem"): # exact, stdlib-only
  echo "p", h.page, " line ", h.line, " col ", h.col, ": ", h.excerpt
d.close()

import openparser/fuzzy # caller-side fuzzy; not an opengraphics dep
var lines: seq[string] = @[]
for p in doc.pages:
  for b in p.blocks:
    lines.add(b.text)
for m in fuzzySearch("lorem", lines, FuzzyOptions(limit: 3)):
  echo "fuzzy score ", m.score, ": ", m.text
```

#### Sheet rows and tables
```nim
import opengraphics/pdf

var d = openMappedDoc("tests/data/pdf/file-example_PDF_500_kB.pdf")
let sheet = d.extractSheet("1.4") # pages of classified rows + tables
for p in sheet.pages:
  for t in p.tables: # whitespace grid: headers + rows of cells
    let ncols = if t.headers.len > 0: t.headers.len
      elif t.rows.len > 0: t.rows[0].len else: 0
    echo "table: ", t.rows.len, " rows x ", ncols, " cols"
    for r in t.rows:
      echo "  ", r.join(" | ")
d.close()
```

### Illustrator files (.ai)

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
MIT license | Nimbase Community
