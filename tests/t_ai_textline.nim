## Point-type line gathering.
##
## Unit tests drive gatherTextLines with hand-built nodes (no PDF
## needed); the integration test runs a small Courier PDF through
## readAiVectors, exercising pen-delta advances for unshaped runs.
import std/math
import std/options
import std/strutils
import unittest
import ../src/opengraphics/ai
import ./ai_support

proc close(a, b: float64): bool = abs(a - b) < 1e-6

proc textNode(text: string, x, y: float64,
    dir = vecPt(1.0, 0.0), advance = 0.0, size = 12.0,
    font = "F1", fill = solidPaint(rgbColor(0, 0, 0)),
    hscale = 100.0, glyphs: seq[VecGlyph] = @[],
    outline = none(VecPath)): VecNode =
  VecNode(kind: vnkText, name: "", opacity: 1.0,
    xform: translateXform(x, y), text: text, fontName: font,
    fontSize: size, textFill: fill, baseDir: dir, advance: advance,
    textHScale: hscale, glyphs: glyphs, outline: outline)

proc pathNode(): VecNode =
  var sub = VecSubPath()
  moveTo(sub, vecPt(0, 0))
  lineTo(sub, vecPt(1, 1))
  VecNode(kind: vnkPath, name: "", opacity: 1.0,
    xform: identityXform(), path: VecPath(subs: @[sub]),
    fill: solidPaint(rgbColor(1, 0, 0)), stroke: defaultStroke(),
    hasStroke: false)

proc texts(nodes: seq[VecNode]): seq[string] =
  for n in nodes:
    if n.kind == vnkText:
      result.add(n.text)

test "adjacent runs merge without space":
  let g = gatherTextLines(@[
    textNode("He", 10, 20, advance = 12.0),
    textNode("llo", 22, 20, advance = 18.0)])
  check g.notes.len == 0
  check texts(g.nodes) == @["Hello"]
  check g.nodes[0].advance == 30.0
  let o = applyXform(g.nodes[0].xform, vecPt(0, 0))
  check close(o.x, 10.0) and close(o.y, 20.0)

test "wide gaps read as a space":
  let g = gatherTextLines(@[
    textNode("Hello", 10, 20, advance = 30.0),
    textNode("World", 60, 20, advance = 30.0)])
  check texts(g.nodes) == @["Hello World"]

test "a second line starts below the first":
  let g = gatherTextLines(@[
    textNode("Hi", 10, 20, advance = 12.0),
    textNode("Lo", 10, 34, advance = 12.0)])
  check texts(g.nodes) == @["Hi", "Lo"]

test "look change splits the line but keeps the space":
  let red = solidPaint(rgbColor(1, 0, 0))
  let g = gatherTextLines(@[
    textNode("Hello", 10, 20, advance = 30.0),
    textNode("World", 60, 20, advance = 30.0, fill = red)])
  check texts(g.nodes) == @["Hello ", "World"]

test "sizes gather within one percent":
  let same = gatherTextLines(@[
    textNode("A", 10, 20, advance = 7.0, size = 12.0),
    textNode("B", 17, 20, advance = 7.0, size = 12.1)])
  check texts(same.nodes) == @["AB"]
  let split = gatherTextLines(@[
    textNode("A", 10, 20, advance = 7.0, size = 12.0),
    textNode("B", 17, 20, advance = 7.0, size = 12.2)])
  check texts(split.nodes) == @["A", "B"]

test "rotated runs end the line with one note":
  let g = gatherTextLines(@[
    textNode("A", 10, 20, advance = 7.0),
    textNode("B", 17, 21, advance = 7.0,
      dir = vecPt(0.9848, 0.1736)),
    textNode("C", 24, 23, advance = 7.0,
      dir = vecPt(0.9397, 0.3420))])
  check texts(g.nodes) == @["A", "B", "C"]
  check g.notes.len == 1
  check "type on a path" in g.notes[0]

test "a vertical line gathers along its own axis":
  let g = gatherTextLines(@[
    textNode("A", 10, 10, dir = vecPt(0, 1), advance = 12.0),
    textNode("B", 10, 22, dir = vecPt(0, 1), advance = 12.0)])
  check texts(g.nodes) == @["AB"]
  # the xform turns +x into +y at the line origin
  let p = applyXform(g.nodes[0].xform, vecPt(1, 0))
  check close(p.x, 10.0) and close(p.y, 11.0)

test "axis singletons keep pure-translation xforms":
  let g = gatherTextLines(@[textNode("Hi", 10, 20, advance = 12.0)])
  check g.nodes[0].xform == translateXform(10.0, 20.0)

test "whitespace-only lines drop":
  let g = gatherTextLines(@[textNode("   ", 10, 20, advance = 5.0)])
  check g.nodes.len == 0

test "paths break lines and groups recurse":
  let inner = gatherTextLines(@[
    textNode("He", 10, 20, advance = 12.0),
    textNode("llo", 22, 20, advance = 18.0)])
  check texts(inner.nodes) == @["Hello"]
  let outer = gatherTextLines(@[
    textNode("A", 10, 20, advance = 7.0),
    pathNode(),
    textNode("B", 17, 20, advance = 7.0)])
  check outer.nodes.len == 3
  check texts(outer.nodes) == @["A", "B"]
  let grp = VecNode(kind: vnkGroup, name: "g", opacity: 1.0,
    xform: identityXform(), children: @[
      textNode("He", 10, 20, advance = 12.0),
      textNode("llo", 22, 20, advance = 18.0)])
  let gg = gatherTextLines(@[grp])
  check gg.nodes.len == 1
  check gg.nodes[0].kind == vnkGroup
  check gg.nodes[0].name == "g"
  check texts(gg.nodes[0].children) == @["Hello"]

test "glyphs re-offset by absolute origins":
  let g = gatherTextLines(@[
    textNode("A", 10, 20, advance = 12.0, glyphs = @[
      VecGlyph(glyphId: 1, cluster: 0, dx: 0.0, dy: 0.0,
        advance: 12.0)]),
    textNode("B", 30, 20, advance = 12.0, glyphs = @[
      VecGlyph(glyphId: 2, cluster: 0, dx: 0.0, dy: 0.0,
        advance: 12.0)])])
  # gap 30 - (10 + 12) = 8 > 2.4: spaced, then merged with the gap
  # folded into the second glyph's offset
  check texts(g.nodes) == @["A B"]
  check g.nodes[0].glyphs.len == 2
  check close(g.nodes[0].glyphs[1].dx, 20.0)

test "outlines concatenate in line space":
  proc box(x0: float64): VecPath =
    VecPath(subs: @[rectSubPath(vecRect(x0, 0, x0 + 5, 5))])
  let g = gatherTextLines(@[
    textNode("A", 10, 20, advance = 12.0, outline = some(box(0.0))),
    textNode("B", 22, 20, advance = 12.0, outline = some(box(0.0)))])
  check g.nodes[0].outline.isSome
  let b = pathBounds(g.nodes[0].outline.get())
  check close(b.x0, 0.0) and close(b.x1, 17.0)

const TContent =
  "BT /F1 12 Tf 1 0 0 1 10 80 Tm (Hello) Tj ET\n" &
  "BT /F1 12 Tf 1 0 0 1 70 80 Tm (World) Tj ET\n" &
  "BT /F1 12 Tf 0 1 -1 0 30 10 Tm (Down) Tj ET\n"

proc tBytes(): string =
  assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] " &
      "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    "<< /Length " & $TContent.len & " >>\nstream\n" & TContent &
      "\nendstream",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Courier " &
      "/Encoding /WinAnsiEncoding >>",
  ])

test "integration: spaced words gather, rotated runs split":
  # Courier is unshaped here, so advances come from pen travel:
  # "Hello" is 5 x 7.2 = 36pt, the gap to "World" at x=70 is wide.
  let doc = readAiVectors(tBytes())
  check doc.layers.len == 1
  var got: seq[string] = @[]
  for n in doc.layers[0].children:
    if n.kind == vnkText:
      got.add(n.text)
  check got == @["Hello World", "Down"]
  var sawCurve = false
  for w in doc.warnings:
    if "type on a path" in w:
      sawCurve = true
  check sawCurve
