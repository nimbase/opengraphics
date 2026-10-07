# AI vector plan

Status: approved for implementation.
Toolchain: clue for dependencies, builds, and tests.
Scope: modern PDF-compatible `.ai` plus legacy EPS container support.
PostScript interpreter: deferred.
UI work: excluded.

## Locked scope

- Primary target is modern PDF-compatible `.ai` from Illustrator 9 onward.
- Include legacy EPS-based `.ai` container support.
- Do not implement a general PostScript interpreter now.
- Build a new programmatic vector model in `opengraphics`.
- Use nimble for dependencies, builds, and tests.
- Ignore VectorCraft UI, tools, panels, MCP, automation, rendering, raster effects, 3D, and unrelated crates.

## Important discovery

`opendocs` already contains the PDF foundation this work needs:

- `src/opendocs/pdf/cos.nim`
- `src/opendocs/pdf/xref.nim`
- `src/opendocs/pdf/docmodel.nim`
- `src/opendocs/pdf/filters.nim`
- `src/opendocs/pdf/content.nim`
- `src/opendocs/pdf/gstate.nim`
- `src/opendocs/pdf/write.nim`
- `src/opendocs/pdf/merge.nim`
- `src/opendocs/pdf/forms.nim`
- `src/opendocs/pdf/images.nim`
- `src/opendocs/pdf/text.nim`

Most importantly, `walkNested` in `gstate.nim` already expands Form XObjects with the correct resource frame, CTM, `/Matrix`, `/BBox`, nesting limit, and `q/cm/Q` replay behavior. Reimplementing another PDF parser inside `opengraphics/ai` would be wasteful and risky.

The current `opengraphics` AI implementation is much narrower:

- `src/opengraphics/ai/detect.nim`
- `src/opengraphics/ai/pages.nim`
- `src/opengraphics/ai/reader.nim`
- `src/opengraphics/ai/xmp.nim`
- `src/opengraphics/ai/document.nim`

It supports detection, page sizes, and metadata, but decodes no content streams and has no writer.

## Reference use

Use VectorCraft as behavior and grammar reference only:

- `crates/pdf`: PDF-compatible `.ai` behavior, artboards, layers, private-data handling, warnings, editing-data strategy.
- `crates/svg`: SVG import/export semantics, transforms, gradients, masks, patterns, text fallback, warnings.
- `crates/eps`: DSC headers, bounding boxes, EPS writing structure, interpreter fallback strategy.
- `crates/geom`: anchor/handle path model, transforms, tolerances.
- `crates/doc`: document/layer/artboard/appearance organization, without importing its editor complexity.

Use `openparser/svg` as the SVG grammar and test oracle:

- `src/openparser/svg/ast.nim`
- `src/openparser/svg/types.nim`
- `src/openparser/svg/path.nim`
- `src/openparser/svg/parser.nim`
- `src/openparser/svg/serializer.nim`

Do not copy VectorCraft UI behavior or Adobe-owned assets.

## Proposed architecture

Create a shared vector layer:

- `src/opengraphics/vector/types.nim`
  - Points, rectangles, affine transforms.
  - Paths, subpaths, anchors/handles, fill rules.
  - Paints: none, solid, linear gradient, radial gradient, pattern reference.
  - Strokes: width, caps, joins, miters, dashes.
  - Groups, layers, pages/artboards, placed images, text placeholders.
  - Limits, warnings, loss ledger.
- `src/opengraphics/vector/path.nim`
  - Path construction, validation, normalization.
  - Smooth/corner classification with an explicit tolerance.
  - Canonical document coordinate system.
- `src/opengraphics/vector/paint.nim`
  - RGB, gray, CMYK, spot/tint representation.
  - Gradient stops, transforms, spread behavior.
- `src/opengraphics/vector/svg.nim`
  - Bridge between the new model and `openparser/svg`.
  - Preserve unsupported SVG features as warnings, not silent drops.

Extend the AI layer:

- `src/opengraphics/ai/pdfcompat.nim`
  - Open modern `.ai` through `opendocs/pdf`.
  - Extract page boxes, XMP, AI markers, and private-data presence.
  - Preserve unknown/private streams for byte-preserving operations.
- `src/opengraphics/ai/content.nim`
  - Convert `WalkedOp` sequences into the new vector model.
  - Handle CTM, resource frames, nested forms, clipping, fills, strokes, gradients, images, and text policy.
- `src/opengraphics/ai/legacy.nim`
  - Bounded legacy EPS/`.ai` container reader.
  - DSC metadata, bounding boxes, version markers, preview detection.
  - Refuse arbitrary PostScript programs with a named error.
- `src/opengraphics/ai/write.nim`
  - Write fresh PDF-compatible `.ai`.
  - Report approximations and missing native edit data.
  - Preserve original private data only where it remains valid.

Use one canonical coordinate convention, preferably document points with y-down to match SVG and VectorCraft geometry. Convert PDF y-up coordinates once at the import/export boundary.

## Phase 0: feasibility and toolchain

1. Declare `opendocs` and `openparser` in `opengraphics.nimble`.
   `opendocs` and `openparser` resolve through clue develop mode to the
   local checkouts, so the unpushed `opendocs` M7 `walkNested` API is
   available. Do not run `clue install`; the requirement lines are enough.
2. Keep clue-based testing:
   - `clue test`
3. Keep `.github/workflows/test.yml` on `test_clue.yml`.
4. Carry forward OS-specific system libraries:
   - Linux: `libvips-dev`.
   - macOS: Homebrew `vips`.
   - Windows: MSYS2 UCRT64 packages, so Nim and `pkg-config` share a
     coherent prefix.
5. Spike:
   - Open a synthetic PDF-compatible `.ai` with `opendocs`. DONE:
     `src/opengraphics/ai/pdfcompat.nim` plus `tests/t_ai_pdfcompat.nim`.
   - Walk one nested content stream. DONE: operators arrive with resource
     frame, CTM, form-box info, and nesting depth via `walkNested`.
   - Extract one rectangle with paint. DONE: `rg`/`re`/`f` sequence verified.
   - Write a minimal PDF and reread it. OPEN: writer lands in Phase 4.
   - Feasibility verdict: the `opendocs` granular path (`types`, `docmodel`,
     `gstate`) compiles under clue develop mode with no HarfBuzz/libvips
     involvement. `walkNested` exists only in the local `opendocs`
     checkout (M7, unpushed); CI and registry installs will lack it until
     `opendocs` main is pushed. That push is the one cross-repo gate left.

Acceptance:

- `opengraphics.nimble` declares `opendocs` and `openparser`.
- `clue test` runs the existing suite.
- CI installs the required native libraries on all selected runners.

## Phase 1: vector model and SVG bridge

Status: implemented (`vector/types.nim`, `vector/path.nim`, `vector/svg.nim`, `vector/svgexport.nim`; tests `t_vector_model`, `t_vector_svg`).

Implement:

- Anchor-based paths.
- Affine transforms.
- Solid paints and strokes.
- Groups and layers.
- Supported SVG shapes, paths, transforms, viewBox handling.
- Explicit warnings for filters, animation, scripting, and unsupported paint features.

Tests:

- `tests/t_vector_model.nim`
- `tests/t_vector_svg.nim`
- Model-to-SVG-to-model semantic round trips.
- Transform composition and tolerance tests.
- Negative tests for malformed path data and unsupported constructs.

Use `openparser/svg` behavior as the grammar oracle, but keep the new model independent from the SVG AST.

## Phase 2: modern `.ai` content extraction

Status: implemented (`ai/content.nim` `readAiVectors`/`foldPage`; test `t_ai_vector`).

Implement:

- Page-to-artboard mapping.
- Path construction operators.
- Fill and stroke operators.
- Graphics-state and CTM handling.
- Nested Form XObjects through `walkNested`.
- Clipping groups.
- Solid RGB/gray/CMYK paints.
- Linear and radial gradients.
- Placed images as blobs or references.
- Text as extracted runs, outlines, or an explicitly deferred category.

Tests:

- `tests/t_ai_vector.nim`
- Synthetic PDF-compatible `.ai` fixtures with nested forms.
- Resource shadowing tests.
- CTM replay tests.
- Gradient, clipping, image, and text-policy tests.
- Negative tests for encrypted files, missing compatibility, xref failures, and PGF-only files.

## Phase 3: legacy EPS container support

Status: implemented (`ai/legacy.nim`; test `t_ai_legacy`).

Implement only:

- `%!PS-Adobe` detection.
- DSC header parsing.
- `%%BoundingBox` and `%%HiResBoundingBox`.
- `%AI5_FileFormat` version extraction.
- Preview-section detection and metadata.
- A clear refusal taxonomy for executable PostScript content.

Tests:

- `tests/t_ai_legacy.nim`
- Synthetic legacy `.ai` and EPS fixtures.
- Bounding-box precedence tests.
- Preview-present versus preview-absent tests.
- Arbitrary-program refusal tests.

No general interpreter lands in this phase.

## Phase 4: PDF-compatible `.ai` writer

Status: implemented (`ai/write.nim` `writeAi`; tests `t_ai_write`, `t_ai_readme`).

Implement:

- Fresh document builder for PDF-compatible `.ai`.
- One PDF page per artboard.
- Content-stream generation from the vector model.
- Compression controls for readable test output.
- Document metadata and XMP support.
- AI compatibility markers.
- `AiWriteReport` with warnings and preserved-data status.

Tests:

- `tests/t_ai_write.nim`
- Writer output reread through the new reader.
- Semantic model comparison, not merely successful parsing.
- Marker, page-count, artboard-size, paint, and transform checks.
- Unknown/private-data preservation tests for metadata-only rewrites.
- Negative tests for unsupported paint/effect constructs.

## Illustrator round-trip caution

There is an important unresolved risk.

VectorCraft deliberately treats Adobe native `.ai` private data as out of scope. It achieves `.ai` compatibility through PDF content plus its own editing payload. Adobe PGF remains proprietary and undocumented.

Therefore, the honest initial writer guarantee should be:

- Valid PDF-compatible `.ai`.
- Correct artboards and supported vector content.
- Successful self-read/self-write semantic round trip.
- Manual Illustrator-open validation for an agreed fixture set.

It should not initially promise that Illustrator will treat every generated file as fully native, editable artwork with layers, effects, and private state intact. In particular, preserving stale PGF bytes after editing artwork could make Illustrator show different state than the new PDF content. The implementation must either:

1. Preserve private data only for byte-preserving/metadata-only operations; or
2. Mark edited output as lacking refreshed native edit data and warn accordingly.

If fully native Illustrator editability is mandatory, that requires a separate PGF research track and Illustrator validation gate.

## Proposed verification

For every phase:

- `clue test`
- New focused tests named above.
- Synthetic fixtures preferred.
- Optional user-created Illustrator fixtures with known sizes and no licensed Adobe assets.
- Cross-check SVG behavior against `openparser/svg`.
- Cross-check PDF behavior against `opendocs`.
- Consult VectorCraft only for format and behavior questions, especially:
  - `cargo test -p vectorcraft-svg`
  - `cargo test -p vectorcraft-eps`
  - `cargo test -p vectorcraft-pdf`
