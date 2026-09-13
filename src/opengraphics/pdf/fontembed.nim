## PDF font embedding for the writer, backed by HarfBuzz.
##
## The M6 builder assembles pages from caller-supplied dictionaries,
## which left every caller hand-rolling font objects. This module
## closes the loop: measure text with shaped advances, draw text
## lines, wrap paragraphs, and embed (optionally subset) TrueType
## programs with matching /Widths and /ToUnicode, so our own reader
## round-trips the text.
##
## HarfBuzz supplies the font intelligence (shaping for measurement,
## subsetting for size); every COS object is ours. Typical flow:
##
##   var use = FontUse(fontBytes: dejavu, baseName: "DejaVuSans")
##   let words = wrapText(sf, "Hello writer", 24.0, 468.0)
##   var content: string
##   for i, line in words:
##     use.noteUse(line)
##     content.add(drawTextLine(72.0, 720.0 - float64(i) * 28.0,
##       "F2", 24.0, line))
##   var b = newPdfBuilder()
##   let fonts = b.finalizeFonts({"F2": use}.toTable)
##   let cnum = b.addContentStream(content)
##   discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
##
## Encoding boundary: WinAnsi only. `noteUse` fails loudly on anything
## outside it; CID-keyed Type0 fonts for full Unicode and emoji are
## future work. System fonts are out of scope: the caller supplies the
## program bytes (for example from the harfbuzz checkout's test data).

import std/algorithm
import std/strutils
import std/tables
import std/unicode
import harfbuzz
import ./cos
import ./write
import ./shape
import ./cmap

type
  FontUse* = object
    ## One font program plus the byte codes used with it. Collect
    ## while drawing, then hand to `finalizeFonts` once, just before
    ## `buildPdf`: the subset is only known after all text is drawn,
    ## but the builder assigns object numbers eagerly.
    fontBytes*: string ## full program; the table keeps it alive
    baseName*: string  ## PostScript name, e.g. "DejaVuSans"
    codes*: Table[int, uint32] ## WinAnsi byte code to Unicode scalar

proc winAnsiByte*(r: Rune): int =
  ## WinAnsi byte for a rune, or -1 when not encodable.
  let u = int(r)
  if u < 0 or u > 0xFFFF:
    return -1
  for b in 0 .. 255:
    if winAnsiTable[b] == u:
      return b
  -1

proc noteUse*(u: var FontUse, text: string) =
  ## Record every rune of `text` in the used-code table. Fails loudly
  ## on runes outside WinAnsi.
  for r in text.runes:
    let b = winAnsiByte(r)
    if b < 0:
      pdfFail("text U+" & toHex(int(r), 4) &
        " is outside WinAnsi; CID-keyed fonts are future work")
    u.codes[b] = uint32(r)

proc subsetFont*(fontBytes: string,
    unicodes: openArray[uint32]): string =
  ## Subset a TrueType/OpenType program to `unicodes` via HarfBuzz,
  ## keeping hinting and `.notdef`. Fails loudly on empty input or a
  ## failed subset operation.
  if fontBytes.len == 0:
    pdfFail("cannot subset an empty font program")
  var sf = openShapedFont(fontBytes)
  defer: close(sf)
  let input = hb_subset_input_create_or_fail()
  if input == nil:
    pdfFail("HarfBuzz refused the subset input")
  defer: hb_subset_input_destroy(input)
  let uset = hb_subset_input_unicode_set(input)
  for u in unicodes:
    hb_set_add(uset, hb_codepoint_t(u))
  let sub = hb_subset_or_fail(sf.face, input)
  if sub == nil:
    pdfFail("HarfBuzz failed to subset the font program")
  defer: hb_face_destroy(sub)
  let bb = hb_face_reference_blob(sub)
  if bb == nil:
    pdfFail("subset produced no font blob")
  defer: hb_blob_destroy(bb)
  var n: cuint = 0
  let p = hb_blob_get_data(bb, addr n)
  if p == nil or n == 0:
    pdfFail("subset produced no font bytes")
  result = newString(int(n))
  copyMem(addr result[0], p, int(n))

proc measureText*(sf: ShapedFont, text: string,
    size: float64): float64 =
  ## Text-space width of `text` at `size`: total shaped advance over
  ## 1000 upm times the size. Includes kerning, ligatures and GPOS.
  sf.shapedWidth(text) / 1000.0 * size

proc drawTextLine*(x, y: float64, resName: string, size: float64,
    text: string): string =
  ## One `BT...ET` content line drawing `text` (WinAnsi, already
  ## recorded via `noteUse`) with font resource `resName`.
  "BT /" & resName & " " & $size & " Tf " & $x & " " & $y & " Td " &
    writeStr(text) & " Tj ET"

proc wrapText*(sf: ShapedFont, text: string, size,
    maxWidth: float64): seq[string] =
  ## Greedy word wrap on shaped widths. `\n` forces a break, runs of
  ## spaces collapse, and a word wider than `maxWidth` takes its own
  ## line (overflowing, never hyphenated). A 1e-6 epsilon keeps float
  ## dust from breaking lines that measure exactly at the width.
  result = @[]
  for para in text.split('\n'):
    var line = ""
    var lineW = 0.0
    let spW = measureText(sf, " ", size)
    for word in para.split(' '):
      if word.len == 0:
        continue
      let w = measureText(sf, word, size)
      if line.len == 0:
        line = word
        lineW = w
      elif lineW + spW + w <= maxWidth + 1e-6:
        line.add(' ')
        line.add(word)
        lineW += spW + w
      else:
        result.add(line)
        line = word
        lineW = w
    result.add(line)

proc uniHex(u: uint32): string =
  if u <= 0xFFFF:
    toHex(int(u), 4).toUpperAscii()
  else:
    let v = u - 0x10000
    toHex(int(0xD800 + (v shr 10)), 4).toUpperAscii() &
      toHex(int(0xDC00 + (v and 0x3FF)), 4).toUpperAscii()

proc toUnicodeCMap(codes: Table[int, uint32]): string =
  var keys: seq[int] = @[]
  for c in codes.keys:
    keys.add(c)
  keys.sort()
  result = "/CIDInit /ProcSet findresource begin\n" &
    "12 dict begin\nbegincmap\n" &
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) " &
    "/Supplement 0 >> def\n" &
    "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" &
    "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" &
    $keys.len & " beginbfchar\n"
  for c in keys:
    result.add("<" & toHex(c, 2).toUpperAscii() & "> <" &
      uniHex(codes[c]) & ">\n")
  result.add("endbfchar\nendcmap\nCMapName currentdict /CMap " &
    "defineresource pop\nend\nend\n")

proc fontResources*(fonts: Table[string, int]): CosObj =
  ## A /Resources dict with a /Font subdict from resource name to
  ## font-dict object number (as built by `finalizeFonts`).
  var names: seq[string] = @[]
  for k in fonts.keys:
    names.add(k)
  names.sort()
  var items: seq[CosObj] = @[]
  for n in names:
    items.add(CosObj(kind: coRef, refNum: fonts[n], refGen: 0))
  CosObj(kind: coDict, keys: @["Font"],
    vals: @[CosObj(kind: coDict, keys: names, vals: items)])

proc embedFont*(b: var PdfBuilder, baseName: string, fontBytes: string,
    codes: Table[int, uint32], subset = true): int =
  ## Embed a TrueType program with matching /Widths and /ToUnicode.
  ## Returns the font-dict object number. With `subset` (default) only
  ## the used unicodes are embedded; otherwise the full program ships.
  ## Widths and descriptor metrics come from the embedded bytes, so
  ## laid-out breaks match the real font.
  if codes.len == 0:
    pdfFail("embedFont needs at least one used code")
  var prog = fontBytes
  if subset:
    var uni: seq[uint32] = @[]
    for u in codes.values:
      uni.add(u)
    prog = subsetFont(fontBytes, uni)
  var sf = openShapedFont(prog)
  defer: close(sf)
  var first = 256
  var last = -1
  for c in codes.keys:
    first = min(first, c)
    last = max(last, c)
  var widths: seq[CosObj] = @[]
  for c in first .. last:
    if codes.hasKey(c):
      let g = sf.nominalGlyph(codes[c])
      widths.add(CosObj(kind: coInt,
        ival: int(sf.glyphAdvance1000(g) + 0.5)))
    else:
      widths.add(CosObj(kind: coInt, ival: 0))
  let bbox = sf.headBBox()
  let ext = sf.hExtents1000()
  var capH = ext.ascender
  let hGlyph = sf.nominalGlyph(0x48)
  if hGlyph != 0:
    var e: hb_glyph_extents_t
    if hb_font_get_glyph_extents(sf.font, hb_codepoint_t(hGlyph),
        addr e) != 0:
      capH = int(e.height)
  let fileNum = b.addStream(CosObj(kind: coDict,
    keys: @["Length1"],
    vals: @[CosObj(kind: coInt, ival: prog.len)]), prog)
  let descNum = b.addValue(CosObj(kind: coDict,
    keys: @["Type", "FontName", "Flags", "FontBBox", "ItalicAngle",
      "Ascent", "Descent", "CapHeight", "StemV", "FontFile2"],
    vals: @[CosObj(kind: coName, name: "FontDescriptor"),
      CosObj(kind: coName, name: baseName),
      CosObj(kind: coInt, ival: 32),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coInt, ival: bbox.xMin),
        CosObj(kind: coInt, ival: bbox.yMin),
        CosObj(kind: coInt, ival: bbox.xMax),
        CosObj(kind: coInt, ival: bbox.yMax)]),
      CosObj(kind: coInt, ival: 0),
      CosObj(kind: coInt, ival: ext.ascender),
      CosObj(kind: coInt, ival: ext.descender),
      CosObj(kind: coInt, ival: capH),
      CosObj(kind: coInt, ival: 80),
      CosObj(kind: coRef, refNum: fileNum, refGen: 0)]))
  let tuNum = b.addStream(CosObj(kind: coDict, keys: @[], vals: @[]),
    toUnicodeCMap(codes))
  result = b.addValue(CosObj(kind: coDict,
    keys: @["Type", "Subtype", "BaseFont", "FirstChar", "LastChar",
      "Widths", "Encoding", "FontDescriptor", "ToUnicode"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "TrueType"),
      CosObj(kind: coName, name: baseName),
      CosObj(kind: coInt, ival: first),
      CosObj(kind: coInt, ival: last),
      CosObj(kind: coArray, items: widths),
      CosObj(kind: coName, name: "WinAnsiEncoding"),
      CosObj(kind: coRef, refNum: descNum, refGen: 0),
      CosObj(kind: coRef, refNum: tuNum, refGen: 0)]))

proc finalizeFonts*(b: var PdfBuilder,
    uses: Table[string, FontUse], subset = true): Table[string, int] =
  ## Embed every collected `FontUse` (resource name to use) and return
  ## resource name to font-dict object number, for `fontResources`.
  ## Names embed in sorted order for deterministic output.
  result = initTable[string, int]()
  var names: seq[string] = @[]
  for k in uses.keys:
    names.add(k)
  names.sort()
  for n in names:
    let u = uses[n]
    result[n] = b.embedFont(u.baseName, u.fontBytes, u.codes, subset)
