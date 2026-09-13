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
import ./crypt

export xref
export crypt

type
  PdfDoc* = object
    data*: PdfSource
    xref*: XRef
    limits*: PdfLimits
    cache*: Table[int, CosObj]
    crypt*: PdfCrypt

proc resolve*(d: var PdfDoc, r: CosObj, depth = 0): CosObj
proc decryptObj(d: var PdfDoc, num, gen: int, val: CosObj): CosObj

proc openDoc*(src: PdfSource, limits = defaultPdfLimits(),
    password = ""): PdfDoc =
  let xr = parseXRef(src, limits)
  limits.checkCount(xr.entries.len, "xref")
  result = PdfDoc(data: src, xref: xr, limits: limits,
    cache: initTable[int, CosObj]())
  if xr.encrypt.kind == coNull:
    return
  var enc = xr.encrypt
  var encNum = -1
  if enc.kind == coRef:
    encNum = enc.refNum
    enc = result.resolve(enc) # crypt not armed yet: stays plaintext
  if enc.kind == coDict:
    let cf = enc.dictGet("CF")
    if cf.kind == coRef:
      for i, k in enc.keys:
        if k == "CF":
          enc.vals[i] = result.resolve(cf)
  result.crypt = openCrypt(enc, xr.idFirst, password, encNum)

proc openDoc*(data: string, limits = defaultPdfLimits(),
    password = ""): PdfDoc =
  ## String convenience wrapper; the parser views the string without
  ## copying it.
  openDoc(fromString(data), limits, password)

proc openMappedDoc*(path: string, limits = defaultPdfLimits(),
    password = ""): PdfDoc =
  ## Memory-map `path` and open it. The document borrows the mapping,
  ## so it stays usable with no heap copy of the file; release it with
  ## `close` when done. Raises IOError when the file cannot be mapped.
  openDoc(mapFile(path), limits, password)

proc close*(d: var PdfDoc) =
  ## Release the underlying file mapping, if any. Using the document
  ## afterwards raises Defect.
  d.data.close()

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
      let dec = d.decryptObj(r.refNum, r.refGen, so)
      d.cache[r.refNum] = dec
      return dec
    lx.pos = save
  # Non-stream value: re-parse through parseIndirect so endobj and
  # stray-endstream validation apply uniformly.
  let (_, _, obj) = parseIndirect(d.data, e.offset)
  let dec = d.decryptObj(r.refNum, r.refGen, obj)
  d.cache[r.refNum] = dec
  dec

proc decryptObj(d: var PdfDoc, num, gen: int, val: CosObj): CosObj =
  ## Decrypt one resolved indirect object (skipped for plain files and
  ## the /Encrypt dictionary itself). Stream bodies use the stream
  ## class; stream-dict strings and all other strings use StrF.
  ## /Metadata streams stay plaintext when EncryptMetadata is false.
  if not d.crypt.present or num == d.crypt.encryptObjNum:
    return val
  if val.kind == coStream:
    var isMeta = false
    for i, k in val.streamDict:
      if k == "Type" and val.streamVals[i].kind == coName and
          val.streamVals[i].name == "Metadata":
        isMeta = true
    var dict = newSeq[CosObj](val.streamVals.len)
    for i, v in val.streamVals:
      dict[i] = d.crypt.decryptValue(v, num, gen, d.crypt.strCrypt)
    if isMeta and not d.crypt.encryptMetadata:
      return CosObj(kind: coStream, streamDict: val.streamDict,
        streamVals: dict, raw: val.raw)
    return CosObj(kind: coStream, streamDict: val.streamDict,
      streamVals: dict,
      raw: d.crypt.decryptData(num, gen, val.raw, d.crypt.stmCrypt))
  d.crypt.decryptValue(val, num, gen, d.crypt.strCrypt)

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
