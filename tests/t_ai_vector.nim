import std/math
import std/options
import std/os
import std/strutils
import unittest
import opendocs/pdf/docmodel
import opendocs/pdf/text
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
  "BT /F1 12 Tf 1 0 0 1 10 80 Tm (Hi) Tj 0 -14 TD (Lo) Tj ET\n" &
  "BT /F1 12 Tf 1 0 0 1 10 50 Tm [(He) -50 (llo)] TJ ET\n" &
  "/Fm1 Do\n" &
  "q 50 0 0 25 10 10 cm /Im1 Do Q\n" &
  "/Sh1 sh\n" &
  "/GS1 gs\n" &
  "ZZ\n" &
  "q 1 0 0 rg 150 5 20 10 re f Q\n" &
  "170 5 20 10 re f\n" &
  "0 0 200 100 re W n\n" &
  "0 0 1 rg 0 40 200 20 re f\n"

const FormContent =
  "BT /F1 12 Tf 1 0 0 1 100 30 Tm (Hi) Tj ET"

proc streamObj(payload: string): string =
  "<< /Length " & $payload.len & " >>\nstream\n" & payload & "\nendstream"

proc aiObjects(): seq[string] =
  let fontBytes = readFile("tests" / "data" / "fonts" / "ai-micro.ttf")
  @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] " &
      "/Resources << /Font << /F1 8 0 R >> " &
      "/XObject << /Im1 5 0 R /Fm1 10 0 R >> " &
      "/Shading << /Sh1 6 0 R >> >> /Contents 4 0 R >>",
    streamObj(Content),
    "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 " &
      "/ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\n" &
      "stream\n\x80\nendstream",
    "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 200 0] " &
      "/Function 7 0 R /Extend [true true] >>",
    "<< /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >>",
    "<< /Type /Font /Subtype /TrueType /BaseFont /DejaVuSans " &
      "/Encoding /WinAnsiEncoding /FontDescriptor 11 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Courier " &
      "/Encoding << /Type /Encoding /Differences [72 /A] >> >>",
    "<< /Type /XObject /Subtype /Form /BBox [0 0 200 100] " &
      "/Resources << /Font << /F1 9 0 R >> >> " &
      "/Length " & $FormContent.len & " >>\nstream\n" & FormContent &
      "\nendstream",
    "<< /Type /FontDescriptor /FontName /DejaVuSans /Flags 32 " &
      "/FontBBox [0 0 1000 1000] /ItalicAngle 0 /Ascent 800 " &
      "/Descent -200 /CapHeight 700 /StemV 80 /FontFile2 12 0 R >>",
    "<< /Length " & $fontBytes.len & " >>\nstream\n" & fontBytes &
      "\nendstream",
    "% /AIPrivateData",
  ]

proc aiBytes(): string = assemblePdf(aiObjects())

proc aiVectors(): VecDocument = readAiVectors(aiBytes())

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

test "text decodes with real fonts, positions, and paint":
  let doc = aiVectors()
  let hi = doc.layers[0].children[6]
  check hi.kind == vnkText
  check hi.text == "Hi"
  check hi.fontName == "F1"
  check close(hi.fontSize, 12.0)
  # Tm origin (10,80) y-up flips to (10,20) y-down
  let o = applyXform(hi.xform, vecPt(0, 0))
  check close(o.x, 10.0) and close(o.y, 20.0)
  # the active fill (green via cs/sc) paints the text
  check hi.textFill.kind == vpkSolid
  check close(hi.textFill.solid.g, 1.0)

test "embedded runs shape with real advances and outlines":
  let doc = aiVectors()
  let hi = doc.layers[0].children[6]
  check hi.glyphs.len == 2
  check hi.glyphs[0].advance > hi.glyphs[1].advance
  check hi.glyphs[1].advance > 0.0
  check hi.glyphs[0].cluster == 0
  check hi.glyphs[1].cluster == 1
  check hi.outline.isSome
  let b = pathBounds(hi.outline.get())
  # a 12pt "Hi" is wider than tall-ish and sits near the run origin
  check b.x1 - b.x0 > 5.0
  check b.y1 - b.y0 > 5.0
  check b.y1 - b.y0 < 20.0

test "unembedded runs keep advances but gain no outlines":
  let doc = aiVectors()
  let xi = doc.layers[0].children[10]
  check xi.glyphs.len == 0
  check xi.outline.isNone
  var sawFontWarn = false
  for w in doc.warnings:
    if "has no embedded program" in w or "cannot shape runs" in w:
      sawFontWarn = true
  check sawFontWarn

test "TD breaks the line from the line matrix":
  let doc = aiVectors()
  let lo = doc.layers[0].children[7]
  check lo.text == "Lo"
  let o = applyXform(lo.xform, vecPt(0, 0))
  # Td restarts from Tlm: (10,80) moved by (0,-14) -> (10,66) -> (10,34)
  check close(o.x, 10.0) and close(o.y, 34.0)

test "TJ kernings split runs and shift the matrix":
  let doc = aiVectors()
  let he = doc.layers[0].children[8]
  let llo = doc.layers[0].children[9]
  check he.text == "He"
  check llo.text == "llo"
  let o = applyXform(llo.xform, vecPt(0, 0))
  # "He" advances two 500-unit missing widths at 12pt (12.0), then the
  # -50 kerning shifts +0.6: 10 + 12 + 0.6 = 22.6
  check close(o.x, 22.6) and close(o.y, 50.0)

test "a form shadows /F1 with its own decoder":
  let doc = aiVectors()
  let xi = doc.layers[0].children[10]
  check xi.kind == vnkText
  # the form's /F1 maps H(72) to /A through /Differences
  check xi.text == "Ai"
  let o = applyXform(xi.xform, vecPt(0, 0))
  check close(o.x, 100.0) and close(o.y, 70.0)

test "text matches extractText run for run":
  var d = openPdfDoc(aiBytes())
  let runs = d.extractText(0)
  let doc = aiVectors()
  var nodes: seq[VecNode] = @[]
  for layer in doc.layers:
    for n in layer.children:
      if n.kind == vnkText:
        nodes.add(n)
  check nodes.len == runs.len
  for i in 0 ..< runs.len:
    check nodes[i].text == runs[i].text
    let o = applyXform(nodes[i].xform, vecPt(0, 0))
    check close(o.x, runs[i].x)
    check close(o.y, 100.0 - runs[i].y)
    check close(nodes[i].fontSize, runs[i].size)
    check nodes[i].fontName == runs[i].fontName

test "images keep name and placement":
  let doc = aiVectors()
  let im = doc.layers[0].children[11]
  check im.kind == vnkImage
  check im.imageKey == "Im1"
  check close(im.imageRect.x0, 10.0) and close(im.imageRect.x1, 60.0)
  check close(im.imageRect.y0, 65.0) and close(im.imageRect.y1, 90.0)

test "axial shading maps to a linear gradient":
  let doc = aiVectors()
  let n = doc.layers[0].children[12]
  check n.kind == vnkPath
  check n.fill.kind == vpkLinear
  check n.fill.gradient.stops.len == 9
  check close(n.fill.gradient.stops[0].color.r, 1.0)
  check close(n.fill.gradient.stops[8].color.b, 1.0)
  check close(n.fill.gradient.x1, 200.0)

test "paint restores across q/Q instead of leaking":
  let doc = aiVectors()
  let inside = doc.layers[0].children[13]
  check inside.fill.kind == vpkSolid
  check close(inside.fill.solid.r, 1.0)
  let after = doc.layers[0].children[14]
  check after.fill.kind == vpkSolid
  check close(after.fill.solid.g, 1.0)

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
    if "HarfBuzz-shaped" in w: sawText = true
    if "not its pixels" in w: sawImage = true
    if "artboard box" in w: sawShade = true
  check sawUnknown and sawGs and sawText and sawImage and sawShade
