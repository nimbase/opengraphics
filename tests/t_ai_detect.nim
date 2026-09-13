import unittest
import ../src/opengraphics/ai
import ./ai_support

test "native ai detected with versions":
  let doc = readAiBytes(buildAiPdf(@[PageSpec(w: 612.0, h: 792.0)],
    extraBody = "% /AIPrivateData\n%AI5_FileFormat 14"))
  check doc.kind == AiNative
  check doc.pdfVersion == "1.5"
  check doc.aiFormatVersion == 14
  check doc.hasPrivateData
  check doc.artboardCount == 1
  check doc.artboards[0].width == 612.0
  check doc.artboards[0].height == 792.0

test "illustrator-saved pdf detected":
  let doc = readAiBytes(buildAiPdf(@[PageSpec(w: 100.0, h: 100.0)],
    extraBody = "% /AIPDFPrivateData"))
  check doc.kind == AiPdfExport
  check not doc.hasPrivateData
  check doc.aiFormatVersion == -1

test "plain pdf has no ai data":
  let doc = readAiBytes(buildAiPdf(@[PageSpec(w: 100.0, h: 100.0)]))
  check doc.kind == PdfWithoutAiData
  check not doc.hasPrivateData

test "native marker wins when both present":
  let doc = readAiBytes(buildAiPdf(@[PageSpec(w: 10.0, h: 10.0)],
    extraBody = "% /AIPDFPrivateData /AIPrivateData"))
  check doc.kind == AiNative

test "eps legacy detected then rejected":
  let data = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 100 100\n"
  check detectAi(data).kind == EpsLegacy
  expect(AiError):
    discard readAiBytes(data)

test "garbage and empty input rejected":
  check detectAi("hello, world").kind == Unknown
  expect(AiError):
    discard readAiBytes("hello, world")
  expect(AiError):
    discard readAiBytes("")

test "byte sequence input works":
  let s = buildAiPdf(@[PageSpec(w: 50.0, h: 60.0)],
    extraBody = "% /AIPrivateData")
  var b = newSeq[byte](s.len)
  for i, c in s:
    b[i] = byte(c)
  let doc = readAiBytes(b)
  check doc.kind == AiNative
  check doc.artboards[0].width == 50.0
