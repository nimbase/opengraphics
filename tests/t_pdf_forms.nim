## M11 forms: extraction, fill, flatten.
import std/strutils
import std/unicode
import unittest
import ../src/opengraphics/pdf
import ../src/opengraphics/pdf/cos
import ../src/opengraphics/pdf/docmodel
import ../src/opengraphics/pdf/forms
import pdf_support

proc formPdf(): string =
  let annots = "[5 0 R 7 0 R 8 0 R 10 0 R 11 0 R 12 0 R 13 0 R 16 0 R 19 0 R]"
  assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] " &
      "/Resources << /Font << /Helv 6 0 R >> >> /Annots " & annots &
      " /Contents 14 0 R >>",
    "<< /Fields [5 0 R 7 0 R 8 0 R 9 0 R 12 0 R 13 0 R 15 0 R 19 0 R] >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 300 200 320] " &
      "/FT /Tx /T (Name) /TU (Your full name) /V (Ann) /DV (Anon) " &
      "/DA (/Helv 12 Tf 0 g) /MaxLen 20 /P 3 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 270 62 282] " &
      "/FT /Btn /T (Agree) /TU (Accept terms) /V /Yes /AS /Yes " &
      "/AP << /N << /Yes 17 0 R /Off 18 0 R >> >> /P 3 0 R >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 250 62 262] " &
      "/FT /Btn /T (Spam) /V /Off /AS /Off " &
      "/AP << /N << /Yes 17 0 R /Off 18 0 R >> >> /P 3 0 R >>",
    "<< /FT /Btn /Ff 32768 /T (Pick) /V /A /Kids [10 0 R 11 0 R] >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 220 62 232] " &
      "/Parent 9 0 R /AS /A " &
      "/AP << /N << /A 17 0 R /Off 18 0 R >> >> /P 3 0 R >>",
    "<< /Type /Annot /Subtype /Widget /Rect [70 220 82 232] " &
      "/Parent 9 0 R /AS /Off " &
      "/AP << /N << /B 17 0 R /Off 18 0 R >> >> /P 3 0 R >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 180 150 200] " &
      "/FT /Ch /Ff 131072 /T (City) /TU (Pick a city) /V (Oslo) " &
      "/Opt [(Oslo) (Bergen)] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 100 150 130] " &
      "/FT /Sig /T (Seal) /P 3 0 R >>",
    streamObj("", "BT /Helv 12 Tf 50 350 Td (static) Tj ET"),
    "<< /T (Addr) /Kids [16 0 R] >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 140 200 160] " &
      "/FT /Tx /Parent 15 0 R /T (Street) /TU (Street hint) " &
      "/V (Main) /DA (/Helv 10 Tf 0 g) /P 3 0 R >>",
    streamObj("", ""),
    streamObj("", ""),
    "<< /Type /Annot /Subtype /Widget /Rect [50 60 150 90] " &
      "/FT /Ch /Ff 2097152 /T (Langs) /V [(en)] /I [0] " &
      "/Opt [[(en) (English)] [(no) (Norwegian)]] " &
      "/DA (/Helv 12 Tf 0 g) /P 3 0 R >>",
  ])

proc namesOf(d: var PdfDoc): seq[string] =
  for f in formFields(d):
    result.add(f.name)

test "extraction lists fields with rich attributes":
  var d = openDoc(formPdf())
  check namesOf(d) == @["Name", "Agree", "Spam", "Pick", "City",
    "Seal", "Addr.Street", "Langs"]
  let n = getField(d, "Name")
  check n.kind == fkText
  check n.value == "Ann"
  check n.defaultValue == "Anon"
  check n.label == "Your full name"
  check n.maxLen == 20
  check n.fontName == "Helv"
  check n.fontSize == 12.0
  check n.widgets.len == 1
  check n.widgets[0].page == 0
  check n.widgets[0].rect.x1 == 50.0
  let s = getField(d, "Spam")
  check s.kind == fkCheckbox
  check s.label == ""
  check not isChecked(s)
  check isChecked(getField(d, "Agree"))
  let p = getField(d, "Pick")
  check p.kind == fkRadio
  check p.value == "A"
  check p.options == @[(value: "A", display: "A"),
    (value: "B", display: "B")]
  let c = getField(d, "City")
  check c.kind == fkDropdown
  check c.combo
  check c.options == @[(value: "Oslo", display: "Oslo"),
    (value: "Bergen", display: "Bergen")]
  check getField(d, "Seal").kind == fkSignature
  check getField(d, "Addr.Street").value == "Main"
  let l = getField(d, "Langs")
  check l.kind == fkListBox
  check l.options == @[(value: "en", display: "English"),
    (value: "no", display: "Norwegian")]
  check l.value == "en"

test "unknown field fails loudly":
  var d = openDoc(formPdf())
  expect PdfError:
    discard getField(d, "Missing")

test "fillText round-trips and truncates to MaxLen":
  var d = openDoc(fillText(formPdf(), "Name", "Bob"))
  check getField(d, "Name").value == "Bob"
  var t = openDoc(fillText(formPdf(), "Name",
    "12345678901234567890123"))
  check getField(t, "Name").value.len == 20

test "fillText truncates on character boundaries":
  # 19 ASCII runes plus three 2-byte runes: a byte cut at MaxLen 20
  # would split the first é, a rune cut keeps it whole.
  let s = "1234567890123456789" & "ééé"
  var d = openDoc(fillText(formPdf(), "Name", s))
  let v = getField(d, "Name").value
  check v.runeLen == 20
  check v == "1234567890123456789" & "é"

test "fillText rejects wrong kinds and names":
  expect PdfError:
    discard fillText(formPdf(), "Agree", "x")
  expect PdfError:
    discard fillText(formPdf(), "Missing", "x")
  expect PdfError:
    discard fillText(formPdf(), "Seal", "x")

test "setCheck flips value":
  var on = openDoc(setCheck(formPdf(), "Spam", true))
  let s = getField(on, "Spam")
  check s.value == "Yes"
  check isChecked(s)
  var off = openDoc(setCheck(formPdf(), "Agree", false))
  check getField(off, "Agree").value == ""
  expect PdfError:
    discard setCheck(formPdf(), "Name", true)

test "selectRadio switches with exclusivity":
  var d = openDoc(selectRadio(formPdf(), "Pick", "B"))
  let p = getField(d, "Pick")
  check p.value == "B"
  check p.widgets[0].appearance == "Off"
  check p.widgets[1].appearance == "B"
  expect PdfError:
    discard selectRadio(formPdf(), "Pick", "Z")
  expect PdfError:
    discard selectRadio(formPdf(), "City", "Oslo")

test "selectChoice by display with rejection":
  var d = openDoc(selectChoice(formPdf(), "City", "Bergen"))
  check getField(d, "City").value == "Bergen"
  expect PdfError:
    discard selectChoice(formPdf(), "City", "Paris")

test "selectChoice stores the export value":
  var d = openDoc(selectChoice(formPdf(), "Langs", "Norwegian"))
  check getField(d, "Langs").value == "no"
  var e = openDoc(selectChoice(formPdf(), "Langs", "en"))
  check getField(e, "Langs").value == "en"

test "selectChoices syncs /V with sorted /I":
  # Reversed input still lands sorted by /Opt index.
  var d = openDoc(selectChoices(formPdf(), "Langs",
    @["Norwegian", "English"]))
  check getField(d, "Langs").value == "en\nno"
  for rf in d.rawFields():
    if rf.fullName == "Langs":
      let v = rf.node.dictGet("V")
      check v.kind == coArray
      check v.items[0].sval == "en"
      check v.items[1].sval == "no"
      let ii = rf.node.dictGet("I")
      check ii.kind == coArray
      check ii.items[0].ival == 0
      check ii.items[1].ival == 1
  # One option degrades to a plain string and drops stale /I.
  var s = openDoc(selectChoices(formPdf(), "Langs", @["Norwegian"]))
  check getField(s, "Langs").value == "no"
  for rf in s.rawFields():
    if rf.fullName == "Langs":
      check rf.node.dictGet("V").sval == "no"
      check rf.node.dictGet("I").kind == coNull
  # Empty clears the selection.
  var c = openDoc(selectChoices(formPdf(), "Langs", @[]))
  check getField(c, "Langs").value == ""
  expect PdfError:
    discard selectChoices(formPdf(), "City", @["Oslo", "Bergen"])
  expect PdfError:
    discard selectChoices(formPdf(), "Langs", @["Klingon"])
  expect PdfError:
    discard selectChoices(formPdf(), "Name", @["Bob"])

test "fill sets NeedAppearances":
  var d = openDoc(fillText(formPdf(), "Name", "Bob"))
  let acro = d.resolve(d.catalog().dictGet("AcroForm"))
  check acro.dictGet("NeedAppearances").kind == coBool
  check acro.dictGet("NeedAppearances").bval

test "flatten bakes values and drops the form":
  var d = openDoc(flattenFields(formPdf()))
  var texts: seq[string] = @[]
  for r in d.extractText(0):
    texts.add(r.text)
  let all = texts.join(" ")
  check "static" in all
  check "Ann" in all
  check "Main" in all
  check "Oslo" in all
  check "English" in all
  # Signature fields never flatten: Seal stays with its AcroForm.
  check namesOf(d) == @["Seal"]
  let cat = d.catalog()
  check d.resolve(cat.dictGet("AcroForm")).kind == coDict

test "flatten draws checks and radio dots":
  var d = openDoc(flattenFields(formPdf()))
  # flattened page content holds stroked ticks and filled dots
  let cat = d.catalog()
  let pages = d.resolve(cat.dictGet("Pages"))
  let kid = d.resolve(pages.dictGet("Kids").items[0])
  let contents = d.resolve(kid.dictGet("Contents"))
  check contents.kind == coArray
  var streams: seq[string] = @[]
  for c in contents.items:
    let s = d.resolve(c)
    check s.kind == coStream
    streams.add(s.raw)
  check streams.join(" ").contains(" S ")
  check streams.join(" ").contains(" f ")

test "flatten only keeps the rest":
  var d = openDoc(flattenFields(formPdf(), @["Name"]))
  check namesOf(d) == @["Agree", "Spam", "Pick", "City", "Seal",
    "Addr.Street", "Langs"]
  var texts: seq[string] = @[]
  for r in d.extractText(0):
    texts.add(r.text)
  check "Ann" in texts.join(" ")

test "flatten rejects signatures and unknown names":
  expect PdfError:
    discard flattenFields(formPdf(), @["Seal"])
  expect PdfError:
    discard flattenFields(formPdf(), @["Missing"])

test "flatten falls back to builtin Helvetica":
  let pdf = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Annots [5 0 R] /Contents 6 0 R >>",
    "<< /Fields [5 0 R] >>",
    "<< /Type /Annot /Subtype /Widget /Rect [10 10 100 30] " &
      "/FT /Tx /T (F) /V (hi) /DA (/Gone 12 Tf 0 g) /P 3 0 R >>",
    streamObj("", ""),
  ])
  var d = openDoc(flattenFields(pdf))
  check namesOf(d).len == 0
  let cat = d.catalog()
  let pages = d.resolve(cat.dictGet("Pages"))
  let kid = d.resolve(pages.dictGet("Kids").items[0])
  let res = d.resolve(kid.dictGet("Resources"))
  check res.dictGet("Font").kind == coDict
