## Vector model to SVG export.
##
## Serializes a `VecDocument` back to an openparser SVG document, so a
## model built programmatically (or imported from another format) can be
## written out, reparsed, and compared. The writer covers exactly what
## the importer reads: paths, solid and gradient paints, strokes,
## opacity, transforms, groups, layers, artboards, image references,
## and text placeholders. Pattern paints have no tile model yet, so they
## export as `none` with a warning on the source document.

import std/math
import std/options
import std/strutils
import std/tables
import openparser/svg
from ./path import segment, segmentCount, segmentIsLine
import ./types

export types

type
  SvgExportCtx* = object
    defs*: SvgNode
    gradIds*: Table[string, string]
    nextGrad*: int
    warnings*: seq[string]

proc newCtx(): SvgExportCtx =
  SvgExportCtx(defs: newSvgElement(svgDefs, "defs"),
    gradIds: initTable[string, string](), nextGrad: 1)

proc colorToHex*(c: VecColor): string =
  ## A model color to `#rrggbb`. Non-RGB spaces collapse to sRGB by a
  ## fixed approximation: gray replicates, CMYK inverts naively.
  proc b(v: float64): string =
    toHex(int(round(clamp(v, 0.0, 1.0) * 255.0)), 2).toLowerAscii()
  case c.space
  of vcsRGB: "#" & b(c.r) & b(c.g) & b(c.b)
  of vcsGray: "#" & b(c.gray) & b(c.gray) & b(c.gray)
  of vcsCMYK:
    "#" & b(1.0 - min(1.0, c.c + c.k)) & b(1.0 - min(1.0, c.m + c.k)) &
      b(1.0 - min(1.0, c.y + c.k))

proc colorAlpha*(c: VecColor): float64 = c.alpha

proc gradientKey(g: VecGradient): string =
  ## A stable identity for gradient deduplication in one export.
  var s = $ord(g.kind) & "|" & $ord(g.spread) & "|" &
    fmtNum(g.x0) & "," & fmtNum(g.y0) & "," & fmtNum(g.x1) & "," &
    fmtNum(g.y1) & "," & fmtNum(g.cx) & "," & fmtNum(g.cy) & "," &
    fmtNum(g.r) & "," & fmtNum(g.fx) & "," & fmtNum(g.fy) & "|"
  for st in g.stops:
    s.add(fmtNum(st.offset) & "=" & colorToHex(st.color) & ";" &
      fmtNum(st.color.alpha) & " ")
  s

proc exportGradient(ctx: var SvgExportCtx, g: VecGradient,
    doc: var VecDocument): string =
  ## A gradient to a `<defs>` entry. Returns its id.
  let key = gradientKey(g)
  if key in ctx.gradIds:
    return ctx.gradIds[key]
  let id = "grad" & $ctx.nextGrad
  inc ctx.nextGrad
  ctx.gradIds[key] = id
  let el = newSvgElement(if g.kind == vgkLinear: svgLinearGradient
    else: svgRadialGradient,
    if g.kind == vgkLinear: "linearGradient" else: "radialGradient")
  el.attrsRaw["id"] = id
  el.attrsRaw["gradientUnits"] =
    if g.objectBoundingBox: "objectBoundingBox" else: "userSpaceOnUse"
  if g.kind == vgkLinear:
    el.attrsRaw["x1"] = fmtNum(g.x0)
    el.attrsRaw["y1"] = fmtNum(g.y0)
    el.attrsRaw["x2"] = fmtNum(g.x1)
    el.attrsRaw["y2"] = fmtNum(g.y1)
  else:
    el.attrsRaw["cx"] = fmtNum(g.cx)
    el.attrsRaw["cy"] = fmtNum(g.cy)
    el.attrsRaw["r"] = fmtNum(g.r)
    el.attrsRaw["fx"] = fmtNum(g.fx)
    el.attrsRaw["fy"] = fmtNum(g.fy)
  if g.spread == vspReflect: el.attrsRaw["spreadMethod"] = "reflect"
  elif g.spread == vspRepeat: el.attrsRaw["spreadMethod"] = "repeat"
  for st in g.stops:
    let stop = newSvgElement(svgStop, "stop")
    stop.attrsRaw["offset"] = fmtNum(st.offset * 100.0) & "%"
    stop.attrsRaw["stop-color"] = colorToHex(st.color)
    if st.color.alpha < 1.0 - 1e-9:
      stop.attrsRaw["stop-opacity"] = fmtNum(st.color.alpha)
    el.addChild(stop)
  ctx.defs.addChild(el)
  id

proc exportPaintFill(ctx: var SvgExportCtx, paint: VecPaint,
    el: SvgNode, doc: var VecDocument) =
  case paint.kind
  of vpkNone:
    el.attrsRaw["fill"] = "none"
  of vpkSolid:
    el.attrsRaw["fill"] = colorToHex(paint.solid)
    if paint.solid.alpha < 1.0 - 1e-9:
      el.attrsRaw["fill-opacity"] = fmtNum(paint.solid.alpha)
  of vpkLinear, vpkRadial:
    let id = exportGradient(ctx, paint.gradient, doc)
    el.attrsRaw["fill"] = "url(#" & id & ")"
  of vpkPattern:
    el.attrsRaw["fill"] = "none"
    doc.warn("pattern paint '" & paint.patternName &
      "' has no tile model; exported as none")

proc exportStroke(ctx: var SvgExportCtx, st: VecStroke, has: bool,
    el: SvgNode, doc: var VecDocument) =
  if not has: return
  case st.paint.kind
  of vpkNone:
    el.attrsRaw["stroke"] = "none"
    return
  of vpkSolid:
    el.attrsRaw["stroke"] = colorToHex(st.paint.solid)
    if st.paint.solid.alpha < 1.0 - 1e-9:
      el.attrsRaw["stroke-opacity"] = fmtNum(st.paint.solid.alpha)
  of vpkLinear, vpkRadial:
    let id = exportGradient(ctx, st.paint.gradient, doc)
    el.attrsRaw["stroke"] = "url(#" & id & ")"
  of vpkPattern:
    el.attrsRaw["stroke"] = "none"
    doc.warn("pattern stroke '" & st.paint.patternName &
      "' has no tile model; exported as none")
  el.attrsRaw["stroke-width"] = fmtNum(st.width)
  if st.cap == vlcRound: el.attrsRaw["stroke-linecap"] = "round"
  elif st.cap == vlcSquare: el.attrsRaw["stroke-linecap"] = "square"
  if st.join == vljRound: el.attrsRaw["stroke-linejoin"] = "round"
  elif st.join == vljBevel: el.attrsRaw["stroke-linejoin"] = "bevel"
  if st.miterLimit != 4.0:
    el.attrsRaw["stroke-miterlimit"] = fmtNum(st.miterLimit)
  if st.dash.len > 0:
    var parts: seq[string] = @[]
    for d in st.dash: parts.add(fmtNum(d))
    el.attrsRaw["stroke-dasharray"] = parts.join(" ")
    if st.dashOffset != 0.0:
      el.attrsRaw["stroke-dashoffset"] = fmtNum(st.dashOffset)

proc exportNodeXform(el: SvgNode, n: VecNode) =
  if not n.xform.isIdentity():
    let m = n.xform
    el.attrsRaw["transform"] = "matrix(" & fmtNum(m[0]) & " " &
      fmtNum(m[1]) & " " & fmtNum(m[2]) & " " & fmtNum(m[3]) & " " &
      fmtNum(m[4]) & " " & fmtNum(m[5]) & ")"

proc pathToD*(p: VecPath): string =
  ## A path to SVG path data. Lines stay lines; curves stay cubics.
  var parts: seq[string] = @[]
  for s in p.subs:
    if s.anchors.len == 0: continue
    parts.add("M" & fmtNum(s.anchors[0].p.x) & " " &
      fmtNum(s.anchors[0].p.y))
    for i in 0 ..< segmentCount(s):
      let c = segment(s, i)
      if segmentIsLine(s, i):
        parts.add("L" & fmtNum(c.p3.x) & " " & fmtNum(c.p3.y))
      else:
        parts.add("C" & fmtNum(c.p1.x) & " " & fmtNum(c.p1.y) & " " &
          fmtNum(c.p2.x) & " " & fmtNum(c.p2.y) & " " &
          fmtNum(c.p3.x) & " " & fmtNum(c.p3.y))
    if s.closed:
      parts.add("Z")
  parts.join(" ")

proc exportNode(ctx: var SvgExportCtx, n: VecNode,
    doc: var VecDocument): SvgNode =
  case n.kind
  of vnkGroup:
    result = newSvgElement(svgG, "g")
    if n.name.len > 0: result.attrsRaw["id"] = n.name
    for c in n.children:
      result.addChild(exportNode(ctx, c, doc))
  of vnkPath:
    result = newSvgElement(svgPath, "path")
    result.attrsRaw["d"] = pathToD(n.path)
    if n.path.fillRule == vfrEvenOdd:
      result.attrsRaw["fill-rule"] = "evenodd"
    exportPaintFill(ctx, n.fill, result, doc)
    exportStroke(ctx, n.stroke, n.hasStroke, result, doc)
  of vnkImage:
    result = newSvgElement(svgImage, "image")
    result.attrsRaw["href"] = n.imageKey
    result.attrsRaw["x"] = fmtNum(n.imageRect.x0)
    result.attrsRaw["y"] = fmtNum(n.imageRect.y0)
    result.attrsRaw["width"] = fmtNum(rectWidth(n.imageRect))
    result.attrsRaw["height"] = fmtNum(rectHeight(n.imageRect))
  of vnkText:
    result = newSvgElement(svgText, "text")
    result.addChild(newSvgText(n.text))
    exportPaintFill(ctx, n.textFill, result, doc)
  of vnkClip:
    result = newSvgElement(svgG, "g")
    let cid = "clip" & $ctx.nextGrad
    inc ctx.nextGrad
    let cp = newSvgElement(svgClipPath, "clipPath")
    cp.attrsRaw["id"] = cid
    let cd = newSvgElement(svgPath, "path")
    cd.attrsRaw["d"] = pathToD(n.clip)
    cp.addChild(cd)
    ctx.defs.addChild(cp)
    result.attrsRaw["clip-path"] = "url(#" & cid & ")"
    for c in n.clipped:
      result.addChild(exportNode(ctx, c, doc))
  if n.name.len > 0 and result.tag != svgG:
    result.attrsRaw["id"] = n.name
  if n.opacity < 1.0 - 1e-9:
    result.attrsRaw["opacity"] = fmtNum(n.opacity)
  exportNodeXform(result, n)

proc exportSvg*(doc: var VecDocument): SvgDocument =
  ## A vector document to an openparser SVG document. Uses the first
  ## artboard as the SVG viewport; extra artboards warn since SVG has
  ## a single viewport.
  var root = newSvgElement(svgSvg, "svg")
  root.attrsRaw["xmlns"] = "http://www.w3.org/2000/svg"
  var board = vecRect(0, 0, 300, 150)
  if doc.artboards.len > 0:
    board = doc.artboards[0].rect
  if doc.artboards.len > 1:
    doc.warn("SVG has one viewport; only the first of " &
      $doc.artboards.len & " artboards was exported")
  root.attrsRaw["width"] = fmtNum(rectWidth(board))
  root.attrsRaw["height"] = fmtNum(rectHeight(board))
  root.attrsRaw["viewBox"] = fmtNum(board.x0) & " " & fmtNum(board.y0) &
    " " & fmtNum(rectWidth(board)) & " " & fmtNum(rectHeight(board))
  var ctx = newCtx()
  for layer in doc.layers:
    let g = newSvgElement(svgG, "g")
    if layer.name.len > 0: g.attrsRaw["id"] = layer.name
    if not layer.visible: g.attrsRaw["display"] = "none"
    for n in layer.children:
      g.addChild(exportNode(ctx, n, doc))
    root.addChild(g)
  if ctx.defs.children.len > 0:
    root.children.insert(ctx.defs, 0)
  SvgDocument(root: root)
