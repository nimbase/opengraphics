## Text extraction (ISO 32000 §9.4): positioned runs.
##
## extractText walks a page's content operators with the M3a graphics
## state, decoding each shown string through the font's ToUnicode CMap
## first, then Differences plus the base encoding. Positions come from
## the text rendering matrix (font size, scale, rise, Tm, CTM); only
## horizontal writing is supported, vertical CMaps raise a clear error.
## Widths come from the font dictionary (/Widths, /DW plus /W); fonts
## without any widths fall back to 500 units with positions best-effort.

import std/tables
import std/unicode
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters
import ./cmap
import ./gstate

export gstate

type
  FontDecoder* = object
    fontName*: string
    codeLen*: int ## bytes per code (1 simple, 2 composite default)
    cmap*: CMap
    hasCMap*: bool
    diff*: Table[int, int] ## Differences code -> scalar (-1 unknown)
    hasDiff*: bool
    baseWinAnsi*: bool ## false selects MacRoman
    hasBase*: bool
    widths*: Table[int, float64]
    missingWidth*: float64

  TextRun* = object
    text*: string
    x*: float64 ## device-space origin via the rendering matrix
    y*: float64
    size*: float64
    fontName*: string

proc decodeCode(fd: FontDecoder, code: int): string =
  if fd.hasCMap and fd.cmap.entries.hasKey(code):
    return fd.cmap.entries[code]
  if fd.hasDiff and fd.diff.hasKey(code):
    let u = fd.diff[code]
    if u >= 0:
      return $Rune(u)
    return "\xEF\xBF\xBD"
  if fd.hasBase:
    let t = if fd.baseWinAnsi: winAnsiTable else: macRomanTable
    if code >= 0 and code < 256 and t[code] >= 0:
      return $Rune(t[code])
    if code >= 32 and code < 127:
      return $chr(code)
    return "\xEF\xBF\xBD"
  # No Encoding and no ToUnicode: the built-in encoding is unknown, so
  # only the ASCII range decodes (shared by all Latin encodings).
  if code >= 32 and code < 127:
    return $chr(code)
  "\xEF\xBF\xBD"

proc codeWidth(fd: FontDecoder, code: int): float64 =
  if fd.widths.hasKey(code):
    return fd.widths[code]
  fd.missingWidth

proc parseW(arr: CosObj, widths: var Table[int, float64]) =
  ## CID /W array in both range forms.
  var i = 0
  while i < arr.items.len:
    let first = arr.items[i].asInt()
    inc i
    if i < arr.items.len and arr.items[i].kind == coArray:
      var code = first
      for w in arr.items[i].items:
        widths[code] = w.asFloat()
        inc code
      inc i
    elif i < arr.items.len:
      let last = arr.items[i].asInt()
      inc i
      if i < arr.items.len:
        let w = arr.items[i].asFloat()
        inc i
        for code in first .. last:
          widths[code] = w

proc loadDecoder*(d: var PdfDoc, fontRef: CosObj,
    name: string): FontDecoder =
  ## Build the decoder for one font resource (resolved reference).
  var font = fontRef
  if font.kind == coRef:
    font = d.resolve(font)
  if font.kind != coDict:
    pdfFail("font /" & name & " is not a dictionary")
  let subtype = font.dictGet("Subtype")
  let composite = subtype.kind == coName and subtype.name == "Type0"
  result = FontDecoder(fontName: name,
    codeLen: if composite: 2 else: 1,
    diff: initTable[int, int](), widths: initTable[int, float64](),
    missingWidth: 500.0)
  var uni = font.dictGet("ToUnicode")
  if uni.kind == coRef:
    uni = d.resolve(uni)
  if uni.kind == coStream:
    result.cmap = parseToUnicode(decodeCosStream(uni), d.limits)
    result.hasCMap = true
    if composite:
      result.codeLen = clamp(result.cmap.maxKeyLen, 1, 4)
  var enc = font.dictGet("Encoding")
  if enc.kind == coRef:
    enc = d.resolve(enc)
  if enc.kind == coName:
    if enc.name == "WinAnsiEncoding":
      result.hasBase = true
      result.baseWinAnsi = true
    elif enc.name == "MacRomanEncoding":
      result.hasBase = true
      result.baseWinAnsi = false
  elif enc.kind == coDict:
    let base = enc.dictGet("BaseEncoding")
    if base.kind == coName:
      result.hasBase = true
      result.baseWinAnsi = base.name != "MacRomanEncoding"
    else:
      result.hasBase = true
      result.baseWinAnsi = true
    let diffs = enc.dictGet("Differences")
    if diffs.kind == coArray and diffs.items.len > 0:
      result.hasDiff = true
      var code = 0
      var started = false
      for item in diffs.items:
        if item.kind == coInt:
          code = item.ival
          started = true
        elif started and item.kind == coName:
          result.diff[code] = glyphNameToUnicode(item.name)
          inc code
  if composite:
    if font.dictGet("DescendantFonts").kind == coArray and
        font.dictGet("DescendantFonts").items.len > 0:
      var cid = font.dictGet("DescendantFonts").items[0]
      if cid.kind == coRef:
        cid = d.resolve(cid)
      let dw = cid.dictGet("DW")
      if dw.kind == coInt:
        result.missingWidth = dw.asFloat()
      let w = cid.dictGet("W")
      if w.kind == coArray:
        parseW(w, result.widths)
  else:
    let mw = font.dictGet("MissingWidth")
    if mw.kind == coInt:
      result.missingWidth = mw.asFloat()
    let first = font.dictGet("FirstChar")
    let last = font.dictGet("LastChar")
    let arr = font.dictGet("Widths")
    if first.kind == coInt and arr.kind == coArray:
      let n = if last.kind == coInt: last.ival - first.ival + 1
        else: arr.items.len
      for i in 0 ..< min(n, arr.items.len):
        result.widths[first.ival + i] = arr.items[i].asFloat()

proc splitCodes(s: string, codeLen: int): seq[int] =
  var i = 0
  while i < s.len:
    if i + codeLen > s.len:
      pdfFail("truncated multi-byte code in text string")
    var code = 0
    for j in 0 ..< codeLen:
      code = code * 256 + int(byte(s[i + j]))
    result.add(code)
    i += codeLen

proc showText(d: var PdfDoc, gs: var GState, fd: FontDecoder,
    s: string, runs: var seq[TextRun]) =
  if s.len == 0:
    return
  let th = gs.text.scale / 100.0
  let fs = gs.text.fontSize
  let trm = concatMatrix([fs * th, 0.0, 0.0, fs, 0.0, gs.text.rise],
    concatMatrix(gs.textMatrix, gs.ctm))
  var text = ""
  for code in splitCodes(s, fd.codeLen):
    text.add(fd.decodeCode(code))
  runs.add(TextRun(text: text, x: trm[4], y: trm[5], size: fs,
    fontName: fd.fontName))
  for code in splitCodes(s, fd.codeLen):
    let decoded = fd.decodeCode(code)
    var tx = (fd.codeWidth(code) * fs / 1000.0 + gs.text.charSpace) * th
    if decoded == " ":
      tx += gs.text.wordSpace * th
    let t: Matrix = [1.0, 0.0, 0.0, 1.0, tx, 0.0]
    # Showing text advances Tm only; Tlm keeps the line start for
    # Td, TD and T*.
    gs.textMatrix = concatMatrix(t, gs.textMatrix)

proc decoderFor(d: var PdfDoc, res: CosObj,
    cache: var Table[string, FontDecoder], gs: GState): FontDecoder =
  if gs.text.fontName.len == 0:
    pdfFail("text showing operator without a selected font (Tf)")
  if cache.hasKey(gs.text.fontName):
    return cache[gs.text.fontName]
  var fonts = res.dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  if fonts.kind != coDict:
    pdfFail("page /Resources has no /Font dictionary")
  let r = fonts.dictGet(gs.text.fontName)
  if r.kind != coRef and r.kind != coDict:
    pdfFail("font /" & gs.text.fontName & " missing from /Resources")
  result = d.loadDecoder(r, gs.text.fontName)
  cache[gs.text.fontName] = result

proc extractText*(d: var PdfDoc, index: int): seq[TextRun] =
  ## One run per shown string with its device-space origin. Tj
  ## numbers shift Tm only (Td restarts from Tlm); quote operators
  ## expand to their T* plus spacing equivalents.
  let ops = d.walkPageOps(index)
  let res = d.pageResources(index)
  var cache = initTable[string, FontDecoder]()
  var gs = initGState()
  result = @[]
  for op in ops:
    case op.name
    of "Tj":
      if op.operands.len != 1 or op.operands[0].kind != coStr:
        pdfFail("Tj needs one string operand")
      d.showText(gs, d.decoderFor(res, cache, gs),
        op.operands[0].sval, result)
    of "TJ":
      if op.operands.len != 1 or op.operands[0].kind != coArray:
        pdfFail("TJ needs one array operand")
      for item in op.operands[0].items:
        if item.kind == coStr:
          d.showText(gs, d.decoderFor(res, cache, gs), item.sval,
            result)
        else:
          let th = gs.text.scale / 100.0
          let t: Matrix = [1.0, 0.0, 0.0, 1.0,
            -item.asFloat() * gs.text.fontSize * th / 1000.0, 0.0]
          gs.textMatrix = concatMatrix(t, gs.textMatrix)
    of "'":
      if op.operands.len != 1 or op.operands[0].kind != coStr:
        pdfFail("' needs one string operand")
      gs.applyOp(ContentOp(name: "T*"))
      d.showText(gs, d.decoderFor(res, cache, gs),
        op.operands[0].sval, result)
    of "\"":
      if op.operands.len != 3 or op.operands[2].kind != coStr:
        pdfFail("\" needs word/char spacing plus a string")
      gs.text.wordSpace = op.operands[0].asFloat()
      gs.text.charSpace = op.operands[1].asFloat()
      gs.applyOp(ContentOp(name: "T*"))
      d.showText(gs, d.decoderFor(res, cache, gs),
        op.operands[2].sval, result)
    else:
      gs.applyOp(op)
