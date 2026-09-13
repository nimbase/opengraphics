## Minimal PDF object and xref-table parser (v1).
##
## Supports classic (uncompressed) xref tables plus an indirect page-tree
## walk with MediaBox inheritance, and nothing else. Streams are never
## decoded: only the leading dictionary of an object is read, the rest
## is ignored. Compressed xref streams raise an AiError that names v2
## Flate support as the missing piece, never a silent wrong answer.

import std/strutils
import std/tables
import ./types

const maxWalkDepth = 32

type
  PdfObjKind* = enum
    poNull, poBool, poInt, poFloat, poName, poStr, poRef, poArray, poDict
  PdfObj* = object
    case kind*: PdfObjKind
    of poInt: ival*: int
    of poFloat: fval*: float64
    of poBool: bval*: bool
    of poName: name*: string
    of poStr: sval*: string
    of poRef: refNum*, refGen*: int
    of poArray: items*: seq[PdfObj]
    of poDict:
      keys*: seq[string]
      vals*: seq[PdfObj]
    of poNull: discard

  Parser = object
    s: string
    pos: int

proc aiFail(msg: string) {.noreturn.} =
  raise newException(AiError, msg)

proc isWs(c: char): bool =
  c in {'\x00', '\x09', '\x0A', '\x0C', '\x0D', '\x20'}

proc isDelim(c: char): bool =
  c in {'(', ')', '<', '>', '[', ']', '{', '}', '/', '%'} or isWs(c)

proc skipWs(p: var Parser) =
  while p.pos < p.s.len:
    if isWs(p.s[p.pos]):
      inc p.pos
    elif p.s[p.pos] == '%':
      while p.pos < p.s.len and p.s[p.pos] notin {'\x0A', '\x0D'}:
        inc p.pos
    else:
      break

proc parseTableInt(p: var Parser): int =
  p.skipWs()
  let start = p.pos
  while p.pos < p.s.len and p.s[p.pos] in {'0'..'9'}:
    inc p.pos
  if start == p.pos:
    aiFail("expected integer in xref table at offset " & $start)
  try:
    parseInt(p.s[start ..< p.pos])
  except ValueError:
    aiFail("bad integer in xref table at offset " & $start)

proc hexNibble(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: aiFail("bad hex digit in PDF string")

proc parseName(p: var Parser): string =
  ## Leading '/' already consumed. Decodes #xx escapes.
  while p.pos < p.s.len and not isDelim(p.s[p.pos]):
    if p.s[p.pos] == '#' and p.pos + 2 < p.s.len and
        p.s[p.pos + 1] in HexDigits and p.s[p.pos + 2] in HexDigits:
      try:
        result.add(chr(parseHexInt(p.s[p.pos + 1 .. p.pos + 2])))
      except ValueError:
        aiFail("bad # escape in PDF name")
      p.pos += 3
    else:
      result.add(p.s[p.pos])
      inc p.pos
  if result.len == 0:
    aiFail("empty PDF name at offset " & $p.pos)

proc parseLiteral(p: var Parser): string =
  ## Leading '(' already consumed. Handles nesting and escapes.
  var depth = 1
  while p.pos < p.s.len:
    let c = p.s[p.pos]
    if c == '\\':
      inc p.pos
      if p.pos >= p.s.len:
        break
      let e = p.s[p.pos]
      case e
      of 'n': result.add('\x0A'); inc p.pos
      of 'r': result.add('\x0D'); inc p.pos
      of 't': result.add('\x09'); inc p.pos
      of 'b': result.add('\x08'); inc p.pos
      of 'f': result.add('\x0C'); inc p.pos
      of '(', ')', '\\': result.add(e); inc p.pos
      of '\x0A': inc p.pos
      of '\x0D':
        inc p.pos
        if p.pos < p.s.len and p.s[p.pos] == '\x0A':
          inc p.pos
      of '0'..'7':
        var v = 0
        for _ in 0 ..< 3:
          if p.pos < p.s.len and p.s[p.pos] in {'0'..'7'}:
            v = v * 8 + (ord(p.s[p.pos]) - ord('0'))
            inc p.pos
          else:
            break
        result.add(chr(v))
      else: result.add(e); inc p.pos
    elif c == '(':
      inc depth
      result.add(c)
      inc p.pos
    elif c == ')':
      dec depth
      inc p.pos
      if depth == 0:
        return
      result.add(c)
    else:
      result.add(c)
      inc p.pos
  aiFail("unterminated PDF string")

proc parseHexStr(p: var Parser): string =
  ## Leading '<' already consumed (not '<<').
  var hi = -1
  while p.pos < p.s.len and p.s[p.pos] != '>':
    let c = p.s[p.pos]
    inc p.pos
    if isWs(c):
      continue
    if c notin HexDigits:
      aiFail("bad hex digit in PDF string")
    let v = hexNibble(c)
    if hi < 0:
      hi = v
    else:
      result.add(chr(hi * 16 + v))
      hi = -1
  if p.pos >= p.s.len:
    aiFail("unterminated PDF hex string")
  inc p.pos # '>'
  if hi >= 0:
    result.add(chr(hi * 16))

proc parseValue(p: var Parser): PdfObj

proc parseDict(p: var Parser): PdfObj =
  ## Leading '<<' already consumed.
  result = PdfObj(kind: poDict, keys: @[], vals: @[])
  while true:
    p.skipWs()
    if p.pos + 1 < p.s.len and p.s[p.pos] == '>' and
        p.s[p.pos + 1] == '>':
      p.pos += 2
      return
    if p.pos >= p.s.len:
      aiFail("unterminated PDF dictionary")
    if p.s[p.pos] != '/':
      aiFail("expected name key in PDF dictionary at offset " & $p.pos)
    inc p.pos
    result.keys.add(p.parseName())
    result.vals.add(p.parseValue())

proc parseArray(p: var Parser): PdfObj =
  ## Leading '[' already consumed.
  result = PdfObj(kind: poArray, items: @[])
  while true:
    p.skipWs()
    if p.pos >= p.s.len:
      aiFail("unterminated PDF array")
    if p.s[p.pos] == ']':
      inc p.pos
      return
    result.items.add(p.parseValue())

proc parseNumberOrRef(p: var Parser): PdfObj =
  let start = p.pos
  if p.pos < p.s.len and p.s[p.pos] in {'+', '-'}:
    inc p.pos
  var hasDot = false
  var digits = 0
  while p.pos < p.s.len and (p.s[p.pos] in {'0'..'9'} or
      (p.s[p.pos] == '.' and not hasDot)):
    if p.s[p.pos] == '.':
      hasDot = true
    else:
      inc digits
    inc p.pos
  let tok = p.s[start ..< p.pos]
  if digits == 0:
    aiFail("bad PDF number at offset " & $start)
  if not hasDot:
    # possible indirect reference: int int R
    let save = p.pos
    p.skipWs()
    var gen = ""
    while p.pos < p.s.len and p.s[p.pos] in {'0'..'9'}:
      gen.add(p.s[p.pos])
      inc p.pos
    if gen.len > 0:
      p.skipWs()
      if p.pos < p.s.len and p.s[p.pos] == 'R' and
          (p.pos + 1 >= p.s.len or isDelim(p.s[p.pos + 1])):
        inc p.pos
        try:
          return PdfObj(kind: poRef, refNum: parseInt(tok),
            refGen: parseInt(gen))
        except ValueError:
          aiFail("bad indirect reference at offset " & $start)
    p.pos = save
    try:
      return PdfObj(kind: poInt, ival: parseInt(tok))
    except ValueError:
      aiFail("bad PDF integer at offset " & $start)
  try:
    PdfObj(kind: poFloat, fval: parseFloat(tok))
  except ValueError:
    aiFail("bad PDF number at offset " & $start)

proc parseValue(p: var Parser): PdfObj =
  p.skipWs()
  if p.pos >= p.s.len:
    aiFail("unexpected end in PDF object")
  case p.s[p.pos]
  of '<':
    if p.pos + 1 < p.s.len and p.s[p.pos + 1] == '<':
      p.pos += 2
      p.parseDict()
    else:
      inc p.pos
      PdfObj(kind: poStr, sval: p.parseHexStr())
  of '[':
    inc p.pos
    p.parseArray()
  of '(':
    inc p.pos
    PdfObj(kind: poStr, sval: p.parseLiteral())
  of '/':
    inc p.pos
    PdfObj(kind: poName, name: p.parseName())
  of '+', '-', '.', '0'..'9':
    p.parseNumberOrRef()
  else:
    for kw in ["true", "false", "null"]:
      if p.s.continuesWith(kw, p.pos):
        let after = p.pos + kw.len
        if after >= p.s.len or isDelim(p.s[after]):
          p.pos = after
          if kw == "true":
            return PdfObj(kind: poBool, bval: true)
          elif kw == "false":
            return PdfObj(kind: poBool, bval: false)
          return PdfObj(kind: poNull)
    aiFail("unsupported PDF token at offset " & $p.pos)

proc dictGet*(d: PdfObj, key: string): PdfObj =
  if d.kind == poDict:
    for i, k in d.keys:
      if k == key:
        return d.vals[i]
  PdfObj(kind: poNull)

proc asFloat*(o: PdfObj): float64 =
  case o.kind
  of poInt: float64(o.ival)
  of poFloat: o.fval
  else:
    aiFail("expected PDF number")

proc resolveRef(data: string, tab: Table[int, int], r: PdfObj): PdfObj =
  if r.kind != poRef:
    aiFail("expected indirect reference")
  if not tab.hasKey(r.refNum):
    aiFail("dangling reference to object " & $r.refNum & " 0 R")
  var p = Parser(s: data, pos: tab[r.refNum])
  discard p.parseTableInt() # object number
  discard p.parseTableInt() # generation
  p.skipWs()
  if not data.continuesWith("obj", p.pos):
    aiFail("expected 'obj' keyword for object " & $r.refNum)
  p.pos += 3
  p.parseValue() # leading dictionary; anything after (stream) is ignored

proc parseTrailer(data: string): tuple[tab: Table[int, int], root: PdfObj] =
  let tail = data[max(0, data.len - 4096) ..< data.len]
  let sx = rfind(tail, "startxref")
  if sx < 0:
    aiFail("PDF trailer not found (no startxref near EOF)")
  var i = sx + "startxref".len
  while i < tail.len and isWs(tail[i]):
    inc i
  var digits = ""
  while i < tail.len and tail[i] in {'0'..'9'}:
    digits.add(tail[i])
    inc i
  if digits.len == 0:
    aiFail("bad startxref offset")
  var off = 0
  try:
    off = parseInt(digits)
  except ValueError:
    aiFail("bad startxref offset")
  if off < 0 or off + 4 > data.len:
    aiFail("startxref offset out of range")
  if data[off ..< off + 4] != "xref":
    if data.continuesWith("obj", off) or find(
        data[off ..< min(data.len, off + 300)], "XRef") >= 0:
      aiFail("PDF uses compressed xref streams, which need v2 Flate " &
        "support (zlib) to read")
    aiFail("bad xref offset " & $off)
  var p = Parser(s: data, pos: off + 4)
  var tab = initTable[int, int]()
  while true:
    p.skipWs()
    if p.pos + 7 <= data.len and
        data[p.pos ..< p.pos + 7] == "trailer":
      break
    if p.pos >= data.len:
      aiFail("unterminated xref table")
    let first = p.parseTableInt()
    let count = p.parseTableInt()
    if count < 0 or count > 10_000_000:
      aiFail("implausible xref subsection size " & $count)
    for n in 0 ..< count:
      let eoff = p.parseTableInt()
      discard p.parseTableInt() # generation
      p.skipWs()
      if p.pos >= data.len:
        aiFail("truncated xref entry")
      let flag = data[p.pos]
      inc p.pos
      if flag == 'n':
        tab[first + n] = eoff
      elif flag != 'f':
        aiFail("bad xref entry flag, expected n or f")
  p.pos += 7 # "trailer"
  let trailer = p.parseValue()
  if trailer.kind != poDict:
    aiFail("bad PDF trailer dictionary")
  let root = dictGet(trailer, "Root")
  if root.kind != poRef:
    aiFail("PDF trailer missing /Root reference")
  (tab, root)

proc readBox(mb: PdfObj): tuple[w, h: float64] =
  if mb.kind != poArray or mb.items.len != 4:
    aiFail("page /MediaBox must be an array of 4 numbers")
  let x0 = asFloat(mb.items[0])
  let y0 = asFloat(mb.items[1])
  let x1 = asFloat(mb.items[2])
  let y1 = asFloat(mb.items[3])
  let w = x1 - x0
  let h = y1 - y0
  if w != w or h != h or w <= 0.0 or h <= 0.0:
    aiFail("page /MediaBox has non-positive size")
  (w, h)

proc walkNode(data: string, tab: Table[int, int], nodeRef: PdfObj,
    inherited: tuple[has: bool, w, h: float64], depth: int,
    limits: AiLimits, pages: var seq[tuple[w, h: float64]]) =
  if depth > maxWalkDepth:
    aiFail("page tree exceeds nesting depth 32")
  if pages.len > limits.maxPages:
    aiFail("page count exceeds limit " & $limits.maxPages)
  let node = resolveRef(data, tab, nodeRef)
  if node.kind != poDict:
    aiFail("page tree node is not a dictionary")
  var box = inherited
  let mb = dictGet(node, "MediaBox")
  if mb.kind == poArray:
    box = (true, readBox(mb).w, readBox(mb).h)
  let kids = dictGet(node, "Kids")
  if kids.kind == poArray:
    for k in kids.items:
      if k.kind != poRef:
        aiFail("page tree kid is not an indirect reference")
      walkNode(data, tab, k, box, depth + 1, limits, pages)
  else:
    let t = dictGet(node, "Type")
    if t.kind == poName and t.name == "Pages":
      aiFail("empty /Pages node in page tree")
    if not box.has:
      aiFail("page missing /MediaBox and no inherited box")
    pages.add((box.w, box.h))

proc parsePages*(data: string, limits = defaultAiLimits()):
    seq[tuple[w, h: float64]] =
  ## One (width, height) pair in points per page, in page-tree order
  ## (which matches artboard order in Illustrator-saved files).
  let (tab, root) = parseTrailer(data)
  let catalog = resolveRef(data, tab, root)
  let pagesRef = dictGet(catalog, "Pages")
  if pagesRef.kind != poRef:
    aiFail("PDF catalog missing /Pages reference")
  let pagesNode = resolveRef(data, tab, pagesRef)
  let cnt = dictGet(pagesNode, "Count")
  if cnt.kind == poInt and cnt.ival > limits.maxPages:
    aiFail("page count " & $cnt.ival & " exceeds limit " &
      $limits.maxPages)
  result = @[]
  walkNode(data, tab, pagesRef, (false, 0.0, 0.0), 0, limits, result)
