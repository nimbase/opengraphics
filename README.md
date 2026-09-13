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

# Walk the layer/group tree and print each layer's display name.
for node in doc.layerTree():
  echo node.layer.displayName()

# The flattened composite: PPM needs stdlib only, JPG needs libvips.
doc.composite.savePpm("preview.ppm")
doc.composite.saveImage("preview.jpg") # jpg/png/webp/tif/gif/heif/avif/jxl
```

### PDF Documents
#### Reading a .pdf file
```nim
import opengraphics/pdf

# High-level handle: version, page count, metadata.
let doc = openPdf("tests/data/pdf/m3b_text.pdf")
echo "PDF ", doc.version, " pages: ", doc.pageCount

# Low-level handle: positioned text runs (string plus x/y origin).
var d = openDoc(readFile("tests/data/pdf/m3b_text.pdf"))
for run in d.extractText(0):
  echo "\"", run.text, "\" at (", run.x, ", ", run.y, ")"

# Embedded images decode through libvips (JPEG, JPX, masks, CMYK).
var imgs = openDoc(readFile("tests/data/pdf/m5_images.pdf"))
for im in imgs.pageImages(0):
  echo im.name, ": ", im.width, "x", im.height, " ", im.encoding
  im.saveImage("/tmp/" & im.name & ".png")

# Encrypted files announce themselves; pass the password to open.
echo "needs password: ", openPdfPassword(readFile("tests/data/pdf/m4_rc4.pdf"))
let locked = openPdf("tests/data/pdf/m4_rc4.pdf", password = "user123")
echo "unlocked pages: ", locked.pageCount
```

#### Writing a .pdf file
```nim
import opengraphics/pdf

var b = newPdfBuilder() # catalog 1, page tree 2, content from 3 up

# A content stream is just marked-up text: font F1 at 24pt, positioned
# at (72, 720). Streams Flate-compress by default.
let cnum = b.addContentStream(
  "BT /F1 24 Tf 72 720 Td (Hello writer) Tj ET")

# Pages point at a /Resources dict; here F1 is plain Helvetica
# (not embedded, so any reader can render it).
let helv = CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
  vals: @[CosObj(kind: coName, name: "Font"),
    CosObj(kind: coName, name: "Type1"),
    CosObj(kind: coName, name: "Helvetica")])
let res = CosObj(kind: coDict, keys: @["Font"],
  vals: @[CosObj(kind: coDict, keys: @["F1"], vals: @[helv])])
discard b.addPage(612.0, 792.0, cnum, res)
writeFile("hello.pdf", b.buildPdf())

# Read it back through a defragmenting rewrite (fresh offsets).
var d = openDoc(rewritePdf(readFile("hello.pdf")))
echo "pages: ", d.pageCount()

# Or append without rewriting: new objects plus an xref with /Prev.
var u = beginUpdate(readFile("hello.pdf"))
# ... u.addObject(...) / u.updateObject(...) ...
writeFile("hello-v2.pdf", u.finishUpdate())
```

#### Embedding a font (harfbuzz)
```nim
import opengraphics/pdf
import std/tables

# Any TrueType/OpenType program works; DejaVu ships with harfbuzz.
let prog = readFile("../harfbuzz/tests/data/DejaVuSans.ttf")

# One cached HarfBuzz face per program: shaping, measuring, subsetting.
var sf = openShapedFont(prog)
defer: close(sf)

# Collect every codepoint you draw; the subset is cut at the end.
var use = FontUse(fontBytes: prog, baseName: "DejaVuSans")
var content: string

# wrapText breaks on shaped widths so lines fit the 468pt column.
for i, line in wrapText(sf, "Hello embedded writer", 24.0, 468.0):
  use.noteUse(line) # WinAnsi only; anything else fails loudly
  content.add(drawTextLine(72.0, 720.0 - float64(i) * 28.0,
    "F2", 24.0, line) & "\n")
var b = newPdfBuilder()

# finalizeFonts subsets the program, embeds it with matching /Widths
# and /ToUnicode, and returns resource name to font object number.
let fonts = b.finalizeFonts({"F2": use}.toTable)
let cnum = b.addContentStream(content)
discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
writeFile("embedded.pdf", b.buildPdf())
```

#### Document text and search
```nim
import opengraphics/pdf

# Memory-mapped: the 500kB file is never fully copied.
var d = openMappedDoc("tests/data/pdf/file-example_PDF_500_kB.pdf")

# Runs grouped into lines, blocks, and pages of plain text.
let doc = d.extractDocumentText("1.4")
echo "pages: ", doc.pageCount

# Exact substring search from the stdlib, with page/line/col hits.
for h in doc.searchText("Lorem"):
  echo "p", h.page, " line ", h.line, " col ", h.col, ": ", h.excerpt
d.close()

# Fuzzy search is caller-side (openparser), not an opengraphics dep.
import openparser/fuzzy
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
# Each page as classified rows (heading/paragraph/list/caption/other)

# plus whitespace-grid tables (headers and rows of cell strings).
let sheet = d.extractSheet("1.4")
for p in sheet.pages:
  for t in p.tables:
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

# Modern .ai files are PDFs: detect the kind, then read artboards.
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
