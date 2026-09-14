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

#### Writing a .pdf file (high level)
```nim
import opengraphics/pdf

# A4 by default (psLetter, psLegal, psA5, psA3, psCustom available).
# No font file needed: the body starts on builtin Helvetica
# (unembedded, viewer-rendered, WinAnsi text only).
var doc = newPdf()
# Or start embedded: the program shapes via HarfBuzz and embeds as a
# subset on save, with full Unicode.
# var doc = newPdf("../harfbuzz/tests/data/DejaVuSans.ttf")
doc.setTitle("Hello")
doc.heading("Hello writer")
doc.paragraph("Wrapped on shaped widths, auto page breaks.")
doc.textAt("absolute at x, y", 72.0, 72.0)

# JPEG embeds byte-for-byte; anything else embeds lossless.
# With compress the pixels run through libvips (optional downscale
# to maxWidthPx, alpha over white) and re-encode at jpegQuality.
doc.imageFromFile("photo.jpg")
doc.imageFromFile("photo.jpg", ImageOpts(compress: true,
  jpegQuality: 60, maxWidthPx: 800, widthPt: 400.0))

doc.save("hello.pdf")
doc.close()
```

Runnable versions: `examples/example_pdf_simple.nim` (basics:
heading, paragraph, absolute text, two image modes) and
`examples/example_pdf_report.nim` (multi-page Letter report with
metadata, two fonts, compressed figures, read-back check).

High-level writer reference (`Pdf` is an opaque handle):

- Lifecycle: `newPdf(fontPath)` or `newPdf(fontBytes, baseName)`
  starts one open page; `save(path)` writes the file (`build()` returns
  the bytes and is repeatable); `close()` releases the HarfBuzz
  shaping contexts. `pageCount()` counts finished pages plus the open
  one when it holds content.
- Page sizes (`PageSize`, default `psA4`): `psA5` 419.53x595.28,
  `psA4` 595.28x841.89, `psA3` 841.89x1190.55, `psLetter` 612x792,
  `psLegal` 612x1008 (points), `psCustom` with explicit width/height
  via `pageDims`. `setPageSize` applies to later pages, `setMargin`
  sets the working margin (default 20 mm).
- Fonts: `newPdf()` starts on builtin Helvetica (no file, nothing
  embedded, WinAnsi only: CJK, emoji, and Euro fail loudly instead of
  misrendering). `loadFont(name, path)` loads a TTF/OTF program which
  HarfBuzz shapes and the writer subset-embeds on save with full
  Unicode; loading over an existing name (including `"body"`)
  upgrades it. `setFont(name, size)` switches, `fontNames()` lists
  loaded faces in order. Names stay ASCII letters, digits, `_`, `-`,
  `.` so they double as PDF resource names. Builtin advances are the
  Adobe AFM widths, verified against the licensed cut.
- Text (natural layout: greedy wrap on shaped widths, left aligned,
  no hyphenation): `paragraph` wraps and breaks pages automatically,
  `heading(text, size = 18.0)` adds space around one wrapped title,
  `textAt(text, x, y)` draws one absolute line, `newPage()` starts a
  fresh page.
- Images (`ImageOpts`): default embeds JPEG byte-for-byte and anything
  else lossless; `compress: true` re-encodes through libvips at
  `jpegQuality` (default 85) with optional downscale to `maxWidthPx`
  and alpha flattened over white; `widthPt` sets the placed width
  (default fits the text column, aspect kept).
- Metadata: `setTitle`/`setAuthor` land in the trailer `/Info` dict.
- Errors are loud `PdfError`: missing font file or glyph, unknown
  font name, unreadable or decodable image, empty input.

High-level reader surface (same import, no extra modules):
`openPdf`/`readPdfBytes`/`openPdfPassword` for snapshots,
`openDoc`/`openMappedDoc` plus `close` for lazy documents,
`extractText` (positioned runs), `pageImages` (decoded via libvips,
re-encoded with `encodeImage`/`saveImage`), `extractDocumentText`
plus `searchText`, and `extractSheet` for rows and tables.
Anything deeper (`pdf/write`, `pdf/cos`, `pdf/fontembed`,
`pdf/shape`, ...) imports directly for advanced use.

#### Writing a .pdf file (low level)
```nim
import opengraphics/pdf
import opengraphics/pdf/write
import opengraphics/pdf/cos
import opengraphics/pdf/docmodel
import opengraphics/pdf/text

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

#### Embedding a font (harfbuzz, low level)
```nim
import opengraphics/pdf
import opengraphics/pdf/write
import opengraphics/pdf/shape
import opengraphics/pdf/fontembed
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

#### Full Unicode (CID-keyed Type0, low level)
```nim
import opengraphics/pdf
import opengraphics/pdf/write
import opengraphics/pdf/shape
import opengraphics/pdf/fontembed
import std/tables

# Any TrueType/OpenType program works, including CFF outlines and
# CBDT color emoji; the CJK micro-subset ships under tests/data/fonts.
let prog = readFile("tests/data/fonts/cjk-cff-micro.otf")
var sf = openShapedFont(prog)
defer: close(sf)

# CIDs key on shaped glyphs (ligatures, reordering), so the open
# font travels with the use from the first call.
var use = CidFontUse(fontBytes: prog, baseName: "NotoSansJP")

# Lines shape through HarfBuzz and show as 2-byte Identity-H CIDs;
# kern corrections land in the TJ array automatically.
let content = drawCidLine(use, sf, 72.0, 720.0, "F3", 24.0, "日本語あAX")
var b = newPdfBuilder()

# finalizeFonts embeds a Type0 font (CIDFontType0/FontFile3 for CFF,
# CIDFontType2/FontFile2 for TrueType) with /CIDToGIDMap, /W and
# /ToUnicode, so our own reader round-trips the text unchanged.
let fonts = b.finalizeFonts({"F3": use}.toTable)
let cnum = b.addContentStream(content)

discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
writeFile("cid.pdf", b.buildPdf())
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

# CJK needs no flags: Identity-H fonts without ToUnicode resolve
# through built-in ordering tables (Japan1/GB1/CNS1/Korea1),
# predefined encodings, or the embedded font itself. Vertical
# (WMode 1) text groups into columns. Unmapped codes stay U+FFFD,
# never guesses.

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

**Source for PDFs samples:** https://github.com/EbookFoundation/free-programming-books/

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/opengraphics/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/opengraphics/fork)

### 🎩 License
MIT license | Nimbase Community
