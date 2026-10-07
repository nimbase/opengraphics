import std/math
import std/options
import std/strutils
import unittest
import ../src/opengraphics/ai
import ./ai_support

proc close(a, b: float64): bool = abs(a - b) < 1e-6

const Content =
  "1 0 0 rg 10 60 50 30 re f\n" &
  "0.5 g 70 60 50 30 re f\n" &
  "0 1 1 0 k 130 60 50 30 re f\n" &
  "150 70 20 10 re f*\n" &
  "/DeviceRGB cs 0 1 0 sc 10 40 30 10 re f\n" &
  "2 w 1 J [4 2] 0 d 0 0.5 0 RG 10 10 180 0 l S\n" &
  "BT /F1 12 Tf 1 0 0 1 10 80 Tm (Hi) Tj ET\n" &
  "q 50 0 0 25 10 10 cm /Im1 Do Q\n" &
  "/Sh1 sh\n" &
  "/GS1 gs\n" &
  "ZZ\n" &
  "0 0 200 100 re W n\n" &
  "0 0 1 rg 0 40 200 20 re f\n"

proc streamObj(payload: string): string =
  "<< /Length " & $payload.len & " >>\nstream\n" & payload & "\nendstream"

proc aiVectors(): VecDocument =
  let data = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] " &
      "/Resources << /XObject << /Im1 5 0 R >> " &
      "/Shading << /Sh1 6 0 R >> >> /Contents 4 0 R >>",
    streamObj(Content),
    "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 " &
      "/ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\n" &
      "stream\n\x80\nendstream",
    "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 200 0] " &
      "/Function 7 0 R /Extend [true true] >>",
    "<< /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >>",
    "% /AIPrivateData",
  ])
  readAiVectors(data)

test "pages become artboards and layers":
  let doc = aiVectors()
  check doc.artboards.len == 1
  check doc.artboards[0].rect.x1 == 200.0
  check doc.artboards[0].rect.y1 == 100.0
  check doc.layers.len == 1
  check doc.layers[0].name == "Page 1"

test "solid fills map with y flipped":
  let doc = aiVectors()
  let red = doc.layers[0].children[0]
  check red.kind == vnkPath
  check red.fill.kind == vpkSolid
  check close(red.fill.solid.r, 1.0)
  # y-up 60..90 on a 100pt page becomes y-down 10..40
  let b = pathBounds(red.path)
  check close(b.y0, 10.0) and close(b.y1, 40.0)
  check close(b.x0, 10.0) and close(b.x1, 60.0)
  let gray = doc.layers[0].children[1]
  check gray.fill.solid.space == vcsGray
  check close(gray.fill.solid.gray, 0.5)
  let cmyk = doc.layers[0].children[2]
  check cmyk.fill.solid.space == vcsCMYK
  check close(cmyk.fill.solid.m, 1.0)

test "evenodd rule and cs/sc paints map":
  let doc = aiVectors()
  check doc.layers[0].children[3].path.fillRule == vfrEvenOdd
  let viaCs = doc.layers[0].children[4]
  check viaCs.fill.kind == vpkSolid
  check close(viaCs.fill.solid.g, 1.0)

test "stroke state maps fully":
  let doc = aiVectors()
  let line = doc.layers[0].children[5]
  check line.hasStroke
  check close(line.stroke.width, 2.0)
  check line.stroke.cap == vlcRound
  check line.stroke.dash == @[4.0, 2.0]
  check close(line.stroke.paint.solid.g, 0.5)
  # a y-up horizontal line at y=10 sits at y-down 90
  let b = pathBounds(transformPath(line.path, line.xform))
  check close(b.y0, 90.0) and close(b.y1, 90.0)

test "text becomes a positioned placeholder":
  let doc = aiVectors()
  let t = doc.layers[0].children[6]
  check t.kind == vnkText
  check t.text == "Hi"
  check t.fontName == "F1"
  check close(t.fontSize, 12.0)
  # Tm origin (10,80) y-up flips to (10,20) y-down
  let o = applyXform(t.xform, vecPt(0, 0))
  check close(o.x, 10.0) and close(o.y, 20.0)

test "images keep name and placement":
  let doc = aiVectors()
  let im = doc.layers[0].children[7]
  check im.kind == vnkImage
  check im.imageKey == "Im1"
  check close(im.imageRect.x0, 10.0) and close(im.imageRect.x1, 60.0)
  check close(im.imageRect.y0, 65.0) and close(im.imageRect.y1, 90.0)

test "axial shading maps to a linear gradient":
  let doc = aiVectors()
  let n = doc.layers[0].children[8]
  check n.kind == vnkPath
  check n.fill.kind == vpkLinear
  check n.fill.gradient.stops.len == 9
  check close(n.fill.gradient.stops[0].color.r, 1.0)
  check close(n.fill.gradient.stops[8].color.b, 1.0)
  check close(n.fill.gradient.x1, 200.0)

test "clipping wraps later paints":
  let doc = aiVectors()
  let n = doc.layers[0].children[^1]
  check n.kind == vnkClip
  check n.clipRule == vfrNonZero
  let cb = pathBounds(n.clip)
  check close(cb.x1, 200.0) and close(cb.y1, 100.0)
  check n.clipped.len == 1
  check n.clipped[0].fill.solid.b == 1.0

test "unknown operators and gs warn once each":
  let doc = aiVectors()
  var sawUnknown = false
  var sawGs = false
  var sawText = false
  var sawImage = false
  var sawShade = false
  for w in doc.warnings:
    if "operator 'ZZ'" in w: sawUnknown = true
    if "ExtGState" in w: sawGs = true
    if "placeholder" in w: sawText = true
    if "not its pixels" in w: sawImage = true
    if "artboard box" in w: sawShade = true
  check sawUnknown and sawGs and sawText and sawImage and sawShade
