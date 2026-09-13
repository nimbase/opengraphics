## Synthetic PDF-based .ai builder for tests (stdlib only).
##
## Assembles minimal valid PDFs from object bodies: header, objects with
## tracked offsets, classic xref table, trailer, startxref, %%EOF.
## Markers and XMP go in as raw body text; detection and XMP parsing
## are string scans, so unreferenced objects are sufficient.

type
  PageSpec* = object
    w*, h*: float
    omitBox*: bool

proc pageObj*(parent: int, spec: PageSpec): string =
  result = "<< /Type /Page /Parent " & $parent & " 0 R"
  if not spec.omitBox:
    result.add(" /MediaBox [0 0 " & $spec.w & " " & $spec.h & "]")
  result.add(" >>")

proc assemblePdf*(objs: seq[string]): string =
  result = "%PDF-1.5\n%\xE2\xE3\xCF\xD3\n"
  var offsets: seq[int] = @[]
  for i, body in objs:
    offsets.add(result.len)
    result.add($(i + 1) & " 0 obj\n")
    result.add(body)
    result.add("\nendobj\n")
  let xrefPos = result.len
  result.add("xref\n0 " & $(objs.len + 1) & "\n")
  result.add("0000000000 65535 f \n")
  for off in offsets:
    var s = $off
    while s.len < 10:
      s = "0" & s
    result.add(s & " 00000 n \n")
  result.add("trailer\n<< /Size " & $(objs.len + 1) &
    " /Root 1 0 R >>\n")
  result.add("startxref\n" & $xrefPos & "\n%%EOF\n")

proc buildAiPdf*(pages: seq[PageSpec], extraBody = "", xmpPacket = "",
    pagesExtra = ""): string =
  ## Flat catalog, one /Pages node (object 2), page dicts from object 3.
  ## pagesExtra is appended inside the /Pages dict (e.g. a parent
  ## /MediaBox for the inheritance test).
  var objs: seq[string] = @[]
  var kids = ""
  for i in 0 ..< pages.len:
    if kids.len > 0:
      kids.add(" ")
    kids.add($(i + 3) & " 0 R")
  objs.add("<< /Type /Catalog /Pages 2 0 R >>")
  objs.add("<< /Type /Pages /Kids [" & kids & "] /Count " & $pages.len &
    pagesExtra & " >>")
  for spec in pages:
    objs.add(pageObj(2, spec))
  if extraBody.len > 0:
    objs.add(extraBody)
  if xmpPacket.len > 0:
    objs.add("<< /Type /Metadata /Subtype /XML /Length " &
      $xmpPacket.len & " >>\nstream\n" & xmpPacket & "\nendstream")
  assemblePdf(objs)

const XmpSample* = """<?xpacket begin="x" id="xmp-test"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:illustrator="http://ns.adobe.com/illustrator/1.0/">
   <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Test Doc</rdf:li></rdf:Alt></dc:title>
   <dc:creator><rdf:Seq><rdf:li>George</rdf:li></rdf:Seq></dc:creator>
   <xmp:CreateDate>2026-09-13T10:00:00</xmp:CreateDate>
   <illustrator:Type>Document</illustrator:Type>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"""
