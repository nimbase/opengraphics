## Document model: object registry, catalog, page tree.
##
## PdfDoc owns the file bytes, the merged xref table and a bounded
## resolve cache. Streams with indirect /Length are resolved here:
## Length is dereferenced first, then cos.parseStreamBody slices bytes.

import std/tables
import ./types
import ./lexer
import ./cos
import ./xref

export xref

type
  PdfDoc* = object
    data*: string
    xref*: XRef
    limits*: PdfLimits
    cache*: Table[int, CosObj]

proc openDoc*(data: string, limits = defaultPdfLimits()): PdfDoc =
  let xr = parseXRef(data, limits)
  limits.checkCount(xr.entries.len, "xref")
  PdfDoc(data: data, xref: xr, limits: limits,
    cache: initTable[int, CosObj]())

proc cacheSize*(d: PdfDoc): int {.inline.} = d.cache.len

proc resolve*(d: var PdfDoc, r: CosObj, depth = 0): CosObj =
  ## Dereference indirect objects with caching and a cycle guard.
  ## Non-ref values pass through unchanged.
  if r.kind != coRef:
    return r
  if depth > d.limits.maxWalkDepth:
    pdfFail("indirect reference cycle near object " & $r.refNum)
  if d.cache.hasKey(r.refNum):
    return d.cache[r.refNum]
  if not d.xref.entries.hasKey(r.refNum):
    pdfFail("dangling reference to object " & $r.refNum)
  let e = d.xref.entries[r.refNum]
  if not e.live:
    pdfFail("reference to freed object " & $r.refNum)
  if d.cache.len >= d.limits.maxObjects:
    pdfFail("object cache exceeds limit " & $d.limits.maxObjects)
  # Parse the header and value inline (rather than via parseIndirect)
  # so streams with indirect /Length can be handled: Length is
  # dereferenced first, then the body is sliced.
  var lx = initLexer(d.data, e.offset)
  let num = lx.readTableInt("object number")
  discard lx.readTableInt("object generation")
  lx.expectKeyword("obj", "indirect object " & $r.refNum)
  if num != r.refNum:
    pdfFail("xref offset for object " & $r.refNum &
      " points at object " & $num)
  let val = lx.parseCosValue()
  if val.kind == coDict:
    let save = lx.pos
    lx.skipWsAndComments()
    if lx.continuesWith("stream"):
      let after = lx.pos + 6
      if after >= d.data.len or d.data[after] notin {'\x0A', '\x0D'}:
        pdfFail("expected EOL after 'stream' in object " & $r.refNum)
      var length = -1
      for i, k in val.keys:
        if k == "Length":
          let lv = val.vals[i]
          if lv.kind == coInt:
            length = lv.ival
          else:
            length = d.resolve(lv, depth + 1).asInt()
      if length < 0:
        pdfFail("stream object " & $r.refNum & " missing /Length")
      let raw = parseStreamBody(d.data, after, length)
      let so = CosObj(kind: coStream, streamDict: val.keys,
        streamVals: val.vals, raw: raw)
      d.cache[r.refNum] = so
      return so
    lx.pos = save
  # Non-stream value: re-parse through parseIndirect so endobj and
  # stray-endstream validation apply uniformly.
  let (_, _, obj) = parseIndirect(d.data, e.offset)
  d.cache[r.refNum] = obj
  obj

proc catalog*(d: var PdfDoc): CosObj =
  let c = d.resolve(d.xref.root)
  if c.kind != coDict:
    pdfFail("PDF catalog is not a dictionary")
  c

proc pageCount*(d: var PdfDoc): int =
  let cat = d.catalog()
  let pagesRef = cat.dictGet("Pages")
  if pagesRef.kind != coRef:
    pdfFail("PDF catalog missing /Pages reference")
  let node = d.resolve(pagesRef)
  let cnt = node.dictGet("Count")
  if cnt.kind != coInt:
    pdfFail("page tree /Count is not an integer")
  if cnt.ival < 0 or cnt.ival > d.limits.maxPages:
    pdfFail("page count " & $cnt.ival & " exceeds limit " &
      $d.limits.maxPages)
  cnt.ival

proc readBox(o: CosObj): tuple[w, h: float64] =
  if o.kind != coArray or o.items.len != 4:
    pdfFail("page /MediaBox must be an array of 4 numbers")
  let w = o.items[2].asFloat() - o.items[0].asFloat()
  let h = o.items[3].asFloat() - o.items[1].asFloat()
  if w != w or h != h or w <= 0.0 or h <= 0.0:
    pdfFail("page /MediaBox has non-positive size")
  (w, h)

proc walkPages(d: var PdfDoc, nodeRef: CosObj,
    inherited: tuple[has: bool, w, h: float64], depth: int,
    pages: var seq[PageBox]) =
  if depth > d.limits.maxWalkDepth:
    pdfFail("page tree exceeds nesting depth " & $d.limits.maxWalkDepth)
  if pages.len >= d.limits.maxPages:
    pdfFail("page count exceeds limit " & $d.limits.maxPages)
  let node = d.resolve(nodeRef)
  if node.kind != coDict:
    pdfFail("page tree node is not a dictionary")
  var box = inherited
  let mb = node.dictGet("MediaBox")
  if mb.kind == coArray:
    box = (true, readBox(mb).w, readBox(mb).h)
  let kids = node.dictGet("Kids")
  if kids.kind == coArray:
    for k in kids.items:
      if k.kind != coRef:
        pdfFail("page tree kid is not an indirect reference")
      d.walkPages(k, box, depth + 1, pages)
  else:
    let t = node.dictGet("Type")
    if t.kind == coName and t.name == "Pages":
      pdfFail("empty /Pages node in page tree")
    if not box.has:
      pdfFail("page missing /MediaBox and no inherited box")
    pages.add(PageBox(index: pages.len, width: box.w, height: box.h))

proc pageBoxes*(d: var PdfDoc): seq[PageBox] =
  ## One entry per page in page-tree order.
  let cat = d.catalog()
  let pagesRef = cat.dictGet("Pages")
  if pagesRef.kind != coRef:
    pdfFail("PDF catalog missing /Pages reference")
  result = @[]
  d.walkPages(pagesRef, (false, 0.0, 0.0), 0, result)
