## M3b tests: CMaps, encodings, positioned extraction, shaping.
##
## Fixture tests/data/pdf/m3b_text.pdf (see tests/gen_pdf_fixtures.nim):
## page 0 WinAnsi Helvetica with Tj, TJ kerning and a quote op;
## page 1 subset DejaVuSans TrueType with ToUnicode, Widths and an
## embedded FontFile2 (font bytes read back out of the PDF, so tests
## stay hermetic).

import std/math
import std/tables
import unittest
import ../src/opengraphics/pdf
import ./pdf_support

const TextPdf = "tests/data/pdf/m3b_text.pdf"

test "bfchar maps codes":
  let cm = parseToUnicode(
    "2 beginbfchar\n<01> <0041>\n<02> <0048>\nendbfchar\n")
  check cm.entries[1] == "A"
  check cm.entries[2] == "H"
  check cm.maxKeyLen == 1

test "bfrange single destination increments":
  let cm = parseToUnicode(
    "1 beginbfrange\n<0A> <0C> <0060>\nendbfrange\n")
  check cm.entries[10] == "`"
  check cm.entries[11] == "a"
  check cm.entries[12] == "b"

test "bfrange array destination":
  let cm = parseToUnicode(
    "1 beginbfrange\n<20> <22> [<0041> <0042> <0043>]\nendbfrange\n")
  check cm.entries[0x20] == "A"
  check cm.entries[0x22] == "C"

test "surrogate pair decodes":
  let cm = parseToUnicode("1 beginbfchar\n<01> <D83DDE00>\nendbfchar\n")
  check cm.entries[1] == "\xF0\x9F\x98\x80"

test "two-byte codes set key length":
  let cm = parseToUnicode("1 beginbfchar\n<0001> <0041>\nendbfchar\n")
  check cm.maxKeyLen == 2
  check cm.entries[1] == "A"

test "glyph names":
  check glyphNameToUnicode("Aacute") == 193
  check glyphNameToUnicode("uni00E9") == 233
  check glyphNameToUnicode("u1F600") == 128512
  check glyphNameToUnicode("A") == 65
  check glyphNameToUnicode("fi") == 64257
  check glyphNameToUnicode("NoSuchGlyphXYZ") == -1

test "byte tables":
  check winAnsiTable[0x96] == 8211
  check winAnsiTable[0x81] == -1
  check winAnsiTable[0x41] == 65
  check macRomanTable[0xF0] == 63743
  check macRomanTable[0x80] == 196

test "winansi run with en dash":
  var d = openDoc(readFile(TextPdf))
  let runs = d.extractText(0)
  check runs[0].text == "Hello \xE2\x80\x93 world"
  check abs(runs[0].x - 72.0) < 1e-6
  check abs(runs[0].y - 720.0) < 1e-6
  check abs(runs[0].size - 24.0) < 1e-9
  check runs[0].fontName == "F1"

test "TJ kerning shifts positions":
  var d = openDoc(readFile(TextPdf))
  let runs = d.extractText(0)
  check runs[1].text == "A"
  check runs[2].text == "B"
  check runs[3].text == "C"
  check abs(runs[1].x - 72.0) < 1e-6
  check abs(runs[2].x - 81.12) < 1e-6
  check abs(runs[3].x - 93.84) < 1e-6
  check runs[4].text == "Q1"

test "subset truetype through tounicode":
  var d = openDoc(readFile(TextPdf))
  let runs = d.extractText(1)
  check runs.len == 1
  check runs[0].text == "ABC"
  check abs(runs[0].x - 72.0) < 1e-6
  check abs(runs[0].y - 700.0) < 1e-6
  check runs[0].fontName == "F2"

test "differences encoding":
  let data = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /Font << /F3 5 0 R >> >> /Contents 4 0 R >>",
    streamObj("", "BT /F3 12 Tf 10 10 Td (\\103) Tj ET"),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica " &
      "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding " &
      "/Differences [67 /Aacute] >> >>",
  ])
  var d = openDoc(data)
  check d.extractText(0)[0].text == "\xC3\x81"

test "unknown difference name becomes replacement":
  let data = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /Font << /F3 5 0 R >> >> /Contents 4 0 R >>",
    streamObj("", "BT /F3 12 Tf 10 10 Td (A) Tj ET"),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica " &
      "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding " &
      "/Differences [65 /NoSuchGlyphXYZ] >> >>",
  ])
  var d = openDoc(data)
  check d.extractText(0)[0].text == "\xEF\xBF\xBD"

test "text without font fails":
  let data = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Contents 4 0 R >>",
    streamObj("", "BT (Hi) Tj ET"),
  ])
  var d = openDoc(data)
  expect(PdfError):
    discard d.extractText(0)

proc fontBytes(d: var PdfDoc, page: int, name: string): string =
  var fonts = d.pageResources(page).dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  var font = fonts.dictGet(name)
  if font.kind == coRef:
    font = d.resolve(font)
  loadFontBytes(font, d)

test "embedded font loads from fixture":
  var d = openDoc(readFile(TextPdf))
  let bytes = fontBytes(d, 1, "F2")
  check bytes.len > 100
  check bytes[0] == '\x00' and bytes[1] == '\x01'

test "shaping subset text":
  var d = openDoc(readFile(TextPdf))
  let shaped = shapeText(fontBytes(d, 1, "F2"), "ABC")
  check shaped.glyphs.len == 3
  for g in shaped.glyphs:
    check g.glyphId != 0
    check g.xAdvance > 0.0

test "shaping empty text is empty":
  var d = openDoc(readFile(TextPdf))
  check shapeText(fontBytes(d, 1, "F2"), "").glyphs.len == 0

test "base-14 font has no program":
  var d = openDoc(readFile(TextPdf))
  expect(PdfError):
    discard fontBytes(d, 0, "F1")
