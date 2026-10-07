## SVG bridge for the vector model.
##
## Converts between `openparser/svg` documents and `VecDocument`, in both
## directions. openparser owns the XML grammar (tags, lengths, transforms,
## path data, colors); this module owns the geometric meaning (anchors,
## transforms, paints) and the loss ledger. Anything without a faithful
## mapping lands in `VecDocument.warnings` instead of vanishing.
##
## Supported on import: shapes, paths (all commands including arcs),
## transforms, viewBox, solid fills and strokes, linear and radial
## gradients, opacity, groups, images, and text placeholders. Deferred
## with warnings: clip paths, masks, filters, symbols and `use`,
## patterns (kept as named references), markers, animation, interactivity,
## and embedded stylesheets beyond presentation attributes plus a small
## set of style-declaration fallbacks.

import std/math
import std/options
import std/strutils
import std/tables
import openparser/svg
import openparser/colors
from ./path import circleKappa, cornerAnchor, curveTo, ellipseSubPath,
  lineTo, moveTo, rectSubPath
import ./types

export types

type
  SvgDefs* = object
    ## Gradient and pattern definitions collected from `<defs>`.
    gradients*: Table[string, SvgNode]
    patterns*: Table[string, SvgNode]
    clips*: Table[string, SvgNode]

proc lengthToPt*(l: SvgLength, percentOf = 0.0): float64 =
  ## An SVG length in document points. Percentages resolve against
  ## `percentOf` (the relevant viewport dimension).
  case l.unit
  of luNumber, luPx: l.value
  of luPt: l.value
  of luPc: l.value * 12.0
  of luIn: l.value * 72.0
  of luCm: l.value * 72.0 / 2.54
  of luMm: l.value * 72.0 / 25.4
  of luEm, luEx: l.value * 12.0 ## no font context: 12pt approximation
  of luPercent: l.value / 100.0 * percentOf

proc optLen(node: SvgNode, key: string, percentOf = 0.0,
    default = 0.0): float64 =
  if node.attrsRaw.hasKey(key):
    try: lengthToPt(parseSvgLength(node.attrsRaw[key]), percentOf)
    except: default
  else: default

proc svgTransformToXform*(t: SvgTransform): VecXform =
  ## One SVG transform function to an affine matrix.
  proc num(vals: seq[float], i: int, default = 0.0): float64 =
    if i < vals.len: vals[i] else: default
  case t.kind
  of trMatrix:
    [num(t.values, 0, 1.0), num(t.values, 1), num(t.values, 2),
     num(t.values, 3, 1.0), num(t.values, 4), num(t.values, 5)]
  of trTranslate:
    translateXform(num(t.values, 0), num(t.values, 1))
  of trScale:
    scaleXform(num(t.values, 0), num(t.values, 1, num(t.values, 0, 1.0)))
  of trRotate:
    let m = rotateXform(num(t.values, 0))
    if t.values.len >= 3:
      let (cx, cy) = (t.values[1], t.values[2])
      concatXform(translateXform(cx, cy),
        concatXform(m, translateXform(-cx, -cy)))
    else: m
  of trSkewX:
    [1.0, 0.0, tan(num(t.values, 0) * PI / 180.0), 1.0, 0.0, 0.0]
  of trSkewY:
    [1.0, tan(num(t.values, 0) * PI / 180.0), 0.0, 1.0, 0.0, 0.0]

proc transformsToXform*(ts: seq[SvgTransform]): VecXform =
  ## A transform list to one matrix. SVG applies functions left to
  ## right, so each function wraps everything accumulated so far.
  result = identityXform()
  for t in ts:
    result = concatXform(svgTransformToXform(t), result)

proc nodeXform*(node: SvgNode): VecXform =
  if node.kind == svgElement and node.common.transform.isSome:
    transformsToXform(node.common.transform.get())
  else: identityXform()

proc nodeOpacity*(node: SvgNode): float64 =
  if node.kind == svgElement and node.common.opacity.isSome:
    node.common.opacity.get()
  else: 1.0

proc styleDecl(node: SvgNode, prop: string): string =
  ## A `style="prop: value"` fallback for presentation attributes the
  ## parser does not resolve into typed fields.
  if node.kind != svgElement: return ""
  for d in node.common.styleDecls:
    if d.property.toLowerAscii() == prop: return d.value.strip()
  ""

proc openColorToVec*(c: Color): VecColor =
  rgbColor(c.r, c.g, c.b, c.a)

proc parseOffset(s: string): float64 =
  ## A gradient stop offset: "50%" or a 0..1 number.
  let t = s.strip()
  try:
    if t.endsWith("%"): parseFloat(t[0 .. ^2]) / 100.0
    else: parseFloat(t)
  except: 0.0

proc buildGradient*(node: SvgNode, doc: var VecDocument,
    idPrefix = ""): VecGradient =
  ## A `<linearGradient>` or `<radialGradient>` node to a gradient.
  ## Geometry reads from raw attributes so `objectBoundingBox` units
  ## stay meaningful; the caller resolves the gradient transform.
  let isLinear = node.tag == svgLinearGradient
  result = VecGradient(
    kind: if isLinear: vgkLinear else: vgkRadial,
    xform: nodeXform(node), spread: vspPad,
    objectBoundingBox: true)
  let units = if node.gradientUnits.isSome: node.gradientUnits.get() else: ""
  if units == "userSpaceOnUse":
    result.objectBoundingBox = false
  elif units.len > 0 and units != "objectBoundingBox":
    doc.warn("gradient '" & idPrefix &
      "' has unknown gradientUnits '" & units & "'; read as bounding box")
  if node.attrsRaw.getOrDefault("spreadMethod", "") == "reflect":
    result.spread = vspReflect
  elif node.attrsRaw.getOrDefault("spreadMethod", "") == "repeat":
    result.spread = vspRepeat
  if isLinear:
    result.x0 = optLen(node, "x1")
    result.y0 = optLen(node, "y1")
    result.x1 = optLen(node, "x2", default = 1.0)
    result.y1 = optLen(node, "y2")
  else:
    result.cx = optLen(node, "cx", default = 0.5)
    result.cy = optLen(node, "cy", default = 0.5)
    result.r = optLen(node, "r", default = 0.5)
    result.fx = optLen(node, "fx", default = result.cx)
    result.fy = optLen(node, "fy", default = result.cy)
  for stop in node.children:
    if stop.kind != svgElement or stop.tag != svgStop: continue
    var col = rgbColor(0, 0, 0)
    if stop.stopColor.isSome:
      col = openColorToVec(stop.stopColor.get())
    else:
      doc.warn("gradient '" & idPrefix &
        "' has a stop without a readable color; read as black")
    if stop.stopOpacity.isSome:
      col.alpha = stop.stopOpacity.get()
    let off = if stop.offset.isSome: parseOffset(stop.offset.get()) else: 0.0
    result.stops.add(VecGradientStop(offset: off, color: col))

proc collectDefs*(root: SvgNode): SvgDefs =
  ## Gradient and pattern definitions anywhere under `root`, keyed by id.
  var defs = SvgDefs()
  proc walk(n: SvgNode) =
    if n.kind != svgElement: return
    if n.tag in {svgLinearGradient, svgRadialGradient} and
        n.common.id.isSome:
      defs.gradients[n.common.id.get()] = n
    elif n.tag == svgPattern and n.common.id.isSome:
      defs.patterns[n.common.id.get()] = n
    elif n.tag == svgClipPath and n.common.id.isSome:
      defs.clips[n.common.id.get()] = n
    for c in n.children: walk(c)
  walk(root)
  defs

proc paintFromSpec*(spec: string, isFill: bool, defs: SvgDefs,
    doc: var VecDocument): VecPaint =
  ## A `fill` or `stroke` attribute value to a paint. `url(#id)` resolves
  ## against collected definitions; unknown paint servers become `none`
  ## with a warning rather than a guess.
  let s = spec.strip()
  if s.len == 0 or s.toLowerAscii() == "none":
    return noPaint()
  if s.startsWith("url("):
    let id = s[4 .. ^1].strip(chars = {'(', ')', '\'', '"', '#', ' '})
    if id in defs.gradients:
      let g = defs.gradients[id]
      var grad = buildGradient(g, doc, id)
      if g.tag == svgLinearGradient:
        return VecPaint(kind: vpkLinear, gradient: grad)
      return VecPaint(kind: vpkRadial, gradient: grad)
    if id in defs.patterns:
      return VecPaint(kind: vpkPattern, patternName: id,
        patternXform: identityXform())
    doc.warn("paint reference '#" & id & "' is not a known " &
      "gradient or pattern; painted as none")
    return noPaint()
  try:
    solidPaint(openColorToVec(parseColor(s)))
  except:
    doc.warn("unreadable " & (if isFill: "fill" else: "stroke") &
      " '" & s & "'; painted as none")
    noPaint()

proc nodeFill*(node: SvgNode, defs: SvgDefs,
    doc: var VecDocument): VecPaint =
  var spec = ""
  if node.common.fillRaw.isSome: spec = node.common.fillRaw.get()
  else: spec = styleDecl(node, "fill")
  result = paintFromSpec(spec, true, defs, doc)
  let op = if node.common.fillOpacity.isSome: node.common.fillOpacity.get()
    else:
      let sd = styleDecl(node, "fill-opacity")
      if sd.len > 0:
        try: parseFloat(sd) except: 1.0
      else: 1.0
  if result.kind == vpkSolid:
    result.solid.alpha = clamp(result.solid.alpha * op, 0.0, 1.0)

proc nodeStroke*(node: SvgNode, defs: SvgDefs,
    doc: var VecDocument): tuple[has: bool, stroke: VecStroke] =
  var spec = ""
  if node.common.strokeRaw.isSome: spec = node.common.strokeRaw.get()
  else: spec = styleDecl(node, "stroke")
  if spec.strip().len == 0 or spec.strip().toLowerAscii() == "none":
    return (false, defaultStroke())
  let paint = paintFromSpec(spec, false, defs, doc)
  if paint.kind == vpkNone:
    return (false, defaultStroke())
  var st = defaultStroke()
  st.paint = paint
  if node.common.strokeWidth.isSome:
    st.width = lengthToPt(node.common.strokeWidth.get())
  else:
    let sd = styleDecl(node, "stroke-width")
    if sd.len > 0:
      try: st.width = lengthToPt(parseSvgLength(sd)) except: discard
  let cap = node.attrsRaw.getOrDefault("stroke-linecap",
    styleDecl(node, "stroke-linecap")).toLowerAscii()
  st.cap = case cap
    of "round": vlcRound
    of "square": vlcSquare
    else: vlcButt
  let join = node.attrsRaw.getOrDefault("stroke-linejoin",
    styleDecl(node, "stroke-linejoin")).toLowerAscii()
  st.join = case join
    of "round": vljRound
    of "bevel": vljBevel
    else: vljMiter
  let ml = node.attrsRaw.getOrDefault("stroke-miterlimit", "")
  if ml.len > 0:
    try: st.miterLimit = parseFloat(ml) except: discard
  let da = node.attrsRaw.getOrDefault("stroke-dasharray",
    styleDecl(node, "stroke-dasharray")).strip().toLowerAscii()
  if da.len > 0 and da != "none":
    for part in da.split({',', ' ', '\t'}):
      if part.len == 0: continue
      try: st.dash.add(parseFloat(part)) except: discard
  let doff = node.attrsRaw.getOrDefault("stroke-dashoffset",
    styleDecl(node, "stroke-dashoffset"))
  if doff.len > 0:
    try: st.dashOffset = lengthToPt(parseSvgLength(doff)) except: discard
  let op = if node.common.strokeOpacity.isSome:
      node.common.strokeOpacity.get()
    else:
      let sd = styleDecl(node, "stroke-opacity")
      if sd.len > 0:
        try: parseFloat(sd) except: 1.0
      else: 1.0
  if st.paint.kind == vpkSolid:
    st.paint.solid.alpha = clamp(st.paint.solid.alpha * op, 0.0, 1.0)
  (true, st)

proc arcToCurves*(x1, y1, rx, ry, phi: float64, largeArc, sweep: bool,
    x2, y2: float64): seq[VecCubic] =
  ## Endpoint-parameterized elliptical arc to cubic segments, per the
  ## SVG implementation notes. Degenerate arcs become straight lines.
  var (rx, ry) = (abs(rx), abs(ry))
  if rx <= VecEps or ry <= VecEps:
    return @[VecCubic(p0: vecPt(x1, y1), p1: vecPt(x1, y1),
      p2: vecPt(x2, y2), p3: vecPt(x2, y2))]
  let rad = phi * PI / 180.0
  let (cp, sp) = (cos(rad), sin(rad))
  let dx = (x1 - x2) / 2.0
  let dy = (y1 - y2) / 2.0
  let x1p = cp*dx + sp*dy
  let y1p = -sp*dx + cp*dy
  var lam = x1p*x1p/(rx*rx) + y1p*y1p/(ry*ry)
  if lam > 1.0:
    let s = sqrt(lam)
    rx *= s
    ry *= s
  var num = rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
  var den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
  var co = 0.0
  if den > VecEps:
    co = if num < 0.0: 0.0 else: sqrt(num / den)
  if largeArc == sweep: co = -co
  let cxp = co * rx * y1p / ry
  let cyp = -co * ry * x1p / rx
  let cx = cp*cxp - sp*cyp + (x1 + x2) / 2.0
  let cy = sp*cxp + cp*cyp + (y1 + y2) / 2.0
  proc angle(ux, uy, vx, vy: float64): float64 =
    let d = sqrt(ux*ux + uy*uy) * sqrt(vx*vx + vy*vy)
    var c = if d > VecEps: (ux*vx + uy*vy) / d else: 1.0
    c = clamp(c, -1.0, 1.0)
    var a = arccos(c)
    if ux*vy - uy*vx < 0.0: a = -a
    a
  var t1 = angle(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
  var dt = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
    (-x1p - cxp) / rx, (-y1p - cyp) / ry)
  if not sweep and dt > 0.0: dt -= 2.0 * PI
  elif sweep and dt < 0.0: dt += 2.0 * PI
  let n = max(1, int(ceil(abs(dt) / (PI / 2.0))))
  let step = dt / float(n)
  proc pt(t: float64): VecPt =
    let (c, s) = (cos(t), sin(t))
    vecPt(cx + rx*cp*c - ry*sp*s, cy + rx*sp*c + ry*cp*s)
  proc dtPt(t: float64): VecPt =
    let (c, s) = (cos(t), sin(t))
    vecPt(-rx*cp*s - ry*sp*c, -rx*sp*s + ry*cp*c)
  for i in 0 ..< n:
    let (a, b) = (t1 + float(i)*step, t1 + float(i+1)*step)
    let k = 4.0/3.0 * tan((b - a) / 4.0)
    let (pa, pb) = (pt(a), pt(b))
    let (da, db) = (dtPt(a), dtPt(b))
    result.add(VecCubic(p0: pa,
      p1: vecPt(pa.x + k*da.x, pa.y + k*da.y),
      p2: vecPt(pb.x - k*db.x, pb.y - k*db.y), p3: pb))

proc pathDataToVec*(segs: seq[SvgPathSeg]): VecPath =
  ## Parsed SVG path segments to a path. All coordinates absolute;
  ## arcs expand to cubics; smooth and quadratic commands expand to
  ## explicit control points.
  var sub = VecSubPath()
  var subs: seq[VecSubPath] = @[]
  var cur = vecPt(0, 0)
  var start = vecPt(0, 0)
  var prevC2 = vecPt(0, 0)
  var prevQ = vecPt(0, 0)
  var prevCmd = '\x00'
  proc flush() =
    if sub.anchors.len > 0:
      subs.add(sub)
      sub = VecSubPath()
  proc emitCubic(c1, c2, p: VecPt) =
    curveTo(sub, c1, c2, p)
    cur = p
  for s in segs:
    let rel = s.cmd in {'m', 'l', 'h', 'v', 'c', 's', 'q', 't', 'a'}
    let cmd = s.cmd.toUpperAscii()
    var a = s.args
    case cmd
    of 'M':
      flush()
      var i = 0
      var first = true
      while i + 1 < a.len:
        let p = if rel: vecPt(cur.x + a[i], cur.y + a[i+1])
          else: vecPt(a[i], a[i+1])
        if first:
          moveTo(sub, p)
          start = p
          first = false
        else:
          lineTo(sub, p)
        cur = p
        i += 2
      prevCmd = 'M'
    of 'L':
      var i = 0
      while i + 1 < a.len:
        let p = if rel: vecPt(cur.x + a[i], cur.y + a[i+1])
          else: vecPt(a[i], a[i+1])
        lineTo(sub, p)
        cur = p
        i += 2
      prevCmd = 'L'
    of 'H':
      for v in a:
        let p = if rel: vecPt(cur.x + v, cur.y) else: vecPt(v, cur.y)
        lineTo(sub, p)
        cur = p
      prevCmd = 'L'
    of 'V':
      for v in a:
        let p = if rel: vecPt(cur.x, cur.y + v) else: vecPt(cur.x, v)
        lineTo(sub, p)
        cur = p
      prevCmd = 'L'
    of 'C':
      var i = 0
      while i + 5 < a.len:
        let c1 = if rel: vecPt(cur.x + a[i], cur.y + a[i+1])
          else: vecPt(a[i], a[i+1])
        let c2 = if rel: vecPt(cur.x + a[i+2], cur.y + a[i+3])
          else: vecPt(a[i+2], a[i+3])
        let p = if rel: vecPt(cur.x + a[i+4], cur.y + a[i+5])
          else: vecPt(a[i+4], a[i+5])
        emitCubic(c1, c2, p)
        prevC2 = c2
        i += 6
      prevCmd = 'C'
    of 'S':
      var i = 0
      while i + 3 < a.len:
        let c1 = if prevCmd in {'C', 'S'}:
            vecPt(2*cur.x - prevC2.x, 2*cur.y - prevC2.y)
          else: cur
        let c2 = if rel: vecPt(cur.x + a[i], cur.y + a[i+1])
          else: vecPt(a[i], a[i+1])
        let p = if rel: vecPt(cur.x + a[i+2], cur.y + a[i+3])
          else: vecPt(a[i+2], a[i+3])
        emitCubic(c1, c2, p)
        prevC2 = c2
        i += 4
      prevCmd = 'S'
    of 'Q':
      var i = 0
      while i + 3 < a.len:
        let q = if rel: vecPt(cur.x + a[i], cur.y + a[i+1])
          else: vecPt(a[i], a[i+1])
        let p = if rel: vecPt(cur.x + a[i+2], cur.y + a[i+3])
          else: vecPt(a[i+2], a[i+3])
        emitCubic(
          vecPt(cur.x + 2.0/3.0*(q.x - cur.x), cur.y + 2.0/3.0*(q.y - cur.y)),
          vecPt(p.x + 2.0/3.0*(q.x - p.x), p.y + 2.0/3.0*(q.y - p.y)), p)
        prevQ = q
        i += 4
      prevCmd = 'Q'
    of 'T':
      var i = 0
      while i + 1 < a.len:
        let q = if prevCmd in {'Q', 'T'}:
            vecPt(2*cur.x - prevQ.x, 2*cur.y - prevQ.y)
          else: cur
        let p = if rel: vecPt(cur.x + a[i], cur.y + a[i+1])
          else: vecPt(a[i], a[i+1])
        emitCubic(
          vecPt(cur.x + 2.0/3.0*(q.x - cur.x), cur.y + 2.0/3.0*(q.y - cur.y)),
          vecPt(p.x + 2.0/3.0*(q.x - p.x), p.y + 2.0/3.0*(q.y - p.y)), p)
        prevQ = q
        i += 4
      prevCmd = 'T'
    of 'A':
      var i = 0
      while i + 6 < a.len:
        let (rx, ry, phi) = (a[i], a[i+1], a[i+2])
        let (laf, sf) = (a[i+3] != 0.0, a[i+4] != 0.0)
        let p = if rel: vecPt(cur.x + a[i+5], cur.y + a[i+6])
          else: vecPt(a[i+5], a[i+6])
        if sub.anchors.len == 0:
          moveTo(sub, cur)
        for c in arcToCurves(cur.x, cur.y, rx, ry, phi, laf, sf, p.x, p.y):
          emitCubic(c.p1, c.p2, c.p3)
          prevC2 = c.p2
        i += 7
      prevCmd = 'A'
    of 'Z':
      sub.closed = true
      cur = start
      flush()
      prevCmd = 'Z'
    else:
      discard
  flush()
  VecPath(subs: subs, fillRule: vfrNonZero)

proc shapeToVec*(node: SvgNode, vw, vh: float64,
    doc: var VecDocument): VecPath =
  ## A geometric element to a path in local coordinates. Rounded
  ## rectangles become lines joined by cubic corners.
  case node.tag
  of svgRect:
    let x = optLen(node, "x")
    let y = optLen(node, "y")
    let w = optLen(node, "width", vw)
    let h = optLen(node, "height", vh)
    var rx = optLen(node, "rx", vw)
    var ry = optLen(node, "ry", vh)
    if node.attrsRaw.hasKey("rx") and not node.attrsRaw.hasKey("ry"):
      ry = rx
    elif node.attrsRaw.hasKey("ry") and not node.attrsRaw.hasKey("rx"):
      rx = ry
    rx = min(rx, w / 2.0)
    ry = min(ry, h / 2.0)
    if rx <= VecEps or ry <= VecEps:
      return VecPath(subs: @[rectSubPath(vecRect(x, y, x + w, y + h))],
        fillRule: vfrNonZero)
    let k = circleKappa
    var sub = VecSubPath()
    moveTo(sub, vecPt(x + rx, y))
    lineTo(sub, vecPt(x + w - rx, y))
    curveTo(sub, vecPt(x + w - rx + k*rx, y),
      vecPt(x + w, y + ry - k*ry), vecPt(x + w, y + ry))
    lineTo(sub, vecPt(x + w, y + h - ry))
    curveTo(sub, vecPt(x + w, y + h - ry + k*ry),
      vecPt(x + w - rx + k*rx, y + h), vecPt(x + w - rx, y + h))
    lineTo(sub, vecPt(x + rx, y + h))
    curveTo(sub, vecPt(x + rx - k*rx, y + h),
      vecPt(x, y + h - ry + k*ry), vecPt(x, y + h - ry))
    lineTo(sub, vecPt(x, y + ry))
    curveTo(sub, vecPt(x, y + ry - k*ry),
      vecPt(x + rx - k*rx, y), vecPt(x + rx, y))
    sub.closed = true
    VecPath(subs: @[sub], fillRule: vfrNonZero)
  of svgCircle:
    let cx = optLen(node, "cx", vw)
    let cy = optLen(node, "cy", vh)
    let r = optLen(node, "r", (vw + vh) / 2.0)
    VecPath(subs: @[ellipseSubPath(cx, cy, r, r)], fillRule: vfrNonZero)
  of svgEllipse:
    let cx = optLen(node, "cx", vw)
    let cy = optLen(node, "cy", vh)
    let rx = optLen(node, "rx", vw)
    let ry = optLen(node, "ry", vh)
    VecPath(subs: @[ellipseSubPath(cx, cy, rx, ry)], fillRule: vfrNonZero)
  of svgLine:
    let p0 = vecPt(optLen(node, "x1", vw), optLen(node, "y1", vh))
    let p1 = vecPt(optLen(node, "x2", vw), optLen(node, "y2", vh))
    var sub = VecSubPath()
    moveTo(sub, p0)
    lineTo(sub, p1)
    VecPath(subs: @[sub], fillRule: vfrNonZero)
  of svgPolyline, svgPolygon:
    var sub = VecSubPath()
    for i, p in node.pointsParsed:
      let v = vecPt(p.x, p.y)
      if i == 0: moveTo(sub, v)
      else: lineTo(sub, v)
    sub.closed = node.tag == svgPolygon and sub.anchors.len > 2
    VecPath(subs: @[sub], fillRule: vfrNonZero)
  of svgPath:
    pathDataToVec(node.dSegs)
  else:
    doc.warn("element <" & tagName(node) &
      "> has no path conversion; left out")
    VecPath(subs: @[], fillRule: vfrNonZero)

proc importSvgNode*(node: SvgNode, defs: SvgDefs, vw, vh: float64,
    doc: var VecDocument, parentXf: VecXform,
    parentOpacity: float64): VecNode =
  ## One SVG element to a vector node. Returns nil for content with no
  ## vector meaning; every such case warns on `doc` first.
  if node.kind != svgElement: return nil
  let xf = concatXform(nodeXform(node), parentXf)
  let op = parentOpacity * nodeOpacity(node)
  let name = if node.common.id.isSome: node.common.id.get() else: ""
  case node.tag
  of svgG, svgSvg, svgSymbol, svgSwitch, svgA:
    let g = newGroup(name, op, xf)
    for c in node.children:
      let n = importSvgNode(c, defs, vw, vh, doc, xf, op)
      if n != nil: g.children.add(n)
    g
  of svgDefs:
    for c in node.children:
      discard importSvgNode(c, defs, vw, vh, doc, xf, op)
    nil
  of svgRect, svgCircle, svgEllipse, svgLine, svgPolyline, svgPolygon,
      svgPath:
    let p = newPathNode(shapeToVec(node, vw, vh, doc),
      nodeFill(node, defs, doc), name, op, xf)
    if node.attrsRaw.getOrDefault("fill-rule", "").strip() == "evenodd":
      p.path.fillRule = vfrEvenOdd
    let (hasStroke, st) = nodeStroke(node, defs, doc)
    p.hasStroke = hasStroke
    p.stroke = st
    let clipRef = node.attrsRaw.getOrDefault("clip-path", "").strip()
    if clipRef.startsWith("url("):
      let id = clipRef[4 .. ^1].strip(chars = {'(', ')', '\'', '"', '#', ' '})
      if id in defs.clips:
        var clipPath = VecPath()
        for c in defs.clips[id].children:
          if c.kind == svgElement and c.tag in {svgRect, svgCircle,
              svgEllipse, svgLine, svgPolyline, svgPolygon, svgPath}:
            for s in shapeToVec(c, vw, vh, doc).subs:
              clipPath.subs.add(s)
        if clipPath.subs.len > 0:
          return VecNode(kind: vnkClip, name: name, opacity: op, xform: xf,
            clip: clipPath, clipRule: vfrNonZero, clipped: @[p])
      doc.warn("clip-path reference '#" & id &
        "' is not a readable clip path; content kept unclipped")
    p
  of svgText, svgTspan, svgTextPath, svgAltGlyph:
    var content = ""
    for c in node.children:
      if c.kind == svgTextNode: content.add(c.text)
    let t = VecNode(kind: vnkText, name: name, opacity: op, xform: xf,
      text: content.strip(),
      fontName: node.attrsRaw.getOrDefault("font-family", ""),
      fontSize: optLen(node, "font-size", vh, 12.0),
      textFill: nodeFill(node, defs, doc))
    doc.warn("text kept as a placeholder run; shaping and layout " &
      "are not modeled")
    t
  of svgImage:
    let r = vecRect(optLen(node, "x"), optLen(node, "y"),
      optLen(node, "x") + optLen(node, "width", vw),
      optLen(node, "y") + optLen(node, "height", vh))
    VecNode(kind: vnkImage, name: name, opacity: op, xform: xf,
      imageKey: if node.href.isSome: node.href.get() else: "",
      imageRect: r)
  of svgUse:
    doc.warn("<use> instances are not expanded; left out")
    nil
  of svgLinearGradient, svgRadialGradient, svgPattern, svgClipPath,
      svgMask, svgFilter, svgMarker:
    nil ## definitions or paint servers, not artwork
  of svgStyle, svgScript, svgTitle, svgDesc, svgMetadata:
    nil
  else:
    if node.tag == svgUnknown and node.children.len > 0:
      let g = newGroup(name, op, xf)
      for c in node.children:
        let n = importSvgNode(c, defs, vw, vh, doc, xf, op)
        if n != nil: g.children.add(n)
      if g.children.len > 0: return g
    doc.warn("element <" & tagName(node) & "> is not supported; left out")
    nil

proc importSvg*(doc: SvgDocument): VecDocument =
  ## An openparser SVG document to a vector document. The artboard
  ## follows the viewBox when present, else the width and height.
  result = VecDocument()
  let root = doc.root
  if root.kind != svgElement or root.tag != svgSvg:
    result.warn("document root is not <svg>; nothing imported")
    return
  let vw = if root.width.isSome: lengthToPt(root.width.get()) else: 300.0
  let vh = if root.height.isSome: lengthToPt(root.height.get()) else: 150.0
  var board = vecRect(0, 0, vw, vh)
  if root.viewBox.isSome:
    let vb = root.viewBox.get()
    board = vecRect(vb.minX, vb.minY, vb.minX + vb.width,
      vb.minY + vb.height)
  result.artboards.add(VecArtboard(name: "", rect: board))
  let defs = collectDefs(root)
  var layer = VecLayer(name: "Layer 1", visible: true, locked: false)
  for c in root.children:
    let n = importSvgNode(c, defs, rectWidth(board), rectHeight(board),
      result, identityXform(), 1.0)
    if n != nil: layer.children.add(n)
  result.layers.add(layer)
