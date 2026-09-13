## Cross-reference tables with incremental-update (Prev) chains.
##
## M1: classic `xref` tables only. The newest section is the one named
## by the last `startxref`; each trailer may carry /Prev pointing at an
## older section, and entries from newer sections win. Compressed xref
## streams and object streams arrive with M2 Flate support and raise a
## PdfError that names the missing piece.

import std/strutils
import std/tables
import ./types
import ./lexer
import ./cos

type
  XRefEntry* = object
    offset*: int
    gen*: int
    live*: bool

  XRef* = object
    entries*: Table[int, XRefEntry]
    root*: CosObj ## /Root reference from the newest trailer
    encrypt*: CosObj ## /Encrypt (coNull when absent)
    size*: int ## /Size from the newest trailer

proc parseStartxref(data: string, limits: PdfLimits): int =
  let tail = data[max(0, data.len - limits.maxScanBytes) ..< data.len]
  let sx = rfind(tail, "startxref")
  if sx < 0:
    pdfFail("PDF trailer not found (no startxref near EOF)")
  var lx = initLexer(tail, sx + "startxref".len)
  let off = lx.readTableInt("startxref offset")
  if off < 0 or off > data.len:
    pdfFail("startxref offset out of range: " & $off)
  off

proc parseClassicSection(data: string, off: int, limits: PdfLimits,
    entries: var Table[int, XRefEntry]): CosObj =
  ## Parse one classic table at off; merge entries (caller decides
  ## precedence) and return the trailer dictionary.
  var lx = initLexer(data, off)
  lx.expectKeyword("xref", "cross-reference section")
  while true:
    lx.skipWsAndComments()
    if lx.continuesWith("trailer"):
      lx.pos += 7
      let t = lx.parseCosValue()
      if t.kind != coDict:
        pdfFail("bad PDF trailer dictionary at offset " & $lx.pos)
      return t
    if lx.atEnd:
      pdfFail("unterminated xref table at offset " & $off)
    let first = lx.readTableInt("xref subsection first")
    let count = lx.readTableInt("xref subsection count")
    if count < 0 or count > limits.maxObjects:
      pdfFail("implausible xref subsection size " & $count)
    limits.checkCount(first + count, "xref")
    for n in 0 ..< count:
      let eoff = lx.readTableInt("xref entry offset")
      let egen = lx.readTableInt("xref entry generation")
      lx.skipWsAndComments()
      if lx.atEnd:
        pdfFail("truncated xref entry at offset " & $lx.pos)
      let flag = lx.s[lx.pos]
      inc lx.pos
      if flag == 'n':
        if not entries.hasKey(first + n):
          entries[first + n] = XRefEntry(offset: eoff, gen: egen,
            live: true)
      elif flag == 'f':
        if not entries.hasKey(first + n):
          entries[first + n] = XRefEntry(offset: eoff, gen: egen,
            live: false)
      else:
        pdfFail("bad xref entry flag, expected n or f at offset " &
          $(lx.pos - 1))

proc parseXRef*(data: string, limits = defaultPdfLimits()): XRef =
  var off = parseStartxref(data, limits)
  var entries = initTable[int, XRefEntry]()
  var newestTrailer: CosObj = CosObj(kind: coNull)
  var first = true
  var sections = 0
  while true:
    if sections > limits.maxObjects:
      pdfFail("too many xref sections (possible /Prev cycle)")
    inc sections
    if off + 4 > data.len:
      pdfFail("xref section offset out of range: " & $off)
    if data.continuesWith("xref", off):
      let trailer = parseClassicSection(data, off, limits, entries)
      if first:
        newestTrailer = trailer
        first = false
      let prev = trailer.dictGet("Prev")
      if prev.kind == coNull:
        break
      if prev.kind != coInt:
        pdfFail("/Prev must be an integer offset")
      off = prev.ival
      if off < 0 or off >= data.len:
        pdfFail("/Prev offset out of range: " & $off)
    else:
      let probe = data[off ..< min(data.len, off + 300)]
      if find(probe, "XRef") >= 0 or find(probe, "obj") >= 0:
        pdfFail("PDF uses compressed xref streams, which need M2 " &
          "Flate support (zlib) to read")
      pdfFail("bad xref section at offset " & $off)
  if newestTrailer.kind != coDict:
    pdfFail("missing PDF trailer dictionary")
  let root = newestTrailer.dictGet("Root")
  if root.kind != coRef:
    pdfFail("PDF trailer missing /Root reference")
  let size = newestTrailer.dictGet("Size")
  result = XRef(entries: entries, root: root,
    encrypt: newestTrailer.dictGet("Encrypt"),
    size: if size.kind == coInt: size.ival else: entries.len)
