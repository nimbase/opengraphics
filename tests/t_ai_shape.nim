## Shaping module tests: advances, ligatures, kerning, outlines.
##
## Expected values come from `hb-shape` 14.2.1 on the vendored micro
## font, so they pin HarfBuzz behavior, not just ours:
##   Hi  -> [gid41=0+1540|gid74=1+569]
##   fi  -> [gid128=0+1290]
##   AV  -> [gid34=0+1270|gid55=1+1401]

import std/math
import std/options
import std/os
import unittest
import ../src/opengraphics/ai/shape
import ../src/opengraphics/vector

const FontPath = "tests" / "data" / "fonts" / "ai-micro.ttf"

proc fontBytes(): string = readFile(FontPath)

proc close(a, b: float64): bool = abs(a - b) < 1e-9

test "shapes latin with advances and clusters":
  let shaped = shapeText(fontBytes(), "Hi")
  check shaped.upem == 2048
  check shaped.glyphs.len == 2
  check shaped.glyphs[0].glyphId == 41
  check shaped.glyphs[0].cluster == 0
  check close(shaped.glyphs[0].xAdvance, 1540.0)
  check shaped.glyphs[1].glyphId == 74
  check shaped.glyphs[1].cluster == 1
  check close(shaped.glyphs[1].xAdvance, 569.0)

test "fi ligates to one glyph":
  let shaped = shapeText(fontBytes(), "fi")
  check shaped.glyphs.len == 1
  check shaped.glyphs[0].glyphId == 128
  check shaped.glyphs[0].cluster == 0
  check close(shaped.glyphs[0].xAdvance, 1290.0)

test "kerned advances come from the font, not the widths":
  let shaped = shapeText(fontBytes(), "AV")
  check shaped.glyphs.len == 2
  check close(shaped.glyphs[0].xAdvance, 1270.0)
  check close(shaped.glyphs[1].xAdvance, 1401.0)

test "empty text shapes to nothing":
  check shapeText(fontBytes(), "").glyphs.len == 0

test "empty and garbage programs fail loudly":
  expect(ShapeError):
    discard shapeText("", "Hi")
  expect(ShapeError):
    discard shapeText("not a font program", "Hi")

test "glyph outlines trace real contours":
  let ol = glyphOutline(fontBytes(), 41) # H
  check ol.subs.len > 0
  let b = pathBounds(ol)
  check b.x0 >= 0.0 and b.x1 <= 2048.0
  check b.y1 - b.y0 > 1000.0 # cap height scale, y-up font units
  var segs = 0
  for s in ol.subs: segs += segmentCount(s)
  check segs > 4 # H is not a degenerate sliver

test "whitespace outlines to nothing":
  let sp = shapeText(fontBytes(), " ")
  check sp.glyphs.len == 1
  check glyphOutline(fontBytes(), sp.glyphs[0].glyphId).subs.len == 0

test "baked outlines land in run-local points, y-down":
  var sf = openShapedFont(fontBytes())
  defer: close(sf)
  var shaped = ShapedText()
  shapeInto(sf, "Hi", shaped)
  let glyphs = toVecGlyphs(shaped, 12.0)
  check glyphs.len == 2
  # 1540/2048 of 12pt advances the pen before the second glyph
  check close(glyphs[1].dx, 1540.0 / 2048.0 * 12.0)
  let ol = bakeOutline(sf, shaped.glyphs, 12.0)
  check ol.isSome
  let b = pathBounds(ol.get())
  check b.x0 >= 0.0
  check b.y1 - b.y0 > 5.0
  check b.y1 - b.y0 < 20.0

test "whitespace-only runs bake to none":
  var sf = openShapedFont(fontBytes())
  defer: close(sf)
  var shaped = ShapedText()
  shapeInto(sf, " ", shaped)
  check bakeOutline(sf, shaped.glyphs, 12.0).isNone
