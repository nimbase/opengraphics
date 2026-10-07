import std/math
import std/options
import std/strutils
import unittest
import openparser/svg
import ../src/opengraphics/vector

proc close(a, b: float64): bool = abs(a - b) < 1e-6

test "rect with solid fill imports with geometry and paint":
  let doc = importSvg(parseSvg(
    """<svg viewBox="0 0 100 50"><rect x="10" y="5" width="20" height="10" fill="#ff0000"/></svg>"""))
  check doc.artboards.len == 1
  check doc.layers.len == 1 and doc.layers[0].children.len == 1
  let n = doc.layers[0].children[0]
  check n.kind == vnkPath
  check n.fill.kind == vpkSolid
  check close(n.fill.solid.r, 1.0)
  check close(n.fill.solid.g, 0.0)
  let b = pathBounds(n.path)
  check close(b.x0, 10.0) and close(b.y0, 5.0)
  check close(b.x1, 30.0) and close(b.y1, 15.0)

test "groups carry transforms and opacity down":
  var doc = importSvg(parseSvg(
    """<svg><g transform="translate(10,0)" opacity="0.5"><circle cx="0" cy="0" r="4"/></g></svg>"""))
  check doc.warnings.len == 0
  let g = doc.layers[0].children[0]
  check g.kind == vnkGroup
  check close(g.opacity, 0.5)
  let c = g.children[0]
  check close(c.opacity, 0.5)
  let b = pathBounds(transformPath(c.path, c.xform))
  check close(b.x0, 6.0) and close(b.x1, 14.0)

test "path arcs expand to cubics":
  let doc = importSvg(parseSvg(
    """<svg><path d="M0 0 A 5 5 0 0 1 10 0"/></svg>"""))
  let n = doc.layers[0].children[0]
  check n.path.subs.len == 1
  let s = n.path.subs[0]
  check s.anchors.len > 2
  check close(s.anchors[0].p.x, 0.0)
  check close(s.anchors[^1].p.x, 10.0)
  check close(s.anchors[^1].p.y, 0.0)

test "gradients import with stops and geometry":
  var doc = importSvg(parseSvg(
    """<svg><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="red"/><stop offset="100%" stop-color="blue"/></linearGradient></defs><rect width="10" height="10" fill="url(#g)"/></svg>"""))
  check doc.warnings.len == 0
  let n = doc.layers[0].children[0]
  check n.fill.kind == vpkLinear
  check n.fill.gradient.stops.len == 2
  check close(n.fill.gradient.stops[0].offset, 0.0)
  check close(n.fill.gradient.stops[1].offset, 1.0)
  check close(n.fill.gradient.x1, 1.0)

test "unknown paint servers warn instead of guessing":
  var doc = importSvg(parseSvg(
    """<svg><rect width="10" height="10" fill="url(#missing)"/></svg>"""))
  check doc.layers[0].children[0].fill.kind == vpkNone
  check doc.warnings.len == 1

test "unsupported elements warn and drop":
  var doc = importSvg(parseSvg(
    """<svg><rect width="10" height="10"/><filter id="f"/><use href="#x"/><clipPath id="c"/></svg>"""))
  check doc.layers[0].children.len == 1
  check doc.warnings.len == 1

test "stroke attributes map fully":
  let doc = importSvg(parseSvg(
    """<svg><line x1="0" y1="0" x2="10" y2="0" stroke="blue" stroke-width="3" stroke-linecap="round" stroke-dasharray="4 2"/></svg>"""))
  let n = doc.layers[0].children[0]
  check n.hasStroke
  check close(n.stroke.width, 3.0)
  check n.stroke.cap == vlcRound
  check n.stroke.dash == @[4.0, 2.0]
  check n.fill.kind == vpkNone

test "model to svg round-trips geometry and paint":
  var src = VecDocument()
  src.artboards.add(VecArtboard(rect: vecRect(0, 0, 100, 100)))
  var layer = VecLayer(name: "L", visible: true, locked: false)
  var sub = VecSubPath()
  moveTo(sub, vecPt(1, 2))
  lineTo(sub, vecPt(30, 4))
  curveTo(sub, vecPt(35, 4), vecPt(40, 5), vecPt(45, 6))
  sub.closed = true
  var p = newPathNode(VecPath(subs: @[sub], fillRule: vfrEvenOdd),
    solidPaint(rgbColor(1, 0, 0)), "tri")
  p.hasStroke = true
  p.stroke.width = 2.5
  layer.children.add(p)
  src.layers.add(layer)
  let text = exportSvg(src).toSvg()
  check "fill-rule" in text
  check "stroke-width=\"2.5\"" in text
  var back = importSvg(parseSvg(text))
  check back.warnings.len == 0
  let n = back.layers[0].children[0].children[0]
  check n.kind == vnkPath
  check n.path.fillRule == vfrEvenOdd
  check close(pathBounds(n.path).x1, 45.0)
  check n.hasStroke and close(n.stroke.width, 2.5)
  check close(n.fill.solid.r, 1.0)

test "gradient round-trips through defs":
  var src = VecDocument()
  src.artboards.add(VecArtboard(rect: vecRect(0, 0, 10, 10)))
  var layer = VecLayer(name: "L", visible: true, locked: false)
  let g = VecGradient(kind: vgkLinear, xform: identityXform(),
    objectBoundingBox: false, spread: vspPad,
    x0: 0, y0: 0, x1: 10, y1: 0,
    stops: @[VecGradientStop(offset: 0, color: rgbColor(1, 0, 0)),
      VecGradientStop(offset: 1, color: rgbColor(0, 0, 1))])
  layer.children.add(newPathNode(
    VecPath(subs: @[rectSubPath(vecRect(0, 0, 10, 10))]),
    VecPaint(kind: vpkLinear, gradient: g)))
  src.layers.add(layer)
  var back = importSvg(parseSvg(exportSvg(src).toSvg()))
  check back.warnings.len == 0
  let f = back.layers[0].children[0].children[0].fill
  check f.kind == vpkLinear
  check f.gradient.stops.len == 2
  check close(f.gradient.x1, 10.0)

test "length units convert to points":
  check close(lengthToPt(parseSvgLength("1in")), 72.0)
  check close(lengthToPt(parseSvgLength("2.54cm")), 72.0)
  check close(lengthToPt(parseSvgLength("12pt")), 12.0)
  check close(lengthToPt(parseSvgLength("50%"), 200.0), 100.0)
