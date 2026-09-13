## PDF fixture generator (run manually, not a test).
##
## Writes genuine parseable PDFs under tests/data/pdf/ using the test
## assembler plus the real deflate encoder. Fixtures are checked in so
## tests stay hermetic; rerun after any assembler change:
##   clue run tests/gen_pdf_fixtures.nim   (or build + exec)
##
## Origin: synthetic, generated locally by this script. No licensing
## concerns. Each file: single/System Adler? No: plain classic xref,
## unencrypted, Flate or ASCIIHex content streams.

import std/os
import std/strutils
import ./pdf_support
import ../src/opengraphics/pdf

const OutDir = "tests/data/pdf"

proc toAsciiHex(s: string): string =
  const digits = "0123456789ABCDEF"
  for c in s:
    result.add(digits[ord(c) shr 4])
    result.add(digits[ord(c) and 0x0F])
  result.add('>')

proc streamFlate(payload: string): string =
  streamObj("/Filter /FlateDecode", deflateEncode(payload))

proc streamHex(payload: string): string =
  streamObj("/Filter /ASCIIHexDecode", toAsciiHex(payload))

proc writeBasic() =
  let c1 = "BT /F1 24 Tf 72 720 Td (Hello page one) Tj ET\n" &
    "q 1 0 0 1 10 10 cm BI /W 2 /H 1 /CS /G /BPC 8 ID " &
    "\xAA\xBB EI Q"
  let c2a = "BT /F1 12 Tf 1 0 0 1 50 700 Tm (Second) Tj ET"
  let c2b = "q 2 0 0 2 10 20 cm Q"
  let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F1 5 0 R >> >> " &
      "/Contents [7 0 R 8 0 R] >>",
    font,
    streamFlate(c1),
    streamHex(c2a),
    streamObj("", c2b),
  ]
  writeFile(OutDir / "m3a_basic.pdf", assemblePdf(objs))

proc writeUpdate() =
  ## Base revision says "First"; appended revision redefines contents
  ## to "Second" plus fresh page/pages/catalog objects and a /Prev
  ## trailer. Exercises incremental newest-wins through the page tree.
  let baseObjs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Contents 4 0 R >>",
    streamObj("", "BT (First) Tj ET"),
  ]
  var base = assemblePdf(baseObjs)
  let baseXref = base.find("xref\n")
  doAssert baseXref > 0, "base xref not found"
  var rev = ""
  var offsets: seq[int] = @[]
  let bodies = @[
    streamObj("", "BT (Second) Tj ET"), # 5: new contents
    "<< /Type /Page /Parent 7 0 R /MediaBox [0 0 200 200] " &
      "/Contents 5 0 R >>", # 6: new page
    "<< /Type /Pages /Kids [6 0 R] /Count 1 >>", # 7: new pages
    "<< /Type /Catalog /Pages 7 0 R >>", # 8: new catalog
  ]
  for i, body in bodies:
    offsets.add(base.len + rev.len)
    rev.add($(i + 5) & " 0 obj\n")
    rev.add(body)
    rev.add("\nendobj\n")
  let revXref = base.len + rev.len
  rev.add("xref\n0 1\n0000000000 65535 f \n5 4\n")
  for off in offsets:
    var s = $off
    while s.len < 10:
      s = "0" & s
    rev.add(s & " 00000 n \n")
  rev.add("trailer\n<< /Size 9 /Root 8 0 R /Prev " & $baseXref &
    " >>\nstartxref\n" & $revXref & "\n%%EOF\n")
  writeFile(OutDir / "m3a_update.pdf", base & rev)

proc sanity(path: string, pages, minOps: int) =
  let data = readFile(path)
  let doc = readPdfBytes(data)
  doAssert doc.pages.len == pages, path & ": page count " &
    $doc.pages.len
  var d = openDoc(data)
  var total = 0
  for i in 0 ..< pages:
    total += d.walkPageOps(i).len
  doAssert total >= minOps, path & ": only " & $total & " ops"
  echo "ok " & path & " (" & $total & " ops)"

createDir(OutDir)
writeBasic()
writeUpdate()
sanity(OutDir / "m3a_basic.pdf", 2, 8)
sanity(OutDir / "m3a_update.pdf", 1, 3)
