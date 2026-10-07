## PDF-compatible `.ai` writer.
##
## Serializes a `VecDocument` to a valid PDF file with one page per
## artboard, so it renders anywhere PDF renders and opens in Illustrator
## as PDF-compatible artwork. Geometry is baked to page space (model
## y-down flipped to PDF y-up); node transforms accumulate down the tree.
##
## Honest limits, all reported in `AiWriteReport.warnings`: text
## placeholders and image references are not written (their pixels and
## glyphs are not in the model); pattern paints are left unpainted;
## gradients with more than two stops keep only their endpoints;
## non-uniform transforms scale stroke widths approximately; hidden
## layers are skipped. No `/AIPrivateData` is written: there is no
## native Illustrator edit state to preserve, and inventing one would be
## a lie the file cannot keep.

import std/math
import std/strutils
import std/tables
import opendocs/pdf/cos
import opendocs/pdf/write
import ../vector
import ./types

export vector

type
  AiWriteReport* = object
    bytes*: string
    warnings*: seq[string]

  Writer = object
    b*: PdfBuilder
    patterns*: Table[string, int] ## gradient key to pattern object number
    states*: Table[string, int]   ## opacity value to ExtGState number

proc noteLoss(doc: var VecDocument, r: var AiWriteReport, msg: string) =
  if msg notin r.warnings:
    r.warnings.add(msg)
  doc.warn(msg)

proc fnum(v: float64): string = fmtNum(v, 4)

proc coNums(vals: seq[float64]): CosObj =
  var items: seq[CosObj] = @[]
  for v in vals:
    items.add(CosObj(kind: coFloat, fval: v))
  CosObj(kind: coArray, items: items)

proc coNameRef(num: int): CosObj =
  CosObj(kind: coRef, refNum: num, refGen: 0)

proc colorOps(c: VecColor, stroking: bool): string =
  ## Fill (`rg`/`g`/`k`) or stroke (`RG`/`G`/`K`) color operators.
  case c.space
  of vcsGray: fnum(c.gray) & " " & (if stroking: "G" else: "g")
  of vcsRGB:
    fnum(c.r) & " " & fnum(c.g) & " " & fnum(c.b) & " " &
      (if stroking: "RG" else: "rg")
  of vcsCMYK:
    fnum(c.c) & " " & fnum(c.m) & " " & fnum(c.y) & " " & fnum(c.k) &
      " " & (if stroking: "K" else: "k")

proc rgbOf(c: VecColor): tuple[r, g, b: float64] =
  case c.space
  of vcsRGB: (c.r, c.g, c.b)
  of vcsGray: (c.gray, c.gray, c.gray)
  of vcsCMYK:
    (1.0 - min(1.0, c.c + c.k), 1.0 - min(1.0, c.m + c.k),
     1.0 - min(1.0, c.y + c.k))

proc gradientKey(g: VecGradient): string =
  var s = $ord(g.kind) & "|" & $ord(g.spread) & "|" &
    fnum(g.x0) & "," & fnum(g.y0) & "," & fnum(g.x1) & "," &
    fnum(g.y1) & "," & fnum(g.cx) & "," & fnum(g.cy) & "," &
    fnum(g.r) & "," & fnum(g.fx) & "," & fnum(g.fy) & "|"
  for st in g.stops:
    let (r, gg, b) = rgbOf(st.color)
    s.add(fnum(st.offset) & "=" & fnum(r) & "," & fnum(gg) & "," &
      fnum(b) & " ")
  s

proc emitShading(w: var Writer, g: VecGradient, m: VecXform,
    doc: var VecDocument, r: var AiWriteReport,
    bounds: VecRect): string =
  ## A gradient to `/Pattern` + `/Shading` + `/Function` objects.
  ## Returns the pattern resource name. Stops beyond the endpoints are
  ## out of scope for exponential interpolation, so they warn.
  let key = gradientKey(g)
  if key in w.patterns:
    return "P" & $w.patterns[key]
  var stops = g.stops
  if stops.len < 2:
    noteLoss(doc, r, "a gradient with fewer than two stops paints nothing")
    return ""
  if stops.len > 2:
    noteLoss(doc, r, "a gradient with " & $stops.len &
      " stops keeps only its endpoints")
    stops = @[stops[0], stops[^1]]
  proc T(x, y: float64): tuple[x, y: float64] =
    let p = applyXform(m, vecPt(x, y))
    (p.x, p.y)
  proc resolveFrac(v: float64, lo, hi: float64): float64 =
    if g.objectBoundingBox: lo + v * (hi - lo) else: v
  let bx0 = bounds.x0
  let by0 = bounds.y0
  let bx1 = bounds.x1
  let by1 = bounds.y1
  var coords: seq[float64] = @[]
  var shadeType = 2
  if g.kind == vgkLinear:
    let a = T(resolveFrac(g.x0, bx0, bx1), resolveFrac(g.y0, by0, by1))
    let b2 = T(resolveFrac(g.x1, bx0, bx1), resolveFrac(g.y1, by0, by1))
    coords = @[a.x, a.y, b2.x, b2.y]
  else:
    shadeType = 3
    let c = T(resolveFrac(g.cx, bx0, bx1), resolveFrac(g.cy, by0, by1))
    let f = T(resolveFrac(g.fx, bx0, bx1), resolveFrac(g.fy, by0, by1))
    let rr = if g.objectBoundingBox:
        g.r * max(bx1 - bx0, by1 - by0)
      else: g.r
    if abs(f.x - c.x) > 1e-9 or abs(f.y - c.y) > 1e-9:
      noteLoss(doc, r, "a radial gradient focal point off its center " &
        "is not modeled; the center is used")
    coords = @[c.x, c.y, 0.0, c.x, c.y, rr]
  let (r0, g0, b0) = rgbOf(stops[0].color)
  let (r1, g1, b1) = rgbOf(stops[1].color)
  let fnNum = w.b.addValue(CosObj(kind: coDict,
    keys: @["FunctionType", "Domain", "C0", "C1", "N"],
    vals: @[CosObj(kind: coInt, ival: 2),
      coNums(@[0.0, 1.0]),
      coNums(@[r0, g0, b0]),
      coNums(@[r1, g1, b1]),
      CosObj(kind: coInt, ival: 1)]))
  let shNum = w.b.addValue(CosObj(kind: coDict,
    keys: @["ShadingType", "ColorSpace", "Coords", "Function", "Extend"],
    vals: @[CosObj(kind: coInt, ival: shadeType),
      CosObj(kind: coName, name: "DeviceRGB"),
      coNums(coords),
      coNameRef(fnNum),
      CosObj(kind: coArray, items: @[CosObj(kind: coBool, bval: true),
        CosObj(kind: coBool, bval: true)])]))
  let patNum = w.b.addValue(CosObj(kind: coDict,
    keys: @["Type", "PatternType", "Shading"],
    vals: @[CosObj(kind: coName, name: "Pattern"),
      CosObj(kind: coInt, ival: 2),
      coNameRef(shNum)]))
  w.patterns[key] = patNum
  "P" & $patNum

proc gsFor(w: var Writer, opacity: float64): string =
  ## An ExtGState resource name for `opacity`, creating it once.
  let key = fnum(opacity)
  if key in w.states:
    return "Gs" & $w.states[key]
  let num = w.b.addValue(CosObj(kind: coDict,
    keys: @["Type", "ca", "CA"],
    vals: @[CosObj(kind: coName, name: "ExtGState"),
      CosObj(kind: coFloat, fval: opacity),
      CosObj(kind: coFloat, fval: opacity)]))
  w.states[key] = num
  "Gs" & $num

proc emitSubPath(s: VecSubPath): string =
  ## One subpath to `m`/`l`/`c` operators plus `h` when closed.
  if s.anchors.len == 0: return ""
  var parts: seq[string] = @[
    fnum(s.anchors[0].p.x) & " " & fnum(s.anchors[0].p.y) & " m"]
  for i in 0 ..< segmentCount(s):
    let c = segment(s, i)
    if segmentIsLine(s, i):
      parts.add(fnum(c.p3.x) & " " & fnum(c.p3.y) & " l")
    else:
      parts.add(fnum(c.p1.x) & " " & fnum(c.p1.y) & " " &
        fnum(c.p2.x) & " " & fnum(c.p2.y) & " " &
        fnum(c.p3.x) & " " & fnum(c.p3.y) & " c")
  if s.closed:
    parts.add("h")
  parts.join("\n")

proc emitStrokePaint(w: var Writer, st: VecStroke, m: VecXform,
    bounds: VecRect, doc: var VecDocument, r: var AiWriteReport,
    outp: var string): bool =
  ## Stroke paint selection operators. False when the stroke has no
  ## writable paint and must be dropped.
  case st.paint.kind
  of vpkSolid:
    outp.add(colorOps(st.paint.solid, true) & "\n")
    true
  of vpkLinear, vpkRadial:
    let pname = emitShading(w, st.paint.gradient, m, doc, r, bounds)
    if pname.len == 0: return false
    outp.add("/Pattern CS /" & pname & " SCN\n")
    true
  of vpkPattern:
    noteLoss(doc, r, "pattern stroke '" & st.paint.patternName &
      "' has no tile model; stroke dropped")
    false
  of vpkNone:
    noteLoss(doc, r, "a stroke with no paint was dropped")
    false

proc emitStrokeAttrs(w: var Writer, st: VecStroke, m: VecXform,
    bounds: VecRect, doc: var VecDocument, r: var AiWriteReport,
    outp: var string): bool =
  if not emitStrokePaint(w, st, m, bounds, doc, r, outp):
    return false
  outp.add(fnum(st.width) & " w\n")
  outp.add($(ord(st.cap)) & " J\n")
  outp.add($(ord(st.join)) & " j\n")
  outp.add(fnum(st.miterLimit) & " M\n")
  if st.dash.len > 0:
    var parts: seq[string] = @[]
    for d in st.dash: parts.add(fnum(d))
    outp.add("[" & parts.join(" ") & "] " & fnum(st.dashOffset) & " d\n")
  true

proc strokeScale(m: VecXform): tuple[s: float64, uniform: bool] =
  ## The linear scale of a transform for stroke widths. Non-uniform
  ## scales are approximate by construction.
  let sx = sqrt(m[0]*m[0] + m[1]*m[1])
  let sy = sqrt(m[2]*m[2] + m[3]*m[3])
  ((sx + sy) / 2.0, abs(sx - sy) <= 1e-9 * max(1.0, sx + sy))

proc emitNode(w: var Writer, n: VecNode, xf: VecXform, opacity: float64,
    board: VecRect, doc: var VecDocument, r: var AiWriteReport,
    outp: var string)

proc boundsFor(path: VecPath, xf: VecXform, board: VecRect): VecRect =
  ## Gradient resolution bounds: the path in model space, falling back
  ## to the artboard for empty paths.
  let b = pathBounds(transformPath(path, xf))
  if b.x1 <= b.x0 or b.y1 <= b.y0:
    vecRect(board.x0, board.y0, board.x1, board.y1)
  else: b

proc emitPainted(w: var Writer, path: VecPath, fill: VecPaint,
    stroke: VecStroke, hasStroke: bool, xf: VecXform, opacity: float64,
    board: VecRect, doc: var VecDocument, r: var AiWriteReport,
    outp: var string) =
  let m = concatXform(
    [1.0, 0.0, 0.0, -1.0, -board.x0, board.y1], xf)
  var body = ""
  for s in path.subs:
    let t = emitSubPath(transformSubPath(s, m))
    if t.len > 0: body.add(t & "\n")
  if body.len == 0: return
  let op = opacity
  var scoped = false
  if op < 1.0 - 1e-9:
    body = "q\n/" & gsFor(w, op) & " gs\n" & body
    scoped = true
  let (ss, uniform) = strokeScale(m)
  if hasStroke and not uniform:
    noteLoss(doc, r, "a non-uniform transform scales stroke widths " &
      "approximately")
  var stroked = false
  if hasStroke:
    var st = stroke
    st.width = stroke.width * ss
    stroked = emitStrokeAttrs(w, st, m, boundsFor(path, xf, board),
      doc, r, body)
  case fill.kind
  of vpkNone:
    if stroked: body.add("S\n")
    else: body.add("n\n")
  of vpkSolid:
    body.add(colorOps(fill.solid, false) & "\n")
    if stroked:
      body.add(if path.fillRule == vfrEvenOdd: "B*\n" else: "B\n")
    else:
      body.add(if path.fillRule == vfrEvenOdd: "f*\n" else: "f\n")
  of vpkLinear, vpkRadial:
    let pname = emitShading(w, fill.gradient, m, doc, r,
      boundsFor(path, xf, board))
    if pname.len == 0:
      body.add("n\n")
    else:
      body.add("/Pattern cs /" & pname & " scn\n")
      if stroked:
        body.add(if path.fillRule == vfrEvenOdd: "B*\n" else: "B\n")
      else:
        body.add(if path.fillRule == vfrEvenOdd: "f*\n" else: "f\n")
  of vpkPattern:
    noteLoss(doc, r, "pattern paint '" & fill.patternName &
      "' has no tile model; left unpainted")
    body.add("n\n")
  if scoped:
    body.add("Q\n")
  outp.add(body)

proc emitNode(w: var Writer, n: VecNode, xf: VecXform, opacity: float64,
    board: VecRect, doc: var VecDocument, r: var AiWriteReport,
    outp: var string) =
  let nx = concatXform(n.xform, xf)
  let no = opacity * n.opacity
  case n.kind
  of vnkGroup:
    for c in n.children:
      emitNode(w, c, nx, no, board, doc, r, outp)
  of vnkPath:
    emitPainted(w, n.path, n.fill, n.stroke, n.hasStroke, nx, no,
      board, doc, r, outp)
  of vnkClip:
    let m = concatXform(
      [1.0, 0.0, 0.0, -1.0, -board.x0, board.y1], nx)
    var body = "q\n"
    for s in n.clip.subs:
      let t = emitSubPath(transformSubPath(s, m))
      if t.len > 0: body.add(t & "\n")
    body.add(if n.clipRule == vfrEvenOdd: "W* n\n" else: "W n\n")
    var inner = ""
    for c in n.clipped:
      emitNode(w, c, nx, no, board, doc, r, inner)
    body.add(inner & "Q\n")
    outp.add(body)
  of vnkImage:
    noteLoss(doc, r, "image '" & n.imageKey &
      "' keeps no pixels in the model; not written")
  of vnkText:
    if n.outline.isSome:
      var p = n.outline.get()
      emitPainted(w, p, n.textFill, defaultStroke(), false, nx, no,
        board, doc, r, outp)
    else:
      noteLoss(doc, r, "text '" & n.text &
        "' has no baked outline; not written")

proc writeAi*(doc: var VecDocument, title = ""): AiWriteReport =
  ## A vector document to PDF-compatible `.ai` bytes. Content streams
  ## stay uncompressed so tests and humans can read the operators.
  result = AiWriteReport()
  if doc.artboards.len == 0:
    raise newException(AiError, "cannot write a document with no artboards")
  var w = Writer(b: newPdfBuilder(),
    patterns: initTable[string, int](),
    states: initTable[string, int]())
  for board in doc.artboards:
    var outp = ""
    for layer in doc.layers:
      if not layer.visible:
        noteLoss(doc, result, "hidden layer '" & layer.name &
          "' was skipped")
        continue
      for n in layer.children:
        emitNode(w, n, identityXform(), 1.0, board.rect,
          doc, result, outp)
    let contentNum = w.b.addContentStream(outp, false)
    var rkeys = @["ExtGState", "Pattern"]
    var rvals: seq[CosObj] = @[]
    var gsKeys: seq[string] = @[]
    var gsVals: seq[CosObj] = @[]
    for k, v in w.states:
      gsKeys.add("Gs" & $v)
      gsVals.add(coNameRef(v))
    rvals.add(CosObj(kind: coDict, keys: gsKeys, vals: gsVals))
    var patKeys: seq[string] = @[]
    var patVals: seq[CosObj] = @[]
    for k, v in w.patterns:
      patKeys.add("P" & $v)
      patVals.add(coNameRef(v))
    rvals.add(CosObj(kind: coDict, keys: patKeys, vals: patVals))
    discard w.b.addPage(rectWidth(board.rect), rectHeight(board.rect),
      contentNum, CosObj(kind: coDict, keys: rkeys, vals: rvals))
  if title.len > 0:
    w.b.setInfo(title)
  result.bytes = w.b.buildPdf()
