# PDF roadmap

Status: M0 done (RC4 via nimcypher), M1 done (lexer, cos, xref,
docmodel), M2 done (filters on the `zlib` package), M3a done
(content-stream parser plus graphics state), M4 done (Standard
encryption V1/V2/V4/V5), M3b done (text, CMaps, harfbuzz shaping),
M5 done (images through libvips), M6 done (writer: create, rewrite,
incremental), M8 done (CJK reading), M9 done (merge and split),
M10 done (attachments), M11 done (forms), M12 P4a done (signature
shells: parse, ByteRange digest, placeholders). Mmap file sources
landed before M6 (`source.nim`: `PdfSource`, `openMappedDoc`,
`openPdfPasswordFile`).

Scope: full Nim PDF reader and writer in `src/opengraphics/pdf/`,
stdlib plus `zlib`, `checksums`, `nimcypher`, `harfbuzz`. Linearized
PDF reads as a plain file (no fast-web-view optimization). XRef
streams and object streams are v1 scope (needed for modern files);
JBIG2 and CCITTFax decode stay passthrough.

## Format facts

* Content streams are sequences of operands plus operators
  (`BT /F1 12 Tf 72 720 Td (Hi) Tj ET`). Operands reuse COS value
  syntax; operators are bare keywords. Inline images use
  `BI dict ID <raw bytes> EI` with byte-accurate scanning.
* A page concatenates `/Contents` (single stream or array, each
  filter-decoded), inherits `/Resources` and `/MediaBox` from the page
  tree, and positions text through CTM x text matrix x font size.
* Text bytes map to Unicode via `/ToUnicode` CMaps first, then
  `/Encoding` (WinAnsi, MacRoman, Differences), then glyph shaping via
  embedded font programs.
* Encryption (`/Encrypt` dict, V 1/2/4/5) wraps all streams and strings;
  per-object keys derive from user/owner passwords via MD5 (V<5) or
  SHA-256 (V5). Crypt must land before text extraction is useful on
  real-world files.
* Fonts: simple fonts (Type1, TrueType, Type3) and composite fonts
  (Type0 with CIDFont + CMap). Shaping and subsetting go through the
  `harfbuzz` package (`hb_blob` from embedded FontFile bytes, then
  face, font, buffer, shape). System-font fallback is out of scope.

## Modules (`src/opengraphics/pdf/`)

* `types.nim`: `PdfError`, `PdfLimits`, `PageBox`, `defaultPdfLimits()`.
  DONE.
* `lexer.nim`: byte lexer, `pdfFail`, whitespace/comment skipping. DONE.
* `cos.nim`: `CosObj` (null bool int float name str array dict ref
  stream), value/indirect/stream-body parsing. DONE.
* `xref.nim`: classic tables plus `/Prev` incremental chains,
  newest-wins. DONE.
* `docmodel.nim`: `PdfDoc`, resolve cache with cycle guard, catalog,
  page tree, `pageBoxes`. DONE.
* `filters.nim`: Flate (zlib package) plus predictors, LZW, ASCII85,
  ASCIIHex, RunLength, `decodeChain`, `decodeCosStream`, DCT/JPX/JBIG2/
  CCITT passthrough. DONE.
* `document.nim`: `openPdf` / `readPdfBytes`. DONE.
* `content.nim`: `ContentOp` (name plus `CosObj` operands),
  `parseContentStream`, inline-image byte scanning. M3a.
* `gstate.nim`: CTM stack (`q/Q/cm`), text matrices (`Tm/Td/T*/BT/ET`),
  font selection (`Tf`), resource inheritance, `pageContentStream`
  concatenation, `walkPage`. M3a.
* `crypt.nim`: V1/2/4 RC4 (nimcypher, done) plus V4/5 AES (nimcypher
  `algos/aes`, CBC mode to verify), MD5 (`checksums`) and SHA-256 key
  derivation, auth, per-object decrypt hook in resolve. M4.
* `text.nim`: text-showing ops with positioned `TextRun`s
  (string, x, y, size, font). M3b.
* `cmap.nim`: ToUnicode bfchar/bfrange parser, WinAnsi/MacRoman tables,
  Differences arrays, Widths. M3b.
* `shape.nim`: harfbuzz wiring (blob from FontFile streams, face, font,
  shape buffer, subset for the writer). M3b.
* `images.nim`: Image XObject decode, color spaces (Device, Indexed,
  ICCBased, Separation fallback), Masks/SMask, `pageImages`. M5.
* `write.nim`: create, rewrite, incremental update with `/Prev`;
  re-flate via `deflateEncode`. M6. DONE: `writeCos` canonical
  serializer, `PdfBuilder` (catalog 1, pages 2), `rewritePdf`
  (numbers preserved, optional reflate, DCT/JPX/JBIG2/CCITT untouched),
  `beginUpdate`/`updateObject`/`finishUpdate` (contiguous xref runs,
  /ID preserved); encrypted input rejected loudly.
* `fontembed.nim`: writer-side font pipeline on HarfBuzz
  (`ShapedFont` cache shared with `shape.nim`, `measureText`,
  `subsetFont` with hinting kept, `embedFont` with /Widths plus
  /ToUnicode plus /FontFile2-linked descriptor, `drawTextLine`,
  `wrapText` with float epsilon, `FontUse` collect plus
  `finalizeFonts` before `buildPdf`, `fontResources`). DONE:
  `t_pdf_fontembed` (12 cases: measure sanity, WinAnsi map, noteUse
  rejection, wrap breaks, subset keeps glyphs, full-DejaVu subset
  under 50K, embed round-trip, Widths range, determinism, empty
  rejections); `example_pdf_write` gains an embedded DejaVu page
  (7.8K file round-trips both pages).
  CID-keyed Type0 DONE (`CidFontUse` plus `noteCidUse` plus
  `drawCidLine` plus `embedCidFont` plus `finalizeFonts` overload):
  lines shape through HarfBuzz and show as 2-byte Identity-H CIDs in
  a Type0 font (CIDFontType2/FontFile2 for TrueType,
  CIDFontType0/FontFile3-/OpenType for CFF, variable axes pinned,
  CFF2 downgraded), with /CIDToGIDMap, compact /W and chunked
  /ToUnicode, so full Unicode plus emoji round-trips through our own
  reader with zero reader changes. `t_pdf_fontembed` gains 12 CID
  cases (Greek/Cyrillic/symbol plus CJK plus CBDT-emoji round-trips,
  fi-ligature ToUnicode, kern-driven TJ, structure pins,
  determinism, missing-glyph and empty-use rejections);
  `tests/data/fonts/` vendors two micro-subsets with origin notes
  (CJK CFF OTF 3.5K, CBDT emoji 7.8K); `example_pdf_write` gains a
  CJK page validated by poppler (`CID Type 0C (OT) Identity-H`) and
  Ghostscript extraction. SVG-in-OpenType color fails loudly
  (no HarfBuzz subset support upstream); split-cluster scripts may
  duplicate a mark on extraction (Chrome parity), rendering is exact.
* `doctext.nim`: `PageText`/`DocumentText` (runs, y-grouped lines,
  gap-plus-indent blocks, `text()` dumps), stdlib-only exact
  `searchText` with run-backed hits; `t_pdf_doctext` (10 cases
  incl. the 500kB real-world fixture); `examples/example_pdf_search.nim`
  (exact plus caller-side openparser fuzzy, no new dependency).
* `sheet.nim`: `SheetPage` rows (`classifyBlock`: heading, paragraph,
  list item, caption, other against the page body-size mode) plus
  `PdfTable` detection (`detectTables`: gutter-backed column edges,
  multi-edge seed bands, wrap attach, endpoint strip, headers split
  only when the first band is visibly larger; member lines leave
  `rows`). `t_pdf_sheet` (synthetic 3x3 grid with wrap plus empty
  cell, plain-page and empty-page negatives, 500kB fixture pin of
  the page-1 table); `examples/example_pdf_sheet.nim` prints rows
  and tables. Whitespace grid only: no ruling lines, no spans,
  narrow gutters and dense pitches stay paragraphs.
* `pdf.nim`: public re-export hub. DONE, extended per milestone.
* `merge.nim`: `pageRefs`, `copyPage` (donor objects renumbered into
  the builder), `extractPages`, `mergePdfs`. M9.
* `attach.nim`: `FileAttachment`, `embeddedFiles`, `embedFile`
  (builder), `embedFileUpdate` (incremental). M10.
* `forms.nim`: `FormField` (name, label, kind, value, default,
  options, flags, font, widgets), `formFields`, `fieldNames`,
  `getField`, `fillText` (rune-aware MaxLen), `setCheck`,
  `selectRadio`, `selectChoice` (export values in /V),
  `selectChoices` (multi-select /V plus sorted /I), `resetFields`
  (per-field /DV restore), fill-time /AP appearances (text/choice
  streams, button state ensuring; comb fields stay viewer-rendered),
  `flattenFields` (text stamped multiline with fit-shrink, ticks and
  dots, tree pruned; signature, button and unknown fields fail
  loudly). M11 plus F0-F4. Comb dividers, /Q alignment, and
  width-shrink auto-size stay viewer-side (need font metrics).
* `write.nim` revisions keep base generations (gen+1 broke strict
  third-party xref resolution; fixed with F3, pinned in
  `t_pdf_write`).
* `sign.nim`: `DocSignature`, `docSignatures`, `verifyByteRangeHash`
  (SHA-256 over the signed ranges), `addSignaturePlaceholder`
  (unsigned shell with patched ByteRange). M12 P4a. CMS/PKCS#7
  build and verify plus TSA/DSS stay P4b (needs a CMS dependency).

## Milestones

* M0 crypto prereqs: RC4 in nimcypher with RFC vectors. DONE.
* M1 core: lexer, cos, xref, docmodel, document, page boxes. DONE.
* M2 filters: Flate, predictors, LZW, ASCII85/85Hex, RunLength,
  chains, passthroughs, `t_pdf_filters` (12 cases). DONE.
* M3a content parse (next): `content.nim`, `gstate.nim`,
  `t_pdf_content.nim`, vendored fixtures under `tests/data/pdf/`.
* M4 crypt: `crypt.nim`, encrypted fixtures (user plus owner,
  password `opengraphics`), decrypt hook in resolve. DONE: V1/V2 RC4,
  V4 AESV2/RC4 crypt filters, V5 R6 AES-256; fixtures `m4_rc4.pdf`,
  `m4_aes.pdf`,   `m4_r6.pdf` plus `t_pdf_crypt` (13 cases).
  `readPdfBytes`/`openPdf` take an optional password;
  `openPdfPassword` flags encrypted files. Key derivation (50x MD5
  strengthening, R6 owner U-mixing) cross-checked against qpdf
  sources plus an independent hashlib script.
* M3b text: `text.nim`, `cmap.nim`, `shape.nim` (harfbuzz),
  `extractText` with positions, CMap vectors, shaping smoke test on an
  embedded TrueType font. DONE: ToUnicode bfchar/bfrange (single plus
  array, surrogates), WinAnsi/MacRoman tables, Differences with a
  common-name table plus uni patterns, positioned runs (Tj/TJ/quotes,
  Tm-only advance), Widths/DW/W, `shapeText` at 1000upm plus
  `loadFontBytes`; fixture `m3b_text.pdf` (WinAnsi TJ kerning, subset
  DejaVuSans with ToUnicode) plus `t_pdf_text` (17 cases). Harfbuzz is
  now a package dependency (editable install from the sibling
  checkout). Horizontal writing only at M3b time (vertical landed
  in M8); no-Encoding simple fonts decode ASCII only above the low
  range.
* M5 images: `images.nim`, `pageImages`, fixture coverage per color
  space. DONE: `images.nim` (dict parsing, sample unpacking with
  /Decode, Indexed/ICCBased/Separation/Cal spaces, stencil masks) plus
  `vipsimg.nim` (hard libvips dependency, full color pipeline:
  DCT/JPX decode, DeviceCMYK to sRGB, ICC apply, SMask and color-key
  alpha); fixture `m5_images.pdf` plus `t_pdf_images` (12 cases). Lab
  and CCITT/JBIG2 stay loud errors. Needs system libvips
  (pkg-config vips).
* M6 writer: `write.nim`, round-trip tests (read, rewrite, re-read),  incremental-update test via `/Prev`. DONE: `t_pdf_write`
  (11 cases: serializer round-trips, builder blank/text pages,
  rewrite of assembled plus m3b/m5 fixtures, reflate normalization,
  incremental page add, encrypted rejection); `examples/
  example_pdf_write.nim` verified (build, rewrite, positioned text).
  Cosmetic quirk (not a file bug): poppler `pdffonts` prints
  `xref num ... not found` on files whose page /Resources hold a
  direct (inline) font dict, as the hand-rolled Helvetica page does;
  pdfinfo, Ghostscript render/extract and our own reader are all
  happy, and indirect dicts stay silent.
* M8 CJK reading: composite-font fallback chain plus generated
  ordering tables. DONE: token-stream CMap parser (bfchar/bfrange in
  any layout, cidchar/cidrange, codespace ranges), `cjkmaps.nim`
  (Japan1/GB1/CNS1/Korea1 from Adobe CMap resources via
  `tests/gen_cjk_tables.nim`, committed as `cjkdata.nim` with the
  Adobe notice), predefined-encoding code maps plus direct UCS2
  gap-fill, embedded-sfnt cmap fallback with CIDToGIDMap, indirect
  DescendantFonts arrays, WMode 1 advances (DW2/W2 defaults
  [880 -1000]) with column grouping in doctext; fixture `m8_cjk.pdf`
  (Identity/RKSJ/no-ToUnicode/vertical/packed-ToUnicode/sfnt pages)
  plus table unit tests and a fileExists-gated pin on
  `tests/data/pdf/525J-001.pdf` (InDesign CS_J, 21 pages: 3 FFFD in
  53KB, all 1pt ornaments). CFF-charset names deliberately unused
  (CID-keyed CFF carries no per-glyph names, proven on the file);
  supplement drift and 1990/2004 variant ties resolve documented
  first-wins with CJK-unified preference. Sheet tables stay
  horizontal-only; vertical text extracts as column lines.
* M7 deferred: annotations, tagged PDF, patterns,
  shadings, JBIG2/CCITTFax decode. (Forms and signature shells
  landed separately as M11 and M12 P4a.)
* M9 merge and split: `merge.nim` plus `adoptPage` in `write.nim`,
  XRef-stream (`/W`, `/Index`, `/Prev`) and object-stream (`/ObjStm`)
  reads in `xref.nim`/`docmodel.nim`. DONE: `t_pdf_merge` (10 cases),
  `examples/example_pdf_merge.nim`.
* M10 attachments: `attach.nim`, catalog `/Names /EmbeddedFiles`,
  `t_pdf_attach` (8 cases), `examples/example_pdf_attach.nim`. DONE.
* M11 forms: `forms.nim` (see Modules), `t_pdf_forms`,
  `examples/example_pdf_forms.nim`. DONE.
* M12 signatures P4a: `sign.nim` (see Modules), `t_pdf_sign`
  (10 cases), `examples/example_pdf_sign.nim`. DONE. P4b (CMS
  build/verify, TSA/DSS, document timestamps) is scoped but
  unstarted.

## Tests

* `t_pdf_cos.nim` (7 cases), `t_pdf_xref.nim` (9 cases),
  `t_pdf_filters.nim` (12 cases). All green.
* `t_pdf_merge.nim` (10 cases), `t_pdf_attach.nim` (8 cases),
  `t_pdf_forms.nim`, `t_pdf_sign.nim` (10 cases). All green.
* `t_pdf_content.nim` (M3a): op tokenizing, inline-image scanning,
  `cm` concat math, `Tf` resolution, multi-`/Contents` concat.
* Fixtures under `tests/data/pdf/` (vendored real files, each with
  origin plus checksum note in the test file): Flate text page,
  multi-page plus incremental update, LZW/ASCII85 streams, encrypted
  pair (M4), image color spaces (M5). Hand-built strings stay for
  invalid-input and edge vectors.
* Every milestone ends with `clue test` (all suites) plus `clue check`
  on the hub.

## Explicit non-goals (v1)

JBIG2/CCITTFax decode (passthrough only), annotation rendering,
CMS/PKCS#7 signature build and verify, TSA timestamps, DSS revocation
data, tagged-PDF structure, pattern/shading rendering,
system-font fallback for shaping, linearized fast-web-view writes.
