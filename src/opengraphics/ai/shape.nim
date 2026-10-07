## Glyph shaping and outlines through HarfBuzz.
##
## Shapes decoded run strings (kerning, ligatures, GPOS adjustments
## included) and extracts glyph outlines as vector paths. Font scale
## is the face's units-per-em, so advances, offsets, and outline
## coordinates all read out in font units, y-up for outlines; callers
## scale by fontSize/upem and flip y for the y-down vector model.
##
## Only granular harfbuzz submodules are imported, with compile flags
## from `pkg-config harfbuzz` alone: the full `harfbuzz` hub would also
## drag `harfbuzz-subset` and `harfbuzz-icu` queries into every compile,
## which the Linux CI images do not carry. The callback warning
## suppression below is the same one the hub applies (see hb_common):
## Nim callback procs are ABI-identical but nominally distinct, which
## clang 16+ escalates without it.

{.passC: gorge("pkg-config --cflags harfbuzz").}
{.passL: gorge("pkg-config --libs harfbuzz").}
{.passC: "-Wno-incompatible-function-pointer-types".}

import std/options
import harfbuzz/hb_common
import harfbuzz/hb_blob
import harfbuzz/hb_face
import harfbuzz/hb_font
import harfbuzz/hb_buffer
import harfbuzz/hb_shape
import harfbuzz/hb_draw
import harfbuzz/hb_ot_font
import opendocs/pdf/cos
import opendocs/pdf/docmodel
import opendocs/pdf/filters
import ../vector/types
from ../vector/path import curveTo, lineTo, moveTo

export types

type
  ShapeError* = object of CatchableError

  ShapedFont* = object
    ## One open face: blob, face, and font at upem scale. `bytes` keeps
    ## the program alive because the blob does not copy. Call `close`
    ## when done; closing is idempotent and safe on a zero value.
    bytes*: string
    blob*: ptr hb_blob_t
    face*: ptr hb_face_t
    font*: ptr hb_font_t
    upem*: int

  ShapedGlyph* = object
    ## One shaped glyph. Advances and offsets are font units at the
    ## face scale (divide by `upem`, multiply by the font size for
    ## text-space points). `cluster` is the byte index into the run.
    glyphId*: int
    cluster*: int
    xAdvance*: float64
    yAdvance*: float64
    xOffset*: float64
    yOffset*: float64

  ShapedText* = object
    glyphs*: seq[ShapedGlyph]
    upem*: int

proc shapeFail(msg: string) {.noreturn.} =
  raise newException(ShapeError, msg)

proc close*(sf: var ShapedFont) =
  if sf.font != nil:
    hb_font_destroy(sf.font)
    sf.font = nil
  if sf.face != nil:
    hb_face_destroy(sf.face)
    sf.face = nil
  if sf.blob != nil:
    hb_blob_destroy(sf.blob)
    sf.blob = nil

proc openShapedFont*(fontBytes: string): ShapedFont =
  ## Open a TrueType/OpenType program for shaping and drawing.
  ## HarfBuzz cannot parse Adobe Type 1 (CFF in a bare FontFile
  ## stream is fine; Type 1 is not), so those fail here, loudly.
  if fontBytes.len == 0:
    shapeFail("cannot shape text with an empty font program")
  result.bytes = fontBytes
  result.blob = hb_blob_create(cstring(result.bytes),
    cuint(result.bytes.len), HB_MEMORY_MODE_READONLY, nil, nil)
  if result.blob == nil:
    shapeFail("HarfBuzz refused the font program")
  result.face = hb_face_create(result.blob, 0)
  result.font = hb_font_create(result.face)
  hb_ot_font_set_funcs(result.font)
  result.upem = int(hb_face_get_upem(result.face))
  if result.upem <= 0:
    close(result)
    shapeFail("font program reports no units-per-em")
  if hb_face_get_glyph_count(result.face) == 0:
    close(result)
    shapeFail("font program has no glyphs (Adobe Type 1 programs " &
      "are not supported by HarfBuzz)")
  hb_font_set_scale(result.font, cint(result.upem), cint(result.upem))

proc shapeInto*(sf: ShapedFont, text: string, shaped: var ShapedText) =
  ## Shape UTF-8 `text`, appending glyphs with positions and clusters.
  ## Direction, script, and language are guessed per buffer.
  shaped.upem = sf.upem
  let buf = hb_buffer_create()
  hb_buffer_add_utf8(buf, cstring(text), cint(text.len), 0, cint(text.len))
  hb_buffer_guess_segment_properties(buf)
  hb_shape(sf.font, buf, nil, 0)
  var nInfo: cuint = 0
  var nPos: cuint = 0
  let infos = cast[ptr UncheckedArray[hb_glyph_info_t]](
    hb_buffer_get_glyph_infos(buf, addr nInfo))
  let poss = cast[ptr UncheckedArray[hb_glyph_position_t]](
    hb_buffer_get_glyph_positions(buf, addr nPos))
  let n = min(int(nInfo), int(nPos))
  for i in 0 ..< n:
    shaped.glyphs.add(ShapedGlyph(
      glyphId: int(infos[i].codepoint),
      cluster: int(infos[i].cluster),
      xAdvance: float64(poss[i].x_advance),
      yAdvance: float64(poss[i].y_advance),
      xOffset: float64(poss[i].x_offset),
      yOffset: float64(poss[i].y_offset)))
  hb_buffer_destroy(buf)

proc shapeText*(fontBytes, text: string): ShapedText =
  ## Shape `text` with one throwaway font open. For repeated runs
  ## against one program, open once and call `shapeInto`.
  result = ShapedText()
  if text.len == 0: return
  var sf = openShapedFont(fontBytes)
  defer: close(sf)
  shapeInto(sf, text, result)

type
  OutlineCollector = object
    path*: VecPath
    sub*: VecSubPath
    hasSub*: bool

proc flushSub(c: var OutlineCollector) =
  if c.hasSub and c.sub.anchors.len > 0:
    c.path.subs.add(c.sub)
  c.sub = VecSubPath()
  c.hasSub = false

proc collectorOf(data: pointer): ptr OutlineCollector =
  cast[ptr OutlineCollector](data)

proc drawMove(dfuncs: ptr hb_draw_funcs_t, data: pointer,
    st: ptr hb_draw_state_t, x, y: cfloat,
    ud: pointer) {.cdecl.} =
  let c = collectorOf(data)
  flushSub(c[])
  c[].sub = VecSubPath()
  moveTo(c[].sub, vecPt(float64(x), float64(y)))
  c[].hasSub = true

proc drawLine(dfuncs: ptr hb_draw_funcs_t, data: pointer,
    st: ptr hb_draw_state_t, x, y: cfloat,
    ud: pointer) {.cdecl.} =
  let c = collectorOf(data)
  if not c[].hasSub:
    c[].sub = VecSubPath()
    moveTo(c[].sub, vecPt(float64(x), float64(y)))
    c[].hasSub = true
  else:
    lineTo(c[].sub, vecPt(float64(x), float64(y)))

proc drawQuadratic(dfuncs: ptr hb_draw_funcs_t, data: pointer,
    st: ptr hb_draw_state_t, cx, cy, x, y: cfloat,
    ud: pointer) {.cdecl.} =
  ## TrueType quadratics elevate to cubics: C1 = P0 + 2/3(Q-P0),
  ## C2 = P3 + 2/3(Q-P3). Exact, not an approximation.
  let c = collectorOf(data)
  if not c[].hasSub or c[].sub.anchors.len == 0:
    drawLine(dfuncs, data, st, x, y, ud)
    return
  let p0 = c[].sub.anchors[^1].p
  let q = vecPt(float64(cx), float64(cy))
  let p3 = vecPt(float64(x), float64(y))
  curveTo(c[].sub,
    vecPt(p0.x + 2.0/3.0*(q.x - p0.x), p0.y + 2.0/3.0*(q.y - p0.y)),
    vecPt(p3.x + 2.0/3.0*(q.x - p3.x), p3.y + 2.0/3.0*(q.y - p3.y)),
    p3)

proc drawCubic(dfuncs: ptr hb_draw_funcs_t, data: pointer,
    st: ptr hb_draw_state_t, c1x, c1y, c2x, c2y, x, y: cfloat,
    ud: pointer) {.cdecl.} =
  let c = collectorOf(data)
  if not c[].hasSub or c[].sub.anchors.len == 0:
    drawLine(dfuncs, data, st, x, y, ud)
    return
  curveTo(c[].sub, vecPt(float64(c1x), float64(c1y)),
    vecPt(float64(c2x), float64(c2y)), vecPt(float64(x), float64(y)))

proc drawClose(dfuncs: ptr hb_draw_funcs_t, data: pointer,
    st: ptr hb_draw_state_t, ud: pointer) {.cdecl.} =
  let c = collectorOf(data)
  if c[].hasSub:
    c[].sub.closed = true
    flushSub(c[])

proc glyphOutlineInto*(sf: ShapedFont, glyphId: int,
    path: var VecPath) =
  ## The outline of one glyph appended to `path`, in font units, y-up.
  ## Empty glyphs (spaces) append nothing; that is expected, not an error.
  var funcs = hb_draw_funcs_create()
  hb_draw_funcs_set_move_to_func(funcs, drawMove, nil, nil)
  hb_draw_funcs_set_line_to_func(funcs, drawLine, nil, nil)
  hb_draw_funcs_set_quadratic_to_func(funcs, drawQuadratic, nil, nil)
  hb_draw_funcs_set_cubic_to_func(funcs, drawCubic, nil, nil)
  hb_draw_funcs_set_close_path_func(funcs, drawClose, nil, nil)
  var c = OutlineCollector()
  hb_font_draw_glyph(sf.font, hb_codepoint_t(glyphId), funcs,
    cast[pointer](addr c))
  flushSub(c)
  for s in c.path.subs:
    if s.anchors.len > 0:
      path.subs.add(s)
  hb_draw_funcs_destroy(funcs)

proc glyphOutline*(fontBytes: string, glyphId: int): VecPath =
  ## One glyph's outline with a throwaway font open.
  result = VecPath()
  var sf = openShapedFont(fontBytes)
  defer: close(sf)
  glyphOutlineInto(sf, glyphId, result)

proc embeddedFontBytes*(fontDict: CosObj, d: var PdfDoc): string =
  ## The embedded program from a font dictionary's /FontDescriptor
  ## (/FontFile2 or /FontFile3 preferred, /FontFile last). Raises
  ## ShapeError when the font is not embedded.
  ##
  ## This mirrors opendocs `loadFontBytes` on purpose: importing that
  ## module would pull the full harfbuzz hub (including subset/icu
  ## queries) into every compile, while this module deliberately links
  ## only `pkg-config harfbuzz`.
  var desc = fontDict.dictGet("FontDescriptor")
  if desc.kind == coRef:
    desc = d.resolve(desc)
  if desc.kind != coDict:
    shapeFail("no /FontDescriptor: font is not embedded, shaping " &
      "needs an embedded program")
  for key in ["FontFile2", "FontFile3", "FontFile"]:
    var s = desc.dictGet(key)
    if s.kind == coRef:
      s = d.resolve(s)
    if s.kind == coStream:
      let raw = decodeCosStream(s)
      if raw.len == 0:
        shapeFail("empty embedded font program in /" & key)
      return raw
  shapeFail("no embedded font program (/FontFile, /FontFile2 or " &
    "/FontFile3) in /FontDescriptor")

proc bakeOutline*(sf: ShapedFont, glyphs: seq[ShapedGlyph],
    fontSize: float64): Option[VecPath] =
  ## Shaped glyphs to a run-local outline path: pen starts at the run
  ## origin, units are points, y points down. Returns none when every
  ## glyph is empty (a whitespace-only run), which the writer skips.
  if sf.upem <= 0 or fontSize <= 0.0: return none(VecPath)
  let s = fontSize / float64(sf.upem)
  var path = VecPath()
  var (penX, penY) = (0.0, 0.0)
  for g in glyphs:
    let ox = penX + g.xOffset * s
    let oy = penY - g.yOffset * s
    var local = VecPath()
    glyphOutlineInto(sf, g.glyphId, local)
    for sub in local.subs:
      if sub.anchors.len == 0: continue
      var moved = VecSubPath(closed: sub.closed)
      for a in sub.anchors:
        moved.anchors.add(VecAnchor(
          p: vecPt(ox + a.p.x * s, oy - a.p.y * s),
          hIn: vecPt(ox + a.hIn.x * s, oy - a.hIn.y * s),
          hOut: vecPt(ox + a.hOut.x * s, oy - a.hOut.y * s),
          kind: a.kind))
      path.subs.add(moved)
    penX += g.xAdvance * s
    penY += g.yAdvance * s
  if path.subs.len == 0: none(VecPath)
  else: some(path)

proc toVecGlyphs*(shaped: ShapedText, fontSize: float64): seq[VecGlyph] =
  ## Shaped glyphs to run-local model glyphs at `fontSize` points.
  if shaped.upem <= 0 or fontSize <= 0.0: return @[]
  let s = fontSize / float64(shaped.upem)
  var (penX, penY) = (0.0, 0.0)
  for g in shaped.glyphs:
    result.add(VecGlyph(glyphId: g.glyphId, cluster: g.cluster,
      dx: (penX + g.xOffset * s), dy: -(penY + g.yOffset * s),
      advance: g.xAdvance * s))
    penX += g.xAdvance * s
    penY += g.yAdvance * s
