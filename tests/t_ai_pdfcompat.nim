import unittest
import ../src/opengraphics/ai
import ./ai_support

const Content = "1 0 0 rg 10 10 90 80 re f"

proc contentObj(payload: string): string =
  "<< /Length " & $payload.len & " >>\nstream\n" & payload & "\nendstream"

proc opNames(page: AiPdfPage): seq[string] =
  for op in page.ops:
    result.add(op.op.name)

test "pdf-compatible ai exposes walked page operators":
  let data = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] " &
      "/Resources << >> /Contents 4 0 R >>",
    contentObj(Content),
    "% /AIPrivateData",
  ])
  let doc = openAiPdf(data)
  check doc.pages.len == 1
  check doc.pages[0].width == 200.0
  check doc.pages[0].height == 100.0
  check opNames(doc.pages[0]) == @["rg", "re", "f"]
  check doc.pages[0].ops[1].depth == 0
  check doc.pages[0].ops[1].ctm == [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]

test "pdf-compatible ai content failures stay ai errors":
  expect(AiError):
    discard openAiPdf("%PDF-1.5\ntrailerless")
