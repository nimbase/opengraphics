## Optional content group routing.
##
## Synthetic two-page PDF with a catalog /OCProperties: group "Top" on,
## group "Hidden" off, locked, and unprintable, plus a membership
## dictionary. Page art wrapped in /OC marked content must land on one
## layer per group (shared across pages); unmarked art and broken
## references stay on the page layer.
import std/strutils
import unittest
import ../src/opengraphics/ai
import ./ai_support

proc streamObj(payload: string): string =
  "<< /Length " & $payload.len & " >>\nstream\n" & payload & "\nendstream"

const Content1 =
  "EMC\n" & # stray close with nothing open: ignored, not fatal
  "1 0 0 rg 10 10 20 10 re f\n" &
  "/OC /mc0 BDC\n" &
  "0 0 1 rg 40 10 20 10 re f\n" &
  "/OC /mc1 BDC\n" &
  "0 1 0 rg 70 10 20 10 re f\n" &
  "EMC\n" &
  "0.5 g 100 10 20 10 re f\n" &
  "EMC\n" &
  "q\n/Fm1 Do\nQ\n" &
  "1 1 0 rg 160 10 20 10 re f\n"

const Content2 =
  "0 0 0 rg 10 10 20 10 re f\n" &
  "/OC /mc0 BDC\n" &
  "1 0 1 rg 40 10 20 10 re f\n" &
  "EMC\n" &
  "/OC /nope BDC\n" &
  "0 1 1 rg 70 10 20 10 re f\n" &
  "EMC\n" &
  "/OC /ocmd BDC\n" &
  "0.5 0 0.5 rg 100 10 20 10 re f\n" &
  "EMC\n"

const FormContent = "0 1 1 rg 130 10 20 10 re f"

proc ocgObjects(): seq[string] =
  @[
    "<< /Type /Catalog /Pages 2 0 R /OCProperties 7 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] " &
      "/Resources << /Properties << /mc0 8 0 R /mc1 9 0 R >> " &
      "/XObject << /Fm1 10 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] " &
      "/Resources << /Properties << /mc0 8 0 R /ocmd 11 0 R >> >> " &
      "/Contents 6 0 R >>",
    streamObj(Content1),
    streamObj(Content2),
    "<< /OCGs [8 0 R 9 0 R] /D << /ON [8 0 R] /OFF [9 0 R] " &
      "/Locked [9 0 R] /Order [8 0 R 9 0 R] >> >>",
    "<< /Type /OCG /Name (Top) >>",
    "<< /Type /OCG /Name (Hidden) " &
      "/Usage << /Print << /PrintState /OFF >> >> >>",
    "<< /Type /XObject /Subtype /Form /BBox [0 0 200 100] " &
      "/OC 8 0 R /Resources << >> /Length " & $FormContent.len &
      " >>\nstream\n" & FormContent & "\nendstream",
    "<< /Type /OCMD /OCGs [8 0 R 9 0 R] /P /AllOn >>",
  ]

proc ocgDoc(): VecDocument = readAiVectors(assemblePdf(ocgObjects()))

proc fills(layer: VecLayer): seq[string] =
  ## Fill colors of a layer's paths as r/g/b triplets.
  for n in layer.children:
    if n.kind == vnkPath and n.fill.kind == vpkSolid:
      let c = n.fill.solid
      case c.space
      of vcsGray:
        result.add($c.gray & "/" & $c.gray & "/" & $c.gray)
      of vcsRGB:
        result.add($c.r & "/" & $c.g & "/" & $c.b)
      of vcsCMYK:
        result.add("cmyk")

test "groups become layers in encounter order, shared across pages":
  let doc = ocgDoc()
  check doc.artboards.len == 2
  var names: seq[string] = @[]
  for l in doc.layers:
    names.add(l.name)
  check names == @["Page 1", "Top", "Hidden", "Page 2"]

test "unmarked art stays on the page layer":
  let doc = ocgDoc()
  check fills(doc.layers[0]) == @["1.0/0.0/0.0", "1.0/1.0/0.0"]
  check fills(doc.layers[3]) == @["0.0/0.0/0.0", "0.0/1.0/1.0"]

test "marked art collects on the group layer across pages":
  let doc = ocgDoc()
  let top = doc.layers[1]
  check top.visible and not top.locked and top.printable
  check fills(top) == @["0.0/0.0/1.0", "0.5/0.5/0.5", "0.0/1.0/1.0",
    "1.0/0.0/1.0", "0.5/0.0/0.5"]

test "off, locked, unprintable state imports, art included":
  let doc = ocgDoc()
  let hidden = doc.layers[2]
  check hidden.name == "Hidden"
  check not hidden.visible
  check hidden.locked
  check not hidden.printable
  check fills(hidden) == @["0.0/1.0/0.0"]

test "a form's own /OC scopes its whole expansion":
  let doc = ocgDoc()
  # the cyan rect at x=130 comes from the form stream, yet the Top
  # layer holds it: the form-level group outranks the page layer
  let top = doc.layers[1]
  var found = false
  for n in top.children:
    if n.kind == vnkPath:
      let b = pathBounds(n.path)
      if b.x0 > 129.0 and b.x0 < 131.0:
        found = true
  check found

test "broken references and policies warn once and stay grouped":
  let doc = ocgDoc()
  let w = doc.warnings.join(" ")
  check "failed to resolve" in w # /nope names no /Properties entry
  check "first group" in w # the AllOn membership routes to Top

test "text strings decode across encodings":
  check decodeTextString("Top") == "Top"
  check decodeTextString("\xFE\xFF\x00H\x00i") == "Hi"
  check decodeTextString("\xEF\xBB\xBFHi") == "Hi"
  check decodeTextString("\xE9") == "\xC3\xA9" # Latin-1 e-acute
