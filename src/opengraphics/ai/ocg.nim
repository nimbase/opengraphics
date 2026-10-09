## Optional content groups (PDF layers) for .ai import.
##
## Illustrator writes each layer as an optional content group: entries in
## the catalog's /OCProperties, with page art wrapped in `/OC name BDC
## ... EMC` marked content (or a form XObject carrying its own /OC
## entry). This module reads the group table and resolves marked-content
## properties to group indices; content.nim routes the folded nodes.
##
## Visibility is imported, never enforced at parse time: art in an
## off-group still imports, into a layer with visible=false. The Rust
## reference re-opens the file with every group on to recover hidden art;
## that trick is unnecessary here because nothing is ever skipped.
##
## Only reference-backed groups become layers. An inline OCG dictionary
## has no stable identity to share across pages, so (like the reference)
## its art routes to the page layer with a warning.

import std/tables
import std/unicode
import opendocs/pdf/cos
import opendocs/pdf/docmodel
import opendocs/pdf/types

const MaxOcgGroups* = 1024
  ## Cap on groups read from one file, mirroring the reference bound.
  ## Illustrator layer counts never approach it; beyond it groups are
  ## counted in `dropped` and their art stays on the page layer.

type
  OcgGroup* = object
    name*: string
    visible*: bool
    printable*: bool
    locked*: bool

  OcgTable* = object
    groups*: seq[OcgGroup]
    byRef*: Table[(int, int), int]
    dropped*: int ## groups beyond the cap, caller warns once
    badProps*: bool ## a BDC /OC reference failed to resolve
    badPolicy*: bool ## a non-AnyOn membership policy was approximated

proc decodeTextString*(s: string): string =
  ## A PDF text string to UTF-8: UTF-16BE with its byte order mark,
  ## UTF-8 with one, else PDFDocEncoding read as Latin-1 (which it
  ## matches for letters).
  if s.len >= 2 and s[0] == '\xFE' and s[1] == '\xFF':
    var i = 2
    while i < s.len:
      let hi =
        if i + 1 < s.len: (s[i].ord shl 8) or s[i + 1].ord
        else: -1
      if hi < 0:
        result.add($Rune(0xFFFD))
        break
      i += 2
      if hi >= 0xD800 and hi <= 0xDBFF and i + 1 < s.len:
        let lo = (s[i].ord shl 8) or s[i + 1].ord
        if lo >= 0xDC00 and lo <= 0xDFFF:
          result.add($(Rune(0x10000 + ((hi - 0xD800) shl 10) +
            (lo - 0xDC00))))
          i += 2
          continue
      result.add($Rune(hi))
  elif s.len >= 3 and s[0] == '\xEF' and s[1] == '\xBB' and s[2] == '\xBF':
    result = s[3 .. ^1]
  else:
    for c in s:
      result.add($Rune(c.ord))

proc addGroup(t: var OcgTable, key: (int, int), dict: CosObj,
    off: Table[(int, int), bool],
    locked: Table[(int, int), bool], d: var PdfDoc): int =
  ## Note group `key` (`dict` its dictionary). Returns -1 past the cap.
  if key in t.byRef:
    return t.byRef[key]
  if t.groups.len >= MaxOcgGroups:
    inc t.dropped
    return -1
  var name = ""
  let raw = dict.dictGet("Name")
  if raw.kind == coStr:
    name = decodeTextString(raw.sval)
  if name.len == 0:
    name = "Layer " & $(t.groups.len + 1)
  var printable = true
  let usage = d.resolve(dict.dictGet("Usage"))
  if usage.kind == coDict:
    let print = d.resolve(usage.dictGet("Print"))
    if print.kind == coDict:
      let state = print.dictGet("PrintState")
      if state.kind == coName and state.name == "OFF":
        printable = false
  t.groups.add(OcgGroup(name: name, visible: not off.getOrDefault(key),
    printable: printable, locked: locked.getOrDefault(key)))
  t.byRef[key] = t.groups.len - 1
  t.groups.len - 1

proc noteGroup(d: var PdfDoc, t: var OcgTable, key: (int, int),
    dict: CosObj): int =
  ## The index of group `key`, noting groups the catalog never listed
  ## (marked content may name a group /OCProperties omits).
  if key in t.byRef:
    return t.byRef[key]
  var emptyOff = initTable[(int, int), bool]()
  var emptyLocked = initTable[(int, int), bool]()
  try:
    addGroup(t, key, dict, emptyOff, emptyLocked, d)
  except PdfError:
    t.badProps = true
    -1

proc groupOfDict*(d: var PdfDoc, t: var OcgTable, dict: CosObj,
    id: CosObj): int =
  ## `dict` (resolved) is an OCG or a membership dictionary, `id` the
  ## reference it came through (or coNull). Membership routes to its
  ## first group, like the reference; a non-AnyOn policy only sets
  ## `badPolicy` since visibility lives on the layer, not the sequence.
  if dict.kind != coDict:
    return -1
  let typ = dict.dictGet("Type")
  if typ.kind == coName and typ.name == "OCMD":
    let p = dict.dictGet("P")
    if p.kind == coName and p.name != "AnyOn":
      t.badPolicy = true
    var first = CosObj(kind: coNull)
    let arr = d.resolve(dict.dictGet("OCGs"))
    if arr.kind == coArray:
      for item in arr.items:
        if item.kind == coRef:
          first = item
          break
    else:
      let single = dict.dictGet("OCGs")
      if single.kind == coRef:
        first = single
    if first.kind != coRef:
      return -1
    try:
      let gd = d.resolve(first)
      if gd.kind != coDict:
        return -1
      return noteGroup(d, t, (first.refNum, first.refGen), gd)
    except PdfError:
      t.badProps = true
      return -1
  if id.kind == coRef:
    return noteGroup(d, t, (id.refNum, id.refGen), dict)
  -1

proc readOcgs*(d: var PdfDoc): OcgTable =
  ## The catalog's /OCProperties as a group table: /OCGs array order,
  ## default states from the /D config (BaseState, then ON, then OFF),
  ## locked groups from /Locked. No /OCProperties means no groups.
  result = OcgTable(byRef: initTable[(int, int), int]())
  var props: CosObj
  try:
    props = d.resolve(d.catalog().dictGet("OCProperties"))
  except PdfError:
    return
  if props.kind != coDict:
    return
  let cfg = d.resolve(props.dictGet("D"))
  var all: seq[CosObj] = @[]
  let arr = d.resolve(props.dictGet("OCGs"))
  if arr.kind == coArray:
    for item in arr.items:
      if item.kind != coRef:
        continue
      all.add(item)
      if all.len >= MaxOcgGroups:
        break
  var off = initTable[(int, int), bool]()
  var locked = initTable[(int, int), bool]()
  if cfg.kind == coDict:
    let base = cfg.dictGet("BaseState")
    if base.kind == coName and base.name == "OFF":
      for r in all:
        off[(r.refNum, r.refGen)] = true
    for key in ["ON", "OFF"]:
      let a = d.resolve(cfg.dictGet(key))
      if a.kind != coArray:
        continue
      for item in a.items:
        if item.kind != coRef:
          continue
        let k = (item.refNum, item.refGen)
        if key == "ON":
          off.del(k)
        else:
          off[k] = true
    let la = d.resolve(cfg.dictGet("Locked"))
    if la.kind == coArray:
      for item in la.items:
        if item.kind == coRef:
          locked[(item.refNum, item.refGen)] = true
  for r in all:
    let key = (r.refNum, r.refGen)
    var g: CosObj
    try:
      g = d.resolve(r)
    except PdfError:
      continue # a broken reference names no layer; art routes by content
    if g.kind != coDict:
      continue
    discard addGroup(result, key, g, off, locked, d)

proc groupOfBdc*(d: var PdfDoc, t: var OcgTable,
    resources: CosObj, operands: seq[CosObj]): int =
  ## The group `/OC props BDC` marks, or -1 for page-layer routing: a
  ## non-/OC tag, unresolvable properties, or a direct dictionary with
  ## no identity to share across pages. Never raises; resolution
  ## failures set `badProps` for one caller warning.
  if operands.len < 2:
    return -1
  if operands[0].kind != coName or operands[0].name != "OC":
    return -1
  let p = operands[1]
  try:
    if p.kind == coName:
      let cat = d.resolve(resources.dictGet("Properties"))
      if cat.kind != coDict:
        return -1
      let entry = cat.dictGet(p.name)
      if entry.kind == coNull:
        t.badProps = true
        return -1
      let dict = d.resolve(entry)
      let id = if entry.kind == coRef: entry
        else: CosObj(kind: coNull)
      return groupOfDict(d, t, dict, id)
    if p.kind == coDict or p.kind == coStream:
      let dict = d.resolve(p)
      let oc = dict.dictGet("OC")
      if oc.kind != coRef:
        return -1
      return groupOfDict(d, t, d.resolve(oc), oc)
    -1
  except PdfError:
    t.badProps = true
    -1

proc groupOfFormOc*(d: var PdfDoc, t: var OcgTable,
    formDict: CosObj): int =
  ## The group a form XObject's own /OC entry scopes, or -1. Direct
  ## dictionaries have no cross-page identity and stay on the page
  ## layer, matching groupOfBdc.
  let oc = formDict.dictGet("OC")
  if oc.kind != coRef:
    return -1
  try:
    groupOfDict(d, t, d.resolve(oc), oc)
  except PdfError:
    t.badProps = true
    -1
