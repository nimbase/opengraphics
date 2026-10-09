## Point-type line gathering for extracted text.
##
## The fold emits one text node per shown string; Illustrator (and the
## Rust reference) instead keeps the glyphs on one baseline as one
## point-type object with runs per font, size and paint. This post-pass
## merges consecutive runs that continue a baseline, inferring spaces
## from gaps, and splits on look changes. Thresholds mirror the
## reference: direction within about 1.8 degrees, perpendicular drift
## under 0.15 x size, gaps in (-0.3, 3.0) x size continue, gaps over
## 0.2 x size read as a space, sizes within 1%, horizontal scales
## within half a point.
##
## Two honest simplifications. Curved baselines (type on a path) have
## no model concept, so a run that turns off the line ends it with a
## note instead of joining a curve. And a non-text node ends the open
## line: art interleaved mid-baseline breaks the line here, where the
## reference device would join across it.

import std/math
import std/options
import std/strutils
import ../vector

const
  LineDirDot = 0.9995 ## same baseline within about 1.8 degrees
  LinePerpTol = 0.15 ## drift off the baseline, in ems
  LineGapLo = -0.3 ## overlap before a run stops continuing, in ems
  LineGapHi = 3.0 ## distance before a run starts a line, in ems
  LineSpaceGap = 0.2 ## gap width that reads as a space, in ems
  LineSizeTol = 0.01 ## run size match, relative
  LineHScaleTol = 0.5 ## horizontal scale match, in percent
  CurveNote = "rotated or curved runs are not joined into type on a " &
    "path; each keeps its own baseline"

type
  GatheredLines* = object
    nodes*: seq[VecNode]
    notes*: seq[string] ## caller warns each once across buckets

  LineAcc = object
    open: bool
    origin: VecPt ## first run's origin, model space
    dir: VecPt ## unit baseline direction
    size: float64
    hscale: float64
    fontName: string
    fill: VecPaint
    text: string
    glyphs: seq[VecGlyph] ## merged, in line space
    outline: Option[VecPath] ## merged, line-local (origin at origin)
    pen: VecPt ## expected pen for the next run, model space
    advance: float64 ## total travel from origin along dir

proc gatherTextLines*(nodes: seq[VecNode]): GatheredLines

proc sameColor(a, b: VecColor): bool =
  ## Structural paint comparison: `==` does not generate for case
  ## objects, so looks compare field by field.
  if a.space != b.space or a.alpha != b.alpha:
    return false
  case a.space
  of vcsRGB: a.r == b.r and a.g == b.g and a.b == b.b
  of vcsGray: a.gray == b.gray
  of vcsCMYK: a.c == b.c and a.m == b.m and a.y == b.y and a.k == b.k

proc sameXform(a, b: VecXform): bool =
  for i in 0 .. 5:
    if a[i] != b[i]:
      return false
  true

proc samePaint(a, b: VecPaint): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of vpkNone: true
  of vpkSolid: sameColor(a.solid, b.solid)
  of vpkLinear, vpkRadial:
    let x = a.gradient
    let y = b.gradient
    if x.kind != y.kind or
        x.objectBoundingBox != y.objectBoundingBox or
        x.spread != y.spread or not sameXform(x.xform, y.xform) or
        x.x0 != y.x0 or x.y0 != y.y0 or x.x1 != y.x1 or x.y1 != y.y1 or
        x.cx != y.cx or x.cy != y.cy or x.r != y.r or x.fx != y.fx or
        x.fy != y.fy or x.stops.len != y.stops.len:
      return false
    for i in 0 ..< x.stops.len:
      if x.stops[i].offset != y.stops[i].offset or
          not sameColor(x.stops[i].color, y.stops[i].color):
        return false
    true
  of vpkPattern:
    a.patternName == b.patternName and
      sameXform(a.patternXform, b.patternXform)

proc effDir(n: VecNode): VecPt =
  ## A text node's baseline direction, +x when unknown (nodes built
  ## before directions existed carry (0,0)).
  if n.baseDir.x == 0.0 and n.baseDir.y == 0.0:
    vecPt(1.0, 0.0)
  else:
    let l = sqrt(n.baseDir.x * n.baseDir.x + n.baseDir.y * n.baseDir.y)
    vecPt(n.baseDir.x / l, n.baseDir.y / l)

proc effHScale(n: VecNode): float64 =
  if n.textHScale == 0.0: 100.0 else: n.textHScale

proc originOf(n: VecNode): VecPt =
  applyXform(n.xform, vecPt(0.0, 0.0))

proc lineAngleDeg(dir: VecPt): float64 =
  arctan2(dir.y, dir.x) * 180.0 / PI

proc lineXform(origin, dir: VecPt): VecXform =
  ## translate(origin) after rotate(dir), snapped so axis-aligned
  ## lines keep pure-translation transforms.
  var deg = lineAngleDeg(dir)
  let snapped = round(deg / 90.0) * 90.0
  if abs(deg - snapped) < 1e-9:
    deg = snapped
  if abs(deg) < 1e-12 and abs(dir.x - 1.0) < 1e-12:
    return translateXform(origin.x, origin.y)
  concatXform(translateXform(origin.x, origin.y), rotateXform(deg))

proc rot(p: VecPt, deg: float64): VecPt =
  let m = rotateXform(deg)
  applyXform(m, p)

proc xformSub(s: VecSubPath, m: VecXform): VecSubPath =
  result = VecSubPath(closed: s.closed)
  for a in s.anchors:
    result.anchors.add(VecAnchor(p: applyXform(m, a.p),
      hIn: applyXform(m, a.hIn), hOut: applyXform(m, a.hOut)))

proc noteOnce(notes: var seq[string], msg: string) =
  if msg notin notes:
    notes.add(msg)

proc flushAcc(a: var LineAcc, res: var seq[VecNode], final = true) =
  ## Emit the open line. The trailing space trims only at a true line
  ## end; a look-change split keeps its bridging space on the first
  ## node, like the reference keeping it on the earlier run.
  ## Whitespace-only lines drop in both cases.
  if not a.open:
    return
  a.open = false
  var t = a.text
  if final:
    t = t.strip(leading = false, trailing = true)
  if t.strip().len == 0:
    return
  res.add(VecNode(kind: vnkText, name: "", opacity: 1.0,
    xform: lineXform(a.origin, a.dir), text: t, fontName: a.fontName,
    fontSize: a.size, textFill: a.fill, baseDir: a.dir,
    advance: a.advance, textHScale: a.hscale, glyphs: a.glyphs,
    outline: a.outline))

proc startLine(a: var LineAcc, n: VecNode, origin, dir: VecPt) =
  a.open = true
  a.origin = origin
  a.dir = dir
  a.size = n.fontSize
  a.hscale = effHScale(n)
  a.fontName = n.fontName
  a.fill = n.textFill
  a.text = n.text
  a.glyphs = n.glyphs
  if n.outline.isSome:
    let o = n.outline.get()
    var subs: seq[VecSubPath] = @[]
    subs.add(o.subs)
    a.outline = some(VecPath(subs: subs, fillRule: o.fillRule))
  else:
    a.outline = none(VecPath)
  a.pen = vecPt(origin.x + dir.x * n.advance,
    origin.y + dir.y * n.advance)
  a.advance = n.advance

proc gapFor(a: LineAcc, origin: VecPt, size: float64): float64 =
  ((origin.x - a.pen.x) * a.dir.x + (origin.y - a.pen.y) * a.dir.y) /
    size

proc continues(a: LineAcc, n: VecNode, origin, dir: VecPt): bool =
  if n.fontSize <= 0.0 or a.size <= 0.0:
    return false
  if dir.x * a.dir.x + dir.y * a.dir.y <= LineDirDot:
    return false
  let size = max(a.size, n.fontSize)
  let up = vecPt(-a.dir.y, a.dir.x)
  let perp = abs((origin.x - a.origin.x) * up.x +
    (origin.y - a.origin.y) * up.y) / size
  if perp >= LinePerpTol:
    return false
  let gap = gapFor(a, origin, size)
  gap > LineGapLo and gap < LineGapHi

proc sameLook(a: LineAcc, n: VecNode): bool =
  n.fontName == a.fontName and
    abs(n.fontSize - a.size) <= a.size * LineSizeTol and
    abs(effHScale(n) - a.hscale) < LineHScaleTol and
    samePaint(n.textFill, a.fill)

proc mergeRun(a: var LineAcc, n: VecNode, origin, dir: VecPt) =
  ## Extend the open line with a run of the same look. Glyph and
  ## outline points move from the run's baseline frame to the line's;
  ## origins are absolute, so gaps need no bookkeeping.
  let size = max(a.size, n.fontSize)
  if gapFor(a, origin, size) > LineSpaceGap and a.text.len > 0 and
      not a.text.endsWith(' ') and not n.text.startsWith(' '):
    a.text.add(' ')
  a.text.add(n.text)
  let lineDeg = lineAngleDeg(a.dir)
  let runDeg = lineAngleDeg(dir)
  let off = vecPt(origin.x - a.origin.x, origin.y - a.origin.y)
  let loff = rot(off, -lineDeg)
  let rdiff = runDeg - lineDeg
  for g in n.glyphs:
    let gp = rot(vecPt(g.dx, g.dy), rdiff)
    a.glyphs.add(VecGlyph(glyphId: g.glyphId, cluster: g.cluster,
      dx: loff.x + gp.x, dy: loff.y + gp.y, advance: g.advance))
  if n.outline.isSome:
    let m = concatXform(translateXform(loff.x, loff.y),
      rotateXform(rdiff))
    if a.outline.isNone:
      a.outline = some(VecPath(subs: @[], fillRule: vfrNonZero))
    var subs = a.outline.get().subs
    for s in n.outline.get().subs:
      subs.add(xformSub(s, m))
    a.outline = some(VecPath(subs: subs,
      fillRule: a.outline.get().fillRule))
  a.pen = vecPt(origin.x + dir.x * n.advance,
    origin.y + dir.y * n.advance)
  a.advance = (a.pen.x - a.origin.x) * a.dir.x +
    (a.pen.y - a.origin.y) * a.dir.y

proc emitRest(acc: var LineAcc, res: var seq[VecNode], n: VecNode) =
  ## A non-mergeable node ends the open line and passes through.
  flushAcc(acc, res)
  res.add(n)

proc gatherSeq(nodes: seq[VecNode], res: var seq[VecNode],
    notes: var seq[string]) =
  var acc = LineAcc()
  for n in nodes:
    case n.kind
    of vnkText:
      let origin = originOf(n)
      let dir = effDir(n)
      if acc.open and continues(acc, n, origin, dir):
        if sameLook(acc, n):
          mergeRun(acc, n, origin, dir)
        else:
          let size = max(acc.size, n.fontSize)
          if gapFor(acc, origin, size) > LineSpaceGap and
              acc.text.len > 0 and not acc.text.endsWith(' ') and
              not n.text.startsWith(' '):
            acc.text.add(' ')
          flushAcc(acc, res, false)
          startLine(acc, n, origin, dir)
      else:
        if acc.open:
          if dir.x * acc.dir.x + dir.y * acc.dir.y <= LineDirDot:
            noteOnce(notes, CurveNote)
          flushAcc(acc, res)
        startLine(acc, n, origin, dir)
    of vnkGroup:
      let g = gatherTextLines(n.children)
      var c = VecNode(kind: vnkGroup, name: n.name, opacity: n.opacity,
        xform: n.xform, children: g.nodes)
      for nt in g.notes:
        noteOnce(notes, nt)
      emitRest(acc, res, c)
    of vnkClip:
      let g = gatherTextLines(n.clipped)
      var c = VecNode(kind: vnkClip, name: n.name, opacity: n.opacity,
        xform: n.xform, clip: n.clip, clipRule: n.clipRule,
        clipped: g.nodes)
      for nt in g.notes:
        noteOnce(notes, nt)
      emitRest(acc, res, c)
    else:
      emitRest(acc, res, n)
  flushAcc(acc, res)

proc gatherTextLines*(nodes: seq[VecNode]): GatheredLines =
  ## Merge consecutive text runs on one baseline into point-type
  ## lines. Pure: input nodes are never mutated.
  result = GatheredLines(nodes: @[], notes: @[])
  gatherSeq(nodes, result.nodes, result.notes)
