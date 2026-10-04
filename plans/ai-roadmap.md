# AI roadmap

Status: planning done, PSD test files namespaced to `t_psd_*`.
Scope decisions: modern PDF-based `.ai` only (Illustrator 9+, year 2000
onward), read-only MVP first, v1 depth is detect + artboards + metadata.
zlib-family dependency allowed starting at v2 (content streams are
FlateDecode; AI24+ also uses zstd). v1 touches no compressed streams and
stays stdlib-only.

## Format facts

* Modern `.ai` is a valid PDF: `%PDF-1.x` header, xref, object graph,
  `%%EOF`, one PDF page per artboard. Rename to `.pdf` renders the
  flattened composite in any PDF viewer.
* Illustrator edit state lives in the proprietary, undocumented
  `/AIPrivateData` stream (PGF). PDF viewers never see it.
* Forensics needing no decompression:
  `/AIPrivateData` = native `.ai` vs `/AIPDFPrivateData` = Illustrator-saved
  `.pdf`; XMP `<illustrator:Type>Document</illustrator:Type>`; embedded
  `%!PS-Adobe-3.0` + `%AI5_FileFormat <n>` version markers.
* Legacy pre-9 `.ai` is EPS/PostScript (`%!PS-Adobe`): out of scope,
  rejected with a clear error.

## v1 modules (`src/opengraphics/ai/`)

* `types.nim`: `AiError`, `AiKind` (PdfCompatible, PdfWithoutAiData,
  EpsLegacy, Unknown), `AiLimits` (maxPages, maxScanBytes),
  `defaultAiLimits()`, `Artboard` (index, width, height, name best-effort).
* `reader.nim`: byte reader + bounded marker search (head/tail scan,
  tolerant `%PDF-` header per spec allowance for leading bytes).
* `detect.nim`: kind detection, PDF version, AI format version, private-data
  flag. Honest errors for EPS legacy and PDF-compat-off files.
* `pages.nim`: classic xref-table walk (uncompressed only) to catalog,
  `/Pages`, page `/MediaBox` dims. xref-stream-only files get a clear
  "needs v2" error, never a silent wrong answer.
* `xmp.nim`: `<?xpacket` extraction + `std/xmlparser` for title, creator,
  dates, illustrator type.
* `document.nim`: `AiDocument`, `openAi` / `readAiBytes`, same
  opts/limits signature shape as PSD.
* `ai.nim`: public re-export hub, mirroring `psd.nim`.

## v1 tests

* `tests/t_ai_detect.nim` with a synthetic minimal-PDF builder (stdlib
  only): kind matrix (native ai, Illustrator pdf, plain pdf, EPS legacy,
  garbage), version markers, compat-off file.
* `tests/t_ai_artboards.nim`: synthetic 2-page xref-table PDF with known
  MediaBoxes; XMP parse test with a canned packet.
* Fixture needed: one small real `.ai` (2 artboards, known sizes, PDF
  compat on) as `tests/data/ai_01.ai`, user-created to avoid licensing
  issues.

## Explicit v1 non-goals

Content-stream vector extraction, placed-image decoding, PGF parsing,
any writer. Writer caveat: a PDF-compatible `.ai` without PGF opens in
Illustrator only as an import, not as editable artwork, so write support
is gated on PGF research.

## After v1

* v2: add zlib package (evaluate `zlib` bindings vs pure-Nim `zippy` at
  kickoff), FlateDecode filter chain, content-stream operator parser to a
  path/fill/stroke model, placed images as raw bytes. Reuse
  `psd/pixels.nim` `ImageBuf` for raster previews.
* v3/research: PGF reverse engineering for layers, live effects, CMYK and
  spot fidelity. References: `illustrator-exporter` (Python, MIT, PGF
  round-trip with SVG rebuild plus sidecar) and
  `opendesigndev/illustrator-parser-pdfcpu` (Go+TS, PDF-layer based).
  Highest-risk track, quarantined from the documented-spec work.
* Shared core: the PDF object/xref layer built here is reusable for any
  future PDF work.
