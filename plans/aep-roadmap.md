# AEP roadmap

Status: v1 (inventory), v2 (static values), v3 (`lhd3`/`ldat`
keyframes), and v4 (orientation) done and tested. Fixture
`tests/data/01.aep` pinned (75,748 bytes, `RIFX` + `Egg!`, trailing
XMP at offset 71,518) and is fully static: no `LIST tdbs` has a
`LIST list` child or the animated byte set (the 14 `LIST list` in the
file are `Gide` guide lists with count 0 plus one `LRdr` reader list,
none inside `tdbs`), so keyframe decoding is covered by synthetic
tests only. Real animated data still wanted: a fixture with keyframed
properties for validating v3 against real bytes.
Scope decisions: internal spec-compliant RIFX container inside
`src/opengraphics/aep/` (no `riff` dependency), read-only v1 is project
inventory only, `cdat` static values and keyframes deferred, writer out of
scope.

Spec source: `plans/aep-spec.md` (fetched from
`hunger-zh/lottie-docs`, `docs/aep.md`).

## Format facts

* Container is `RIFX` (big endian) with form ID `Egg!`. Chunk layout is
  FourCC + BE `uint32` size + data, word aligned (odd sizes pad one byte,
  pad byte not counted in size).
* Top level of the fixture: `svap/head/nhed/nnhd/adfr/LIST Pefl/qtlg/
  LIST gpuG/LIST sfnm/mrid/acer/LIST CPPl/cpid/dwga/pcms/Utf8/PwCs/.../
  LIST ExEn/LIST Fold (66,982 bytes)/wsns/wsnm/.../LIST LSIf/LIST LRdr/
  LIST PTRE`, then trailing XMP XML.
* `Fold` holds `fdta`, one large `LIST Item`, `LIST FEE `, preview `fips`
  blocks. Items route by `idta` type: `1` folder (`LIST Sfdr`), `4` comp
  (`cdta` plus `LIST Layr` plus view layers `DLay/CLay/SLay/SecL` plus
  `CIF0/CIF2/CIF3`), `7` footage (`LIST Pin ` with `sspc`, `opti`,
  `LIST Als2/alas`, `LIST CLRS`).
* Layers (`LIST Layr`): `ldta` (ID, type 0..4, source/parent/matte IDs,
  times, flags), `Utf8` name, optional `cmta`, `LIST tdgp` groups.
  AE23 `ldta` has 4 extra trailing zero bytes, so decode by offset.
* Properties: `tdmn` match name introduces each property, groups end at
  `ADBE Group End`. Full value decoding (`tdb4/cdat/list/lhd3/ldat`) is
  not v1.
* Hazard cases: `tdsn/fnam/pdnm` wrap a `Utf8` child, `LIST btdk` is COS
  encoded (never recurse as RIFF), trailing XMP after the root chunk is
  opaque, `-_0_/-` means empty name, `FFFF` end time means comp duration.

## v1 modules (`src/opengraphics/aep/`)

* `types.nim`: `AepError`, `ItemKind` (Folder=1, Comp=4, Footage=7),
  `LayerKind` (Asset=0, Light=1, Camera=2, Text=3, Shape=4), `AepLimits`
  (`maxChunks`, `maxDepth`, `maxItems`, `maxLayers`, `maxChunkBytes`,
  `maxNameBytes`), `defaultAepLimits()`, `CompInfo`, `LayerInfo`,
  `FootageInfo`, `AepDocument`.
* `rifx.nim`: internal container walk (`RifxChunk` tree with id, listType,
  data slice, children), exact parent bounds, odd size padding, depth and
  count caps before allocation, unknown chunks preserved as raw bytes,
  `btdk` stored opaque, XMP tail captured as string.
* `reader.nim`: leaf decoders (BE `u16/s16/u32/f32/f64`, `string0`, NUL
  stripped match names, flag bit helper, time to frames helper with
  `cdta.time_scale` plus `ldta.start_time`).
* `detect.nim`: `RIFX` + `Egg!` check, `ExEn` expression language, XMP
  presence flag. Honest errors for `RIFF`, wrong form, truncation.
* `items.nim`: `Fold/Item/Sfdr` walk, `idta` decode, name and comment
  extraction, folder/comp/footage routing.
* `comp.nim`: `cdta` header fields by offset (width, height, time scale,
  framerate, in/out/duration).
* `layers.nim`: `ldta` decode by offset, layer index by comp, solid/null/
  adjustment flag separation.
* `props.nim`: match name scanner only (`tdmn` sequence to group end).
  No value decoding in v1.
* `document.nim`: `AepDocument`, `openAep` / `readAepBytes`, same
  opts/limits signature shape as PSD/AI.
* `aep.nim`: public re-export hub, mirroring `psd.nim` and `ai.nim`.

## v1 tests

* `tests/t_aep_rifx.nim`: hand built minimal `RIFX` bytes, no external
  lib (valid root, odd size padding, nested `LIST`, truncation error,
  depth cap error, `btdk` opacity).
* `tests/t_aep_detect.nim`: fixture magic accepted, `RIFF` rejected,
  wrong form rejected, garbage rejected.
* `tests/t_aep_inventory.nim`: synthetic `Fold/Item/cdta/ldta/idta` plus
  pinned `tests/data/01.aep` counts (top level IDs, comp IDs and dims,
  layer IDs/types/sources).
* `examples/example_aep.nim`: open fixture, print comps, layers, footage
  paths. Build with `clue build examples/example_aep.nim`, run with
  `clue test`.

## Explicit v1 non-goals

`cdat` static values, `tdb4` typing, animated keyframes
(`list/lhd3/ldat` variants), bezier `shap/shph`, gradient XML, COS text
`btdk` contents, effect `pard/pdnm` detail, essential graphics detail,
render queue detail, any writer.

## After v1

* v2 done: `tdb4` typing plus `cdat` statics (`props.nim`: `parseTdb4`,
  `parseTdbs`, `groupProperties`, `childGroups`, `findGroup`, `getProp`;
  lazy per layer via `layerTransform` / `layerProperties` on the stored
  comp node; animated properties marked, values empty).
* v3 done: `lhd3`/`ldat` keyframes (`props.nim`: `parseLhd3`,
  `parseKeyframes` for multi-dimensional, position with spatial
  tangents, color ARGB, and no-value layouts; expected item size checked
  against the `tdb4` kind so misaligned data raises; integer/unknown
  animated kinds raise as unsupported; `PropValue.keyframes`, empty when
  the animated byte is set without a `LIST list`).
* v4 done: orientation (`types.nim`: `OrientationInfo` with match name,
  display name, `staticValue` triplet, timeless `frames` triplets;
  `props.nim`: `parseOtst`, `orientationsIn`, `collectGroups`;
  `document.nim`: `layerOrientations` / `layerOrientation`; fixture
  layer 13 pinned: `ADBE Orientation` static `[0,0,0]`, one frame
  `[0,0,0]`, placeholder `tdsn` empties the display name).
* Next: effect groups (`dropShadow/enabled`-style `tdmn` + `LIST tdgp`,
  present in fixture Layer Styles), text (`ADBE Text Document` +
  `LIST btds`/`btgu`, `btdk` fonts), shapes (`om-s`/`omks`/`shap`/`shph`
  bezier), gradient colors (`GCst`/`GCky` + XML), markers
  (`mrst`/`mrky`/`Nmrd`), essential graphics. None of these have
  fixture data except effects and text, so new fixtures are wanted.
* Future: writer or remux support (raw byte preservation in v1 keeps
  this option open, no commitment now).
