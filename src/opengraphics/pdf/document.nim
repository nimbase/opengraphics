## High-level PDF document API (M1: read unencrypted files).

import std/strutils
import ./types
import ./lexer
import ./cos
import ./docmodel

export types
export cos

type
  PdfDocument* = object
    version*: string
    pages*: seq[PageBox]
    hasEncrypt*: bool

proc pageCount*(d: PdfDocument): int {.inline.} = d.pages.len

proc readPdfBytes*(data: string, limits = defaultPdfLimits()): PdfDocument =
  let head = data[0 ..< min(data.len, limits.maxScanBytes)]
  if find(head, "%PDF-") < 0:
    raise newException(PdfError,
      "not a PDF file (no %PDF- header in first " & $limits.maxScanBytes &
      " bytes)")
  var doc = openDoc(data, limits)
  if doc.xref.encrypt.kind != coNull:
    raise newException(PdfError,
      "encrypted PDF: /Encrypt present, needs M4 crypt support")
  let boxes = doc.pageBoxes()
  PdfDocument(version: parsePdfVersion(head), pages: boxes,
    hasEncrypt: false)

proc readPdfBytes*(data: seq[byte],
    limits = defaultPdfLimits()): PdfDocument =
  var s = newString(data.len)
  if data.len > 0:
    copyMem(addr s[0], unsafeAddr data[0], data.len)
  readPdfBytes(s, limits)

proc openPdf*(path: string, limits = defaultPdfLimits()): PdfDocument =
  readPdfBytes(readFile(path), limits)
