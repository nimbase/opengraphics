## Glyph shaping and outlines through harfnim.
##
## Shapes decoded run strings (kerning, ligatures, GPOS adjustments
## included) and extracts glyph outlines as vector paths. Font scale
## is the face's units-per-em, so advances, offsets, and outline
## coordinates all read out in font units, y-up for outlines; callers
## scale by fontSize/upem and flip y for the y-down vector model.
##
## Pure Nim: no C library, no pkg-config. The default feature set
## mirrors `hb-shape` (abvm blwm calt ccmp clig curs dist kern liga
## locl mark mkmk rlig rclt); harfnim's `shape` applies only requested
## features, so shaping with an empty list would skip kerning and
## ligatures entirely.

import std/options
import harfnim/sfnt
import harfnim/font
import harfnim/buffer
import harfnim/shape
import harfnim/feature
import harfnim/tag
import harfnim/draw
import opendocs/pdf/cos
import opendocs/pdf/docmodel
import opendocs/pdf/filters
import ../vector/types
from ../vector/path import curveTo, lineTo, moveTo

export types

const DefaultShapeFeatures = ["abvm", "blwm", "calt", "ccmp", "clig",
  "curs", "dist", "kern", "liga", "locl", "mark", "mkmk", "rlig", "rclt"]
  ## Enabled unless mentioned, like `hb-shape` (see hr-shape).

type
  ShapeError* = object of CatchableError

  ShapedFont* = object
    ## One open face: parsed font plus shaper at upem scale.
    ## `bytes` keeps the program for callers; the parsed font owns its
    ## own copy. Call `close` when done; closing is idempotent and safe
    ## on a zero value.
    bytes*: string
    parsed*: SfntFont
    shaper*: ShaperFont
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
  sf.shaper = nil

proc openShapedFont*(fontBytes: string): ShapedFont =
  ## Open a TrueType/OpenType program for shaping and drawing.
  ## Adobe Type 1 programs fail here, loudly (harfnim parses
  ## TrueType/OpenType collections only).
  if fontBytes.len == 0:
    shapeFail("cannot shape text with an empty font program")
  var parsed: SfntFont
  try:
    parsed = parseFontString(fontBytes)
  except CatchableError as e:
    shapeFail("harfnim refused the font program (" & e.msg & ")")
  let upem = int(parsed.unitsPerEm)
  if upem <= 0:
    shapeFail("font program reports no units-per-em")
  if parsed.numGlyphs == 0:
    shapeFail("font program has no glyphs (Adobe Type 1 programs " &
      "are not supported by harfnim)")
  var shaper = newShaperFont(parsed)
  shaper.setScale(int32(upem))
  ShapedFont(bytes: fontBytes, parsed: parsed, shaper: shaper,
    upem: upem)

proc shapeFeatures(): seq[Feature] =
  result = newSeq[Feature](DefaultShapeFeatures.len)
  for i, t in DefaultShapeFeatures:
    result[i] = globalFeature(tagFromStr(t), 1)

proc shapeInto*(sf: ShapedFont, text: string, shaped: var ShapedText) =
  ## Shape UTF-8 `text`, appending glyphs with positions and clusters.
  ## Direction, script, and language are guessed per buffer.
  shaped.upem = sf.upem
  if text.len == 0 or sf.shaper == nil:
    return
  var buf = newBuffer()
  buf.pushStr(text)
  shape(sf.shaper, buf, shapeFeatures())
  let n = min(buf.len, min(buf.info.len, buf.pos.len))
  for i in 0 ..< n:
    shaped.glyphs.add(ShapedGlyph(
      glyphId: int(buf.info[i].glyphId),
      cluster: int(buf.info[i].cluster),
      xAdvance: float64(buf.pos[i].xAdvance),
      yAdvance: float64(buf.pos[i].yAdvance),
      xOffset: float64(buf.pos[i].xOffset),
      yOffset: float64(buf.pos[i].yOffset)))

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

proc emitMove(c: var OutlineCollector, x, y: float64) =
  flushSub(c)
  c.sub = VecSubPath()
  moveTo(c.sub, vecPt(x, y))
  c.hasSub = true

proc emitLine(c: var OutlineCollector, x, y: float64) =
  if not c.hasSub:
    c.sub = VecSubPath()
    moveTo(c.sub, vecPt(x, y))
    c.hasSub = true
  else:
    lineTo(c.sub, vecPt(x, y))

proc emitQuadratic(c: var OutlineCollector, cx, cy, x, y: float64) =
  ## TrueType quadratics elevate to cubics: C1 = P0 + 2/3(Q-P0),
  ## C2 = P3 + 2/3(Q-P3). Exact, not an approximation.
  if not c.hasSub or c.sub.anchors.len == 0:
    emitLine(c, x, y)
    return
  let p0 = c.sub.anchors[^1].p
  let q = vecPt(cx, cy)
  let p3 = vecPt(x, y)
  curveTo(c.sub,
    vecPt(p0.x + 2.0/3.0*(q.x - p0.x), p0.y + 2.0/3.0*(q.y - p0.y)),
    vecPt(p3.x + 2.0/3.0*(q.x - p3.x), p3.y + 2.0/3.0*(q.y - p3.y)),
    p3)

proc emitCubic(c: var OutlineCollector, c1x, c1y, c2x, c2y, x,
    y: float64) =
  if not c.hasSub or c.sub.anchors.len == 0:
    emitLine(c, x, y)
    return
  curveTo(c.sub, vecPt(c1x, c1y), vecPt(c2x, c2y), vecPt(x, y))

proc emitClose(c: var OutlineCollector) =
  if c.hasSub:
    c.sub.closed = true
    flushSub(c)

proc glyphOutlineInto*(sf: ShapedFont, glyphId: int,
    path: var VecPath) =
  ## The outline of one glyph appended to `path`, in font units, y-up.
  ## Empty glyphs (spaces) append nothing; that is expected, not an error.
  if sf.shaper == nil:
    return
  var c = OutlineCollector()
  let ok = sf.shaper.drawGlyph(newGlyphId(uint32(glyphId)),
    proc(op: DrawOp) {.closure.} =
      case op.kind
      of moveTo:
        emitMove(c, float64(op.to.x), float64(op.to.y))
      of lineTo:
        emitLine(c, float64(op.to.x), float64(op.to.y))
      of quadraticTo:
        emitQuadratic(c, float64(op.qCtrl.x), float64(op.qCtrl.y),
          float64(op.qTo.x), float64(op.qTo.y))
      of cubicTo:
        emitCubic(c, float64(op.c1.x), float64(op.c1.y),
          float64(op.c2.x), float64(op.c2.y), float64(op.cTo.x),
          float64(op.cTo.y))
      of closePath:
        emitClose(c))
  if not ok:
    return
  flushSub(c)
  for s in c.path.subs:
    if s.anchors.len > 0:
      path.subs.add(s)

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
