## Writer-side font pipeline: measure, subset, embed, draw, wrap.
##
## The font program is the full DejaVuSans from the sibling harfbuzz
## checkout when present; otherwise our own m3b_text.pdf fixture
## (embedded subset holding only A, B, C) covers the same paths with
## ABC-only text.
import std/os
import std/strutils
import std/tables
import std/unicode
import unittest
import ../src/opengraphics/pdf

const
  TextPdf = "tests/data/pdf/m3b_text.pdf"
  DejaVuPath = "../harfbuzz/tests/data/DejaVuSans.ttf"

proc subsetProgram(): string =
  var d = openDoc(readFile(TextPdf))
  var fonts = d.pageResources(1).dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  var font = fonts.dictGet("F2")
  if font.kind == coRef:
    font = d.resolve(font)
  loadFontBytes(font, d)

proc fontProgram(): string =
  if fileExists(DejaVuPath):
    readFile(DejaVuPath)
  else:
    subsetProgram()

proc demoText(): string =
  if fileExists(DejaVuPath): "Hello writer" else: "ABC BAC"

proc runesOf(s: string): seq[uint32] =
  for r in s.runes:
    result.add(uint32(r))

test "measureText sanity":
  var sf = openShapedFont(fontProgram())
  defer: close(sf)
  let t = demoText()
  check measureText(sf, "", 12.0) == 0.0
  check measureText(sf, " ", 12.0) > 0.0
  check measureText(sf, t, 12.0) > measureText(sf, $t[0], 12.0)
  check measureText(sf, t, 24.0) == 2.0 * measureText(sf, t, 12.0)
  if fileExists(DejaVuPath):
    check measureText(sf, "ii", 12.0) < measureText(sf, "mm", 12.0)

test "winAnsiByte mapping":
  check winAnsiByte(Rune(0x41)) == 65
  check winAnsiByte(Rune(0xE9)) == 0xE9
  check winAnsiByte(Rune(0x20AC)) == 0x80
  check winAnsiByte(Rune(0x4E2D)) == -1

test "noteUse records codes":
  var u = FontUse(fontBytes: fontProgram(), baseName: "DejaVuSans")
  u.noteUse(demoText())
  check u.codes.len > 0
  expect(PdfError):
    u.noteUse("日本語")

test "wrapText breaks on shaped width":
  var sf = openShapedFont(fontProgram())
  defer: close(sf)
  let t3 = if fileExists(DejaVuPath): "Hello brave writer"
    else: "ABC BAC CAB"
  let words = strutils.split(t3, ' ')
  let w = measureText(sf, words[0] & " " & words[1], 12.0)
  check wrapText(sf, t3, 12.0, w) ==
    @[words[0] & " " & words[1], words[2]]
  check wrapText(sf, "A\nB", 12.0, w * 4.0) == @["A", "B"]
  check wrapText(sf, words[0] & "x-long-word " & words[1], 12.0, w) ==
    @[words[0] & "x-long-word", words[1]]

test "subset keeps used glyphs":
  let prog = subsetProgram()
  let sub = subsetFont(prog, runesOf("AB"))
  check sub.len > 0
  check sub.len <= prog.len
  var sf = openShapedFont(sub)
  defer: close(sf)
  check sf.nominalGlyph(uint32('A')) != 0

test "full DejaVu subset is tiny":
  if fileExists(DejaVuPath):
    let full = readFile(DejaVuPath)
    check full.len > 500_000
    let sub = subsetFont(full, runesOf("Hello writer"))
    check sub.len > 0
    check sub.len < 50_000
    var sf = openShapedFont(sub)
    defer: close(sf)
    check sf.nominalGlyph(uint32('H')) != 0
  else:
    echo "no sibling harfbuzz checkout; full-font subset skipped"

proc embeddedDemo(): string =
  let t = demoText()
  var use = FontUse(fontBytes: fontProgram(), baseName: "DejaVuSans")
  use.noteUse(t)
  let content = drawTextLine(72.0, 720.0, "F2", 24.0, t)
  var b = newPdfBuilder()
  let fonts = b.finalizeFonts({"F2": use}.toTable)
  let cnum = b.addContentStream(content)
  discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
  b.buildPdf()

test "embedded font round-trips text":
  var d = openDoc(embeddedDemo())
  check d.pageCount() == 1
  var texts: seq[string] = @[]
  for r in d.extractText(0):
    texts.add(r.text)
  check texts == @[demoText()]

test "embedded font has full Widths range":
  let t = demoText()
  var first = 256
  var last = -1
  for r in t.runes:
    let b = winAnsiByte(r)
    first = min(first, b)
    last = max(last, b)
  var d = openDoc(embeddedDemo())
  var fonts = d.pageResources(0).dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  var font = fonts.dictGet("F2")
  if font.kind == coRef:
    font = d.resolve(font)
  let widths = font.dictGet("Widths")
  check widths.kind == coArray
  check font.dictGet("FirstChar").ival == first
  check font.dictGet("LastChar").ival == last
  check widths.items.len == last - first + 1

test "finalizeFonts is deterministic":
  check embeddedDemo() == embeddedDemo()

test "embedFont rejects empty codes":
  var b = newPdfBuilder()
  expect(PdfError):
    discard b.embedFont("DejaVuSans", fontProgram(),
      initTable[int, uint32]())

test "subsetFont rejects empty program":
  expect(PdfError):
    discard subsetFont("", runesOf("Hi"))
