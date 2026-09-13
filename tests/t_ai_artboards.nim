import std/strutils
import unittest
import ../src/opengraphics/ai
import ./ai_support

test "page sizes map to artboards in order":
  let doc = readAiBytes(buildAiPdf(@[
    PageSpec(w: 612.0, h: 792.0),
    PageSpec(w: 200.0, h: 100.0),
  ], extraBody = "% /AIPrivateData"))
  check doc.artboardCount == 2
  check doc.artboards[0].index == 0
  check doc.artboards[0].width == 612.0
  check doc.artboards[0].height == 792.0
  check doc.artboards[0].name == ""
  check doc.artboards[1].index == 1
  check doc.artboards[1].width == 200.0
  check doc.artboards[1].height == 100.0

test "mediabox inherited from pages node":
  let doc = readAiBytes(buildAiPdf(
    @[PageSpec(w: 0.0, h: 0.0, omitBox: true)],
    pagesExtra = " /MediaBox [0 0 300 300]"))
  check doc.artboardCount == 1
  check doc.artboards[0].width == 300.0
  check doc.artboards[0].height == 300.0

test "nested pages nodes walked depth-first":
  let doc = readAiBytes(assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 3 >>",
    "<< /Type /Pages /Parent 2 0 R /Kids [5 0 R 6 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
    "<< /Type /Page /Parent 3 0 R /MediaBox [0 0 200 200] >>",
    "<< /Type /Page /Parent 3 0 R /MediaBox [0 0 300 50] >>",
  ]))
  # document order is a depth-first traversal: 5, 6, then 4
  check doc.artboardCount == 3
  check doc.artboards[0].width == 200.0
  check doc.artboards[0].height == 200.0
  check doc.artboards[1].width == 300.0
  check doc.artboards[1].height == 50.0
  check doc.artboards[2].width == 100.0
  check doc.artboards[2].height == 100.0

test "missing mediabox rejected":
  expect(AiError):
    discard readAiBytes(buildAiPdf(
      @[PageSpec(w: 0.0, h: 0.0, omitBox: true)]))

test "page count limit enforced before walk":
  let data = buildAiPdf(@[
    PageSpec(w: 10.0, h: 10.0),
    PageSpec(w: 10.0, h: 10.0),
    PageSpec(w: 10.0, h: 10.0),
  ])
  expect(AiError):
    discard readAiBytes(data, AiLimits(maxPages: 2, maxScanBytes: 8192))

test "compressed xref stream names v2 support":
  var data = "%PDF-1.5\n"
  let xoff = data.len
  data.add("5 0 obj\n<< /Type /XRef /Size 6 /Root 1 0 R >>\n" &
    "stream\nendstream\nendobj\n")
  data.add("startxref\n" & $xoff & "\n%%EOF\n")
  var msg = ""
  try:
    discard readAiBytes(data)
  except AiError as e:
    msg = e.msg
  check "xref stream" in msg

test "xmp metadata parsed":
  let doc = readAiBytes(buildAiPdf(@[PageSpec(w: 10.0, h: 10.0)],
    extraBody = "% /AIPrivateData", xmpPacket = XmpSample))
  check doc.xmp.found
  check doc.xmp.title == "Test Doc"
  check doc.xmp.creator == "George"
  check doc.xmp.createDate == "2026-09-13T10:00:00"
  check doc.xmp.isIllustratorDoc

test "missing xmp is not an error":
  let doc = readAiBytes(buildAiPdf(@[PageSpec(w: 10.0, h: 10.0)]))
  check not doc.xmp.found
  check doc.xmp.title == ""

test "malformed xmp degrades without raising":
  let doc = readAiBytes(buildAiPdf(@[PageSpec(w: 10.0, h: 10.0)],
    xmpPacket = "<?xpacket begin=\"x\" id=\"y\"?><broken><oops>" &
      "<?xpacket end=\"w\"?>"))
  check doc.xmp.found
  check doc.xmp.title == ""
  check not doc.xmp.isIllustratorDoc
