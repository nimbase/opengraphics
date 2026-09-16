# PSD roadmap

Status: read-only MVP done and tested (16 suites, real file `tests/data/01.psd` pinned).
Constraints: PSD only (no PSB), 8-bit, RGB/Grayscale, Raw + RLE + ZIP (zlib).

## Done

* Header, color-mode passthrough, generic `8BIM` resource blocks
* Resolution / thumbnail / ICC accessors, `hasThumbnail`, `saveThumbnailJpeg`
* Layer records (`luni`, `lyid`, `lsct`/`lsdk`), group tree builder, `flattenTree`
* Raw + RLE + ZIP channel decode (incl. ZIP prediction), composite decode,
  `ImageBuf` pixel model
* `TySh` text engine data (`psd/text`: TEXT + EngineData editor text,
  font names/sizes, transform; raw preserved)
* Layer masks (`psd/mask` + `Layer.mask/maskData/maskEnabled`): 20/36-byte
  records parsed (rect, default color, relative/disabled/invert, real
  pair), user-mask channel (id -2) decoded with mask-rect dims for
  Raw/RLE/ZIP, global mask parsed; raw bytes preserved
* Stack renderer (`psd/render`: `renderDocument`, `renderToComposite`):
  20 blend modes, opacity, alpha channels, clipping to base shape,
  group opacity/visibility via the layer tree, mask application
  (incl. invert); unknown/HSL/dissolve modes fall back to normal,
  groups render pass-through. Real fixture renders ~98% identical
  to the stored composite (text effects account for the rest)
* PPM / BMP writers, `ReadOptions` skips
* Hardened for untrusted files (`Limits`: dimensions, pixel volume,
  section bytes, block counts, channel-aware composite volume; every
  length prefix checked before allocation; 6 new limit tests)
* Unknown blocks preserved as raw bytes for future write support

## Next options (ordered by value)

1. Write support: serializer reusing preserved raw bytes; read-modify-write
   round-trips that Photoshop still opens. Biggest unlock, biggest work.
2. Layer masks: DONE (parsed + decoded; vector masks still deferred
   to item 5, mask application to compositing in item 3).
3. Compositing: DONE (see above; vector-mask clipping and
   knockout/blending-ranges still deferred).
4. Format breadth: PSB, 16/32-bit, CMYK/Lab/Indexed.
   ZIP done (zlib, via `psd/zip`, same wrapped/raw fallback as PDF).
5. Semantic blocks: `TySh` done, vector slice 1 done (`vsms`/`vmsk`
   path records + `vscg`/`SoCo` fill via `psd/vector`; fixture layer 0
   pins a 4-knot rectangle + navy fill), smart objects done
   (`SoLd`/`PlLd` via `psd/smartobject` on a shared `psd/descriptor`
   engine: ids, page, type, transform corners, warp, bounds, size,
   resolution; fixture layer 1 pinned; embedded files deferred).
   Still open: `vogk`/`vstk` origination+stroke descriptors,
   adjustments, effects, vector-mask rasterization in the renderer.
6. Robustness for untrusted files: DONE (dimension / layer-count /
   section / block / channel-volume caps before allocating; libpsd
   has no such caps — malloc-only — so this is our own hardening).
7. Thumbnail decode: JPEG decoder, dependency-scale work; deferred in favor
   of 6 (payload is passthrough today).

## Suggested order

6 done, 2 done, 5 (text, vector slice 1, smart objects) done, 3 done.
Next: item 5 remainder (`vogk`/`vstk`, adjustments, effects) and
item 4 (PSB, 16/32-bit, CMYK/Lab/Indexed), then write support (1).
