import std/math
import std/strutils
import unittest
import ../src/opengraphics/ai

proc close(a, b: float64): bool = abs(a - b) < 1e-6

proc sampleDoc(): VecDocument =
  result = VecDocument()
  result.artboards.add(VecArtboard(name: "A",
    rect: vecRect(0, 0, 200, 100)))
  var layer = VecLayer(name: "L", visible: true, locked: false)
  var sub = VecSubPath()
  moveTo(sub, vecPt(10, 10))
  lineTo(sub, vecPt(60, 10))
  lineTo(sub, vecPt(60, 40))
  sub.closed = true
  var p = newPathNode(VecPath(subs: @[sub]),
    solidPaint(rgbColor(1, 0, 0)), "red-tri")
  p.hasStroke = true
  p.stroke.width = 2.0
  p.stroke.paint = solidPaint(rgbColor(0, 0, 0))
  layer.children.add(p)
  let g = VecGradient(kind: vgkLinear, xform: identityXform(),
    objectBoundingBox: false, spread: vspPad,
    x0: 70, y0: 10, x1: 120, y1: 10,
    stops: @[VecGradientStop(offset: 0, color: rgbColor(1, 0, 0)),
      VecGradientStop(offset: 1, color: rgbColor(0, 0, 1))])
  layer.children.add(newPathNode(
    VecPath(subs: @[rectSubPath(vecRect(70, 10, 120, 40))]),
    VecPaint(kind: vpkLinear, gradient: g), "grad-rect"))
  result.layers.add(layer)

test "writer emits a valid pdf with readable operators":
  var doc = sampleDoc()
  let rep = writeAi(doc)
  check rep.bytes.startsWith("%PDF-")
  check "%%EOF" in rep.bytes
  check "10 90 m" in rep.bytes # y-down 10 flips to y-up 90
  check "1 0 0 rg" in rep.bytes
  check "2 w" in rep.bytes
  check "/Pattern cs" in rep.bytes
  check "/ShadingType" in rep.bytes
  check rep.warnings.len == 0

test "written file rereads to the same artwork":
  var doc = sampleDoc()
  let rep = writeAi(doc)
  let back = readAiVectors(rep.bytes)
  check back.artboards.len == 1
  check close(back.artboards[0].rect.x1, 200.0)
  check back.layers[0].children.len == 2
  let tri = back.layers[0].children[0]
  check tri.kind == vnkPath
  check close(tri.fill.solid.r, 1.0)
  check tri.hasStroke and close(tri.stroke.width, 2.0)
  let b = pathBounds(tri.path)
  check close(b.x0, 10.0) and close(b.y0, 10.0)
  check close(b.x1, 60.0) and close(b.y1, 40.0)
  let gr = back.layers[0].children[1]
  check gr.fill.kind == vpkLinear
  check gr.fill.gradient.stops.len == 9 # exponential resampled
  check close(gr.fill.gradient.stops[0].color.r, 1.0)
  check close(gr.fill.gradient.stops[8].color.b, 1.0)

test "text, images, and patterns warn instead of vanishing":
  var doc = VecDocument()
  doc.artboards.add(VecArtboard(rect: vecRect(0, 0, 50, 50)))
  var layer = VecLayer(name: "L", visible: true, locked: false)
  layer.children.add(VecNode(kind: vnkText, name: "", opacity: 1.0,
    xform: identityXform(), text: "hi", fontName: "F",
    fontSize: 10, textFill: solidPaint(rgbColor(0, 0, 0))))
  layer.children.add(VecNode(kind: vnkImage, name: "", opacity: 1.0,
    xform: identityXform(), imageKey: "Im1",
    imageRect: vecRect(0, 0, 10, 10)))
  layer.children.add(newPathNode(
    VecPath(subs: @[rectSubPath(vecRect(0, 0, 10, 10))]),
    VecPaint(kind: vpkPattern, patternName: "tiles",
      patternXform: identityXform())))
  doc.layers.add(layer)
  let rep = writeAi(doc)
  check rep.warnings.len == 3
  let back = readAiVectors(rep.bytes)
  # text and image nodes were skipped; the pattern rect paints nothing
  # (a lone `n`), so nothing rereads
  check back.layers[0].children.len == 0

test "hidden layers are skipped loudly":
  var doc = VecDocument()
  doc.artboards.add(VecArtboard(rect: vecRect(0, 0, 50, 50)))
  doc.layers.add(VecLayer(name: "off", visible: false, locked: false))
  let rep = writeAi(doc)
  check rep.warnings.len == 1
  check "hidden layer" in rep.warnings[0]

test "no artboards fails":
  var doc = VecDocument()
  expect(AiError):
    discard writeAi(doc)
