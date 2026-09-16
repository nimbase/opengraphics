## Interactive form fields: extraction, fill, flatten (M11).
##
## `formFields` walks the catalog /AcroForm /Fields tree with /Parent
## inheritance (FT, Ff, V, DV, DA, TU, Q, Opt, MaxLen) and returns one
## `FormField` per value-holding field: dotted name, tooltip label
## (/TU), kind, value, default, options, flags, font, alignment, and
## widget placements. `getField` fetches one by name, loudly.
##
## Fill stamps values through `PdfUpdate` (one appended section per
## call; chain calls to fill several fields) and raises
## /NeedAppearances so viewers regenerate appearances. `flattenFields`
## bakes text, checks, radios, and choices into page content, drops
## the widget annotations, and prunes the field tree. Signature and
## pushbutton fields are extracted but never filled or flattened.

import std/sets
import std/strutils
import std/tables
import ./types
import ./cos
import ./docmodel
import ./write
import ./fontembed

type
  FieldKind* = enum
    fkText, fkCheckbox, fkRadio, fkDropdown, fkListBox, fkSignature,
    fkPushButton, fkUnknown

  FieldOption* = tuple[value, display: string]

  FieldWidget* = object
    page*: int ## 0-based page index (-1 when unplaced)
    rect*: tuple[x1, y1, x2, y2: float64]
    appearance*: string ## current /AS ("" when absent)

  FormField* = object
    name*: string ## dotted partial-name chain
    label*: string ## /TU tooltip ("" when absent)
    kind*: FieldKind
    value*: string ## /V text or selected name ("" when none/Off)
    defaultValue*: string ## /DV ("" when absent)
    options*: seq[FieldOption] ## choice Opt or button on-states
    maxLen*: int ## /MaxLen (-1 when absent)
    readOnly*: bool
    required*: bool
    multiline*: bool
    password*: bool
    combo*: bool ## choice is a dropdown (else list box)
    editable*: bool ## combo accepts arbitrary text
    fontName*: string ## from /DA ("" when absent)
    fontSize*: float64 ## from /DA (-1 when absent)
    align*: int ## /Q quadding 0 left 1 center 2 right
    widgets*: seq[FieldWidget]

  PathStep* = tuple[isKey: bool, key: string, idx: int]

  Inh* = object ## inherited attributes carried down the field tree
    ft*, v*, dv*, da*, tu*, opt*: CosObj
    ff*, q*, maxLen*: int
    hasFf*, hasQ*, hasMaxLen*: bool

  RawWidget = object
    node: CosObj ## resolved widget dict
    refNum: int ## -1 when the widget is a direct dict
    fieldPath: seq[PathStep] ## steps from /AcroForm to the field node

  RawField* = object
    node*: CosObj
    nodeRef*: CosObj ## coRef or coNull
    path*: seq[PathStep] ## steps from /AcroForm to this node
    fullName*: string
    inh*: Inh
    widgetRefs*: seq[CosObj] ## kid refs/nodes that are widgets
    selfWidget*: bool ## the field node itself is a widget annot

proc nullInh(): Inh =
  Inh(ft: CosObj(kind: coNull), v: CosObj(kind: coNull),
    dv: CosObj(kind: coNull), da: CosObj(kind: coNull),
    tu: CosObj(kind: coNull), opt: CosObj(kind: coNull),
    ff: 0, q: 0, maxLen: -1,
    hasFf: false, hasQ: false, hasMaxLen: false)

proc hasFlag(ff, bit: int): bool =
  (ff and (1 shl bit)) != 0

proc inheritAttrs(node: CosObj, parent: Inh): Inh =
  ## Overlay own entries on the parent's inherited set.
  result = parent
  if node.dictGet("FT").kind != coNull:
    result.ft = node.dictGet("FT")
  if node.dictGet("Ff").kind == coInt:
    result.ff = node.dictGet("Ff").ival
    result.hasFf = true
  if node.dictGet("V").kind != coNull:
    result.v = node.dictGet("V")
  if node.dictGet("DV").kind != coNull:
    result.dv = node.dictGet("DV")
  if node.dictGet("DA").kind != coNull:
    result.da = node.dictGet("DA")
  if node.dictGet("TU").kind != coNull:
    result.tu = node.dictGet("TU")
  if node.dictGet("Q").kind == coInt:
    result.q = node.dictGet("Q").ival
    result.hasQ = true
  if node.dictGet("Opt").kind != coNull:
    result.opt = node.dictGet("Opt")
  if node.dictGet("MaxLen").kind == coInt:
    result.maxLen = node.dictGet("MaxLen").ival
    result.hasMaxLen = true

proc asText(o: CosObj): string =
  case o.kind
  of coStr: o.sval
  of coName: o.name
  else: pdfFail("field value must be a string or name")

proc kindOf*(inh: Inh): FieldKind =
  if inh.ft.kind != coName:
    return fkUnknown
  case inh.ft.name
  of "Tx": fkText
  of "Ch":
    if hasFlag(inh.ff, 17): fkDropdown else: fkListBox
  of "Btn":
    if hasFlag(inh.ff, 16): fkPushButton
    elif hasFlag(inh.ff, 15): fkRadio
    else: fkCheckbox
  of "Sig": fkSignature
  else: fkUnknown

proc parseOpt(opt: CosObj): seq[FieldOption] =
  ## /Opt items: plain strings/names, or [export display] pairs.
  result = @[]
  if opt.kind != coArray:
    return
  for item in opt.items:
    if item.kind == coArray and item.items.len >= 2:
      let v = item.items[0]
      let w = item.items[1]
      if v.kind == coStr and w.kind == coStr:
        result.add((v.sval, w.sval))
    elif item.kind == coStr:
      result.add((item.sval, item.sval))
    elif item.kind == coName:
      result.add((item.name, item.name))

proc onStates(widget: CosObj): seq[string] =
  ## Non-Off keys of the widget /AP /N dict (appearance on-states).
  result = @[]
  let ap = widget.dictGet("AP")
  if ap.kind != coDict:
    return
  let n = ap.dictGet("N")
  if n.kind != coDict:
    return
  for k in n.keys:
    if k != "Off":
      result.add(k)

proc parseDa(da: CosObj, fontName: var string, fontSize: var float64) =
  fontName = ""
  fontSize = -1.0
  if da.kind != coStr:
    return
  let toks = da.sval.splitWhitespace()
  for i, t in toks:
    if t == "Tf" and i >= 2:
      fontName = toks[i - 2]
      if fontName.len > 0 and fontName[0] == '/':
        fontName = fontName[1 .. ^1]
      try:
        fontSize = parseFloat(toks[i - 1])
      except ValueError:
        discard

proc readRect(widget: CosObj): tuple[x1, y1, x2, y2: float64] =
  let r = widget.dictGet("Rect")
  if r.kind != coArray or r.items.len != 4:
    pdfFail("widget annotation missing /Rect array of 4 numbers")
  (r.items[0].asFloat(), r.items[1].asFloat(), r.items[2].asFloat(),
    r.items[3].asFloat())

proc walkFields(d: var PdfDoc, nodeVal: CosObj, nodeRef: CosObj,
    path: seq[PathStep], parentName: string, inh: Inh,
    fields: var seq[RawField], seen: var HashSet[int]) =
  ## Depth-first field walk. Kids with /T recurse as sub-fields;
  ## other dict kids are widget annotations of this node.
  let node = d.resolve(nodeVal)
  if node.kind != coDict:
    pdfFail("form field node is not a dictionary")
  if nodeRef.kind == coRef:
    if nodeRef.refNum in seen:
      pdfFail("circular reference in form field tree at object " &
        $nodeRef.refNum)
    seen.incl(nodeRef.refNum)
  var fullName = parentName
  let t = node.dictGet("T")
  if t.kind == coStr:
    fullName = if fullName.len > 0: fullName & "." & t.sval
      else: t.sval
  let cur = inheritAttrs(node, inh)
  let sub = node.dictGet("Subtype")
  let selfWidget = sub.kind == coName and sub.name == "Widget"
  var rf = RawField(node: node, nodeRef: nodeRef, path: path,
    fullName: fullName, inh: cur, widgetRefs: @[],
    selfWidget: selfWidget)
  let kids = node.dictGet("Kids")
  if kids.kind == coArray:
    for i, k in kids.items:
      let knode = d.resolve(k)
      if knode.kind != coDict:
        pdfFail("form field kid is not a dictionary")
      if knode.dictGet("T").kind == coStr:
        # A named kid is a sub-field, even when merged with its
        # widget annotation (/Subtype /Widget + /FT of its own).
        var sub2 = path
        sub2.add((isKey: true, key: "Kids", idx: 0))
        sub2.add((isKey: false, key: "", idx: i))
        let kref = if k.kind == coRef: k else: CosObj(kind: coNull)
        d.walkFields(k, kref, sub2, fullName, cur, fields, seen)
      else:
        rf.widgetRefs.add(k)
  if cur.ft.kind == coName:
    fields.add(rf)
  elif kids.kind != coArray and not selfWidget:
    pdfFail("form field '" & fullName & "' has no /FT and no kids")

proc collectWidgets(d: var PdfDoc, f: RawField,
    widgets: var seq[RawWidget]) =
  if f.selfWidget:
    widgets.add(RawWidget(node: f.node,
      refNum: if f.nodeRef.kind == coRef: f.nodeRef.refNum else: -1,
      fieldPath: f.path))
  for k in f.widgetRefs:
    let w = d.resolve(k)
    widgets.add(RawWidget(node: w,
      refNum: if k.kind == coRef: k.refNum else: -1,
      fieldPath: f.path))

proc pageAnnots(d: var PdfDoc): seq[tuple[page: int,
    path: seq[PathStep], annots: CosObj]] =
  ## (page index, steps from catalog to the page dict, /Annots value)
  ## for every page carrying annotations.
  result = @[]
  let cat = d.catalog()
  let pagesRef = cat.dictGet("Pages")
  if pagesRef.kind != coRef:
    pdfFail("PDF catalog missing /Pages reference")
  var stack: seq[tuple[node: CosObj, path: seq[PathStep],
      depth: int]] = @[(pagesRef, @[(isKey: true, key: "Pages",
      idx: 0)], 0)]
  var pageIdx = 0
  while stack.len > 0:
    let (nref, ppath, depth) = stack.pop()
    if depth > d.limits.maxWalkDepth:
      pdfFail("page tree exceeds nesting depth")
    let node = d.resolve(nref)
    if node.kind != coDict:
      pdfFail("page tree node is not a dictionary")
    let kids = node.dictGet("Kids")
    if kids.kind == coArray:
      for i in countdown(kids.items.len - 1, 0):
        if kids.items[i].kind != coRef:
          pdfFail("page tree kid is not an indirect reference")
        var sub = ppath
        sub.add((isKey: true, key: "Kids", idx: 0))
        sub.add((isKey: false, key: "", idx: i))
        stack.add((kids.items[i], sub, depth + 1))
    else:
      let ann = node.dictGet("Annots")
      if ann.kind != coNull:
        result.add((pageIdx, ppath, ann))
      inc pageIdx

proc placeWidgets(d: var PdfDoc, raw: seq[RawField]): seq[seq[FieldWidget]] =
  ## Match field widgets to page annotations by object number (or by
  ## /Parent for direct-dict widgets). Returns parallel placements.
  var byNum = initTable[int, int]() ## widget refNum -> field index
  var widgets: seq[RawWidget] = @[]
  for fi, f in raw:
    var ws: seq[RawWidget] = @[]
    d.collectWidgets(f, ws)
    for w in ws:
      if w.refNum >= 0:
        byNum[w.refNum] = fi
      widgets.add(w)
  result = newSeq[seq[FieldWidget]](raw.len)
  for i in 0 ..< raw.len:
    result[i] = @[]
  for (page, _, annotsRef) in d.pageAnnots():
    let annots = d.resolve(annotsRef)
    if annots.kind != coArray:
      pdfFail("page /Annots is not an array")
    for a in annots.items:
      if a.kind == coRef and byNum.hasKey(a.refNum):
        let fi = byNum[a.refNum]
        let w = d.resolve(a)
        var ap = ""
        if w.dictGet("AS").kind == coName:
          ap = w.dictGet("AS").name
        result[fi].add(FieldWidget(page: page, rect: readRect(w),
          appearance: ap))
      elif a.kind == coDict:
        let sub = a.dictGet("Subtype")
        if sub.kind == coName and sub.name == "Widget":
          let par = a.dictGet("Parent")
          if par.kind == coRef:
            for fi, f in raw:
              if f.nodeRef.kind == coRef and
                  f.nodeRef.refNum == par.refNum:
                var ap = ""
                if a.dictGet("AS").kind == coName:
                  ap = a.dictGet("AS").name
                result[fi].add(FieldWidget(page: page,
                  rect: readRect(a), appearance: ap))

proc toField(f: RawField, placed: seq[FieldWidget]): FormField =
  let kind = kindOf(f.inh)
  var value = ""
  if f.inh.v.kind != coNull and f.inh.v.kind != coStream:
    let s = asText(f.inh.v)
    value = if kind in {fkCheckbox, fkRadio} and s == "Off": "" else: s
  var dv = ""
  if f.inh.dv.kind != coNull and f.inh.dv.kind != coStream:
    dv = asText(f.inh.dv)
  var options: seq[FieldOption] = @[]
  if kind in {fkDropdown, fkListBox, fkRadio}:
    options = parseOpt(f.inh.opt)
  # Button on-states resolve from widget appearance dicts; the caller
  # fills them in (it owns the resolved dicts).
  var label = ""
  if f.inh.tu.kind == coStr:
    label = f.inh.tu.sval
  var fontName = ""
  var fontSize = -1.0
  parseDa(f.inh.da, fontName, fontSize)
  FormField(name: f.fullName, label: label, kind: kind, value: value,
    defaultValue: dv, options: options,
    maxLen: f.inh.maxLen,
    readOnly: hasFlag(f.inh.ff, 0), required: hasFlag(f.inh.ff, 1),
    multiline: kind == fkText and hasFlag(f.inh.ff, 12),
    password: kind == fkText and hasFlag(f.inh.ff, 13),
    combo: kind == fkDropdown,
    editable: kind == fkDropdown and hasFlag(f.inh.ff, 18),
    fontName: fontName, fontSize: fontSize,
    align: if f.inh.hasQ: f.inh.q else: 0,
    widgets: placed)

proc rawFields*(d: var PdfDoc): seq[RawField] =
  result = @[]
  let cat = d.catalog()
  let acro = cat.dictGet("AcroForm")
  if acro.kind == coNull:
    return
  let resolved = d.resolve(acro)
  if resolved.kind != coDict:
    pdfFail("catalog /AcroForm is not a dictionary")
  let fields = resolved.dictGet("Fields")
  if fields.kind != coArray:
    pdfFail("AcroForm missing /Fields array")
  var seen = initHashSet[int]()
  for i, k in fields.items:
    # Steps below /AcroForm: the "Fields" key, then the element.
    var path: seq[PathStep] = @[(isKey: true, key: "Fields", idx: 0),
      (isKey: false, key: "", idx: i)]
    let kref = if k.kind == coRef: k else: CosObj(kind: coNull)
    d.walkFields(k, kref, path, "", nullInh(), result, seen)

proc formFields*(d: var PdfDoc): seq[FormField] =
  ## Every value-holding field in document order with inherited
  ## attributes resolved and widgets placed on pages.
  let raw = d.rawFields()
  let placed = d.placeWidgets(raw)
  result = @[]
  for i, f in raw:
    var opts = toField(f, placed[i])
    if opts.kind == fkCheckbox or opts.kind == fkRadio:
      # on-states need the resolved widget dicts, not placements
      var states: seq[FieldOption] = @[]
      var seenStates = initTable[string, bool]()
      var dicts: seq[CosObj] = @[]
      if f.selfWidget:
        dicts.add(f.node)
      for k in f.widgetRefs:
        dicts.add(d.resolve(k))
      for wd in dicts:
        for s in onStates(wd):
          if not seenStates.hasKey(s):
            seenStates[s] = true
            states.add((s, s))
      opts.options = states
    result.add(opts)

proc fieldNames*(d: var PdfDoc): seq[string] =
  ## Dotted names of every value-holding field.
  for f in d.formFields():
    result.add(f.name)

proc getField*(d: var PdfDoc, name: string): FormField =
  ## One field by dotted name; PdfError when absent.
  for f in d.formFields():
    if f.name == name:
      return f
  pdfFail("no form field named '" & name & "'")

proc isChecked*(f: FormField): bool =
  ## Checkbox/radio selected state from the field value.
  f.kind in {fkCheckbox, fkRadio} and f.value.len > 0 and
    f.value != "Off"

# ---------------------------------------------------------------------------
# Update machinery: deep value replacement with generation tracking
# ---------------------------------------------------------------------------

proc stageBody(u: var PdfUpdate, donor: var PdfDoc,
    bumped: var Table[int, int], num: int, body: string) =
  ## Append one new generation of `num`. Each object stages at most
  ## once per update (finishUpdate keys entries by number), so repeat
  ## touches must merge first; repeats fail loudly here.
  if bumped.hasKey(num):
    pdfFail("internal error: object " & $num &
      " staged twice in one update")
  var gen = 0
  if donor.xref.entries.hasKey(num) and donor.xref.entries[num].live:
    gen = donor.xref.entries[num].gen + 1
  bumped[num] = gen
  u.addObject(num, gen, body)

proc setDictKey(keys: var seq[string], vals: var seq[CosObj], k: string,
    v: CosObj) =
  ## Replace-or-add a dictionary entry in place.
  for i, kk in keys:
    if kk == k:
      vals[i] = v
      return
  keys.add(k)
  vals.add(v)

proc navigate(donor: var PdfDoc, rootNum: int,
    path: seq[PathStep]): tuple[anchor: int, rel: seq[PathStep],
    val: CosObj] =
  ## Follow `path` from `rootNum`, re-anchoring at each indirect hop.
  ## Returns the nearest indirect anchor, the steps below it, and the
  ## value at the full path.
  var anchor = rootNum
  var rel: seq[PathStep] = @[]
  var cur = donor.resolve(CosObj(kind: coRef, refNum: rootNum,
    refGen: 0))
  for s in path:
    if cur.kind == coRef:
      anchor = cur.refNum
      cur = donor.resolve(cur)
      rel = @[]
    if s.isKey:
      if cur.kind != coDict:
        pdfFail("form path descends into a non-dictionary")
      cur = cur.dictGet(s.key)
    else:
      if cur.kind != coArray:
        pdfFail("form path descends into a non-array")
      if s.idx < 0 or s.idx >= cur.items.len:
        pdfFail("form path index out of range")
      cur = cur.items[s.idx]
    rel.add(s)
  (anchor, rel, cur)

proc updateDeep(u: var PdfUpdate, donor: var PdfDoc,
    bumped: var Table[int, int], rootNum: int, path: seq[PathStep],
    newVal: CosObj, followRef = false) =
  ## Replace the value at `path` below `rootNum`, rebuilding direct
  ## containers and staging one new anchored generation. Indirect hops
  ## re-anchor, so direct dicts/arrays at any depth work. With
  ## `followRef`, a terminal reference re-anchors to its target and
  ## the target object itself is replaced (keeps shared nodes such as
  ## merged field+widget dicts unified); otherwise the slot is
  ## replaced inline.
  if path.len == 0:
    pdfFail("form path must not be empty")
  var anchor = rootNum
  var cur = donor.resolve(CosObj(kind: coRef, refNum: rootNum,
    refGen: 0))
  var trail: seq[tuple[cont: CosObj, step: PathStep]] = @[]
  for s in path:
    if cur.kind == coRef:
      anchor = cur.refNum
      cur = donor.resolve(cur)
      trail = @[]
    if s.isKey:
      if cur.kind != coDict:
        pdfFail("form path descends into a non-dictionary")
      # A missing terminal key reads back coNull; the rebuild below
      # adds it. Deeper misses fail on the next step.
    else:
      if cur.kind != coArray:
        pdfFail("form path descends into a non-array")
      if s.idx < 0 or s.idx >= cur.items.len:
        pdfFail("form path index out of range")
    trail.add((cur, s))
    cur = if s.isKey: cur.dictGet(s.key) else: cur.items[s.idx]
  if followRef and cur.kind == coRef:
    u.stageBody(donor, bumped, cur.refNum, writeCos(newVal))
    return
  var sub = newVal
  for i in countdown(trail.len - 1, 0):
    let (cont, s) = trail[i]
    if s.isKey:
      var keys = cont.keys
      var vals = cont.vals
      var found = false
      for j, k in keys:
        if k == s.key:
          vals[j] = sub
          found = true
      if not found:
        keys.add(s.key)
        vals.add(sub)
      sub = CosObj(kind: coDict, keys: keys, vals: vals)
    else:
      var items = cont.items
      items[s.idx] = sub
      sub = CosObj(kind: coArray, items: items)
  u.stageBody(donor, bumped, anchor, writeCos(sub))

proc acroPath(fieldPath: seq[PathStep]): seq[PathStep] =
  ## Field steps live below the catalog /AcroForm entry.
  result = @[(isKey: true, key: "AcroForm", idx: 0)]
  for s in fieldPath:
    result.add(s)

proc findRaw(donor: var PdfDoc, name: string): RawField =
  for f in donor.rawFields():
    if f.fullName == name:
      return f
  pdfFail("no form field named '" & name & "'")

proc needAppearances(u: var PdfUpdate, donor: var PdfDoc,
    bumped: var Table[int, int]) =
  ## Flag viewers to regenerate widget appearances from values.
  let (_, _, acroRef) = donor.navigate(u.rootNum,
    @[(isKey: true, key: "AcroForm", idx: 0)])
  let acro = donor.resolve(acroRef)
  if acro.kind != coDict:
    return
  var keys = acro.keys
  var vals = acro.vals
  var found = false
  for i, k in keys:
    if k == "NeedAppearances":
      vals[i] = CosObj(kind: coBool, bval: true)
      found = true
  if not found:
    keys.add("NeedAppearances")
    vals.add(CosObj(kind: coBool, bval: true))
  u.updateDeep(donor, bumped, u.rootNum,
    @[(isKey: true, key: "AcroForm", idx: 0)],
    CosObj(kind: coDict, keys: keys, vals: vals), followRef = true)

proc checkDonor(donor: var PdfDoc) =
  if donor.crypt.present:
    pdfFail("form fill supports unencrypted documents only " &
      "(file has /Encrypt)")

proc setFieldValue(u: var PdfUpdate, donor: var PdfDoc,
    bumped: var Table[int, int], f: RawField, val: CosObj) =
  var keys = f.node.keys
  var vals = f.node.vals
  var found = false
  for i, k in keys:
    if k == "V":
      vals[i] = val
      found = true
  if not found:
    keys.add("V")
    vals.add(val)
  u.updateDeep(donor, bumped, u.rootNum, acroPath(f.path),
    CosObj(kind: coDict, keys: keys, vals: vals), followRef = true)

proc flipRefWidget(u: var PdfUpdate, donor: var PdfDoc,
    bumped: var Table[int, int], done: var HashSet[int],
    pagePath: seq[PathStep], annotIdx, widgetNum: int, state: string) =
  ## Flip one indirect widget's /AS, once per object per update.
  if widgetNum in done:
    return
  var full = pagePath
  full.add((isKey: true, key: "Annots", idx: 0))
  full.add((isKey: false, key: "", idx: annotIdx))
  full.add((isKey: true, key: "AS", idx: 0))
  u.updateDeep(donor, bumped, u.rootNum, full,
    CosObj(kind: coName, name: state))
  done.incl(widgetNum)

proc flipDirectWidgets(u: var PdfUpdate, donor: var PdfDoc,
    bumped: var Table[int, int], pagePath: seq[PathStep],
    flips: seq[tuple[idx: int, state: string]]) =
  ## Flip several direct-dict widgets sharing one page in a single
  ## Annots-array stage (one stage per object per update).
  var ap = pagePath
  ap.add((isKey: true, key: "Annots", idx: 0))
  let (_, _, arrRef) = donor.navigate(u.rootNum, ap)
  let arr = donor.resolve(arrRef)
  if arr.kind != coArray:
    pdfFail("page /Annots is not an array")
  var items = arr.items
  for fl in flips:
    if fl.idx < 0 or fl.idx >= items.len:
      pdfFail("widget index out of range")
    if items[fl.idx].kind != coDict:
      pdfFail("direct flip hit an indirect widget")
    var wkeys = items[fl.idx].keys
    var wvals = items[fl.idx].vals
    setDictKey(wkeys, wvals, "AS",
      CosObj(kind: coName, name: fl.state))
    items[fl.idx] = CosObj(kind: coDict, keys: wkeys, vals: wvals)
  u.updateDeep(donor, bumped, u.rootNum, ap,
    CosObj(kind: coArray, items: items))

proc widgetPositions(donor: var PdfDoc, f: RawField):
    seq[tuple[page: int, pagePath: seq[PathStep], annotIdx: int,
      refNum: int, widget: CosObj]] =
  ## Page-annotation locations of a field's widgets: ref-number match
  ## first, /Parent match for direct-dict widgets.
  result = @[]
  var nums = initTable[int, bool]()
  if f.nodeRef.kind == coRef and f.selfWidget:
    nums[f.nodeRef.refNum] = true
  for k in f.widgetRefs:
    if k.kind == coRef:
      nums[k.refNum] = true
  for (page, ppath, annotsRef) in donor.pageAnnots():
    let annots = donor.resolve(annotsRef)
    if annots.kind != coArray:
      pdfFail("page /Annots is not an array")
    for j, a in annots.items:
      if a.kind == coRef and nums.hasKey(a.refNum):
        result.add((page, ppath, j, a.refNum, donor.resolve(a)))
      elif a.kind == coDict:
        let sub = a.dictGet("Subtype")
        let par = a.dictGet("Parent")
        if sub.kind == coName and sub.name == "Widget" and
            par.kind == coRef and f.nodeRef.kind == coRef and
            par.refNum == f.nodeRef.refNum:
          result.add((page, ppath, j, -1, a))

proc finishWithAppearances(u: PdfUpdate): string =
  ## Finish the value stages, then flag /NeedAppearances in a second
  ## section. Two phases because every stage derives from the base
  ## bytes: folding the flag into the same AcroForm rebuild would
  ## need staged-value chaining.
  let tmp = u.finishUpdate()
  var d2 = openDoc(tmp)
  var u2 = beginUpdate(tmp)
  var bumped2 = initTable[int, int]()
  u2.needAppearances(d2, bumped2)
  u2.finishUpdate()

proc fillText*(base: string, name, text: string): string =
  ## Set a text field's /V (truncated to /MaxLen); returns new bytes.
  var donor = openDoc(base)
  donor.checkDonor()
  let f = donor.findRaw(name)
  if kindOf(f.inh) != fkText:
    pdfFail("field '" & name & "' is not a text field")
  if f.inh.hasFf and hasFlag(f.inh.ff, 0):
    pdfFail("field '" & name & "' is read-only")
  var v = text
  if f.inh.hasMaxLen and f.inh.maxLen >= 0 and
      v.len > f.inh.maxLen:
    v = v[0 ..< f.inh.maxLen]
  var u = beginUpdate(base)
  var bumped = initTable[int, int]()
  u.setFieldValue(donor, bumped, f, CosObj(kind: coStr, sval: v))
  u.finishWithAppearances()

proc setCheck*(base: string, name: string, checked: bool): string =
  ## Check or uncheck a checkbox (widget /AS plus field /V follow).
  var donor = openDoc(base)
  donor.checkDonor()
  let f = donor.findRaw(name)
  if kindOf(f.inh) != fkCheckbox:
    pdfFail("field '" & name & "' is not a checkbox")
  if f.inh.hasFf and hasFlag(f.inh.ff, 0):
    pdfFail("field '" & name & "' is read-only")
  var on = "Yes"
  var dicts: seq[CosObj] = @[]
  if f.selfWidget:
    dicts.add(f.node)
  for k in f.widgetRefs:
    dicts.add(donor.resolve(k))
  for wd in dicts:
    let states = onStates(wd)
    if states.len > 0:
      on = states[0]
  let state = if checked: on else: "Off"
  var u = beginUpdate(base)
  var bumped = initTable[int, int]()
  var done = initHashSet[int]()
  let positions = donor.widgetPositions(f)
  let fnum = if f.nodeRef.kind == coRef: f.nodeRef.refNum else: -1
  # A displayed merged field+widget takes /V and /AS in one stage.
  var mergedAs = false
  for pos in positions:
    if pos.refNum == fnum and fnum >= 0 and
        (pos.widget.dictGet("AS").kind != coNull or
          pos.widget.dictGet("AP").kind != coNull):
      mergedAs = true
  var fkeys = f.node.keys
  var fvals = f.node.vals
  setDictKey(fkeys, fvals, "V", CosObj(kind: coName, name: state))
  if mergedAs:
    setDictKey(fkeys, fvals, "AS", CosObj(kind: coName, name: state))
  let newField = CosObj(kind: coDict, keys: fkeys, vals: fvals)
  if fnum >= 0:
    u.stageBody(donor, bumped, fnum, writeCos(newField))
    done.incl(fnum)
  else:
    u.updateDeep(donor, bumped, u.rootNum, acroPath(f.path), newField)
  var directByPage = initTable[int, seq[tuple[idx: int,
      state: string]]]()
  var directPath = initTable[int, seq[PathStep]]()
  for pos in positions:
    if pos.widget.dictGet("AS").kind == coNull and
        pos.widget.dictGet("AP").kind == coNull:
      continue
    if pos.refNum >= 0:
      if pos.refNum == fnum and mergedAs:
        continue
      u.flipRefWidget(donor, bumped, done, pos.pagePath, pos.annotIdx,
        pos.refNum, state)
    else:
      directPath[pos.page] = pos.pagePath
      directByPage.mgetOrPut(pos.page, @[]).add((pos.annotIdx, state))
  for page, flips in directByPage:
    u.flipDirectWidgets(donor, bumped, directPath[page], flips)
  u.finishWithAppearances()

proc selectRadio*(base: string, group, option: string): string =
  ## Select one radio option (parent /V plus each kid widget /AS;
  ## exclusivity holds by construction). "Off" clears when the group
  ## allows toggling off.
  var donor = openDoc(base)
  donor.checkDonor()
  let f = donor.findRaw(group)
  if kindOf(f.inh) != fkRadio:
    pdfFail("field '" & group & "' is not a radio group")
  if f.inh.hasFf and hasFlag(f.inh.ff, 0):
    pdfFail("field '" & group & "' is read-only")
  if option == "Off" and f.inh.hasFf and
      hasFlag(f.inh.ff, 14):
    pdfFail("radio group '" & group & "' cannot toggle off")
  # option must be a known on-state (or Off)
  var known = option == "Off"
  var dicts: seq[CosObj] = @[]
  if f.selfWidget:
    dicts.add(f.node)
  for k in f.widgetRefs:
    dicts.add(donor.resolve(k))
  for wd in dicts:
    if option in onStates(wd):
      known = true
  if not known:
    # /Opt export values also select
    for o in parseOpt(f.inh.opt):
      if option == o.value or option == o.display:
        known = true
  if not known:
    pdfFail("radio group '" & group & "' has no option '" & option &
      "'")
  var u = beginUpdate(base)
  var bumped = initTable[int, int]()
  var done = initHashSet[int]()
  let positions = donor.widgetPositions(f)
  let fnum = if f.nodeRef.kind == coRef: f.nodeRef.refNum else: -1
  var mergedAs = false
  var mergedState = "Off"
  for pos in positions:
    if pos.refNum == fnum and fnum >= 0:
      let states = onStates(pos.widget)
      mergedState = if option != "Off" and option in states: option
        else: "Off"
      mergedAs = true
  var fkeys = f.node.keys
  var fvals = f.node.vals
  setDictKey(fkeys, fvals, "V", CosObj(kind: coName, name: option))
  if mergedAs:
    setDictKey(fkeys, fvals, "AS",
      CosObj(kind: coName, name: mergedState))
  let newField = CosObj(kind: coDict, keys: fkeys, vals: fvals)
  if fnum >= 0:
    u.stageBody(donor, bumped, fnum, writeCos(newField))
    done.incl(fnum)
  else:
    u.updateDeep(donor, bumped, u.rootNum, acroPath(f.path), newField)
  var directByPage = initTable[int, seq[tuple[idx: int,
      state: string]]]()
  var directPath = initTable[int, seq[PathStep]]()
  for pos in positions:
    let states = onStates(pos.widget)
    let st = if option != "Off" and option in states: option
      else: "Off"
    if pos.refNum >= 0:
      if pos.refNum == fnum and mergedAs:
        continue
      u.flipRefWidget(donor, bumped, done, pos.pagePath, pos.annotIdx,
        pos.refNum, st)
    else:
      directPath[pos.page] = pos.pagePath
      directByPage.mgetOrPut(pos.page, @[]).add((pos.annotIdx, st))
  for page, flips in directByPage:
    u.flipDirectWidgets(donor, bumped, directPath[page], flips)
  u.finishWithAppearances()

proc selectChoice*(base: string, name, option: string): string =
  ## Choose a dropdown/list-box option by display text or export
  ## value; /V stores the display text. Editable combos take any text.
  var donor = openDoc(base)
  donor.checkDonor()
  let f = donor.findRaw(name)
  let kind = kindOf(f.inh)
  if kind != fkDropdown and kind != fkListBox:
    pdfFail("field '" & name & "' is not a choice field")
  if f.inh.hasFf and hasFlag(f.inh.ff, 0):
    pdfFail("field '" & name & "' is read-only")
  let opts = parseOpt(f.inh.opt)
  var display = ""
  for o in opts:
    if option == o.display or option == o.value:
      display = o.display
  if display.len == 0:
    if kind == fkDropdown and f.inh.hasFf and
        hasFlag(f.inh.ff, 18):
      display = option
    else:
      pdfFail("choice field '" & name & "' has no option '" &
        option & "'")
  var u = beginUpdate(base)
  var bumped = initTable[int, int]()
  u.setFieldValue(donor, bumped, f, CosObj(kind: coStr, sval: display))
  u.finishWithAppearances()

# ---------------------------------------------------------------------------
# Flatten: bake values into page content, drop widgets, prune the tree
# ---------------------------------------------------------------------------

proc fontRef(s: string): string =
  ## Content-stream font name serialization.
  result = "/"
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.', '+'}:
      result.add(c)
    else:
      result.add('#')
      result.add(toHex(ord(c), 2))

proc fmtNum(v: float64): string =
  writeCos(CosObj(kind: coFloat, fval: v))

proc stampText(x, y, size: float64, font, text: string): string =
  "q BT " & fontRef(font) & " " & fmtNum(size) & " Tf " & fmtNum(x) &
    " " & fmtNum(y) & " Td " & writeStr(text) & " Tj ET Q\n"

proc stampCheck(x1, y1, x2, y2: float64): string =
  let w = x2 - x1
  let h = y2 - y1
  let lw = max(1.0, min(w, h) * 0.12)
  "q " & fmtNum(lw) & " w 0 G " &
    fmtNum(x1 + 0.22 * w) & " " & fmtNum(y1 + 0.45 * h) & " m " &
    fmtNum(x1 + 0.45 * w) & " " & fmtNum(y1 + 0.22 * h) & " l " &
    fmtNum(x1 + 0.78 * w) & " " & fmtNum(y1 + 0.78 * h) & " l S Q\n"

proc stampDot(x1, y1, x2, y2: float64): string =
  let cx = (x1 + x2) / 2.0
  let cy = (y1 + y2) / 2.0
  let r = min(x2 - x1, y2 - y1) * 0.3
  let k = 0.5523 * r
  "q 0 g " & fmtNum(cx + r) & " " & fmtNum(cy) & " m " &
    fmtNum(cx + r) & " " & fmtNum(cy + k) & " " &
    fmtNum(cx + k) & " " & fmtNum(cy + r) & " " &
    fmtNum(cx) & " " & fmtNum(cy + r) & " c " &
    fmtNum(cx - k) & " " & fmtNum(cy + r) & " " &
    fmtNum(cx - r) & " " & fmtNum(cy + k) & " " &
    fmtNum(cx - r) & " " & fmtNum(cy) & " c " &
    fmtNum(cx - r) & " " & fmtNum(cy - k) & " " &
    fmtNum(cx - k) & " " & fmtNum(cy - r) & " " &
    fmtNum(cx) & " " & fmtNum(cy - r) & " c " &
    fmtNum(cx + k) & " " & fmtNum(cy - r) & " " &
    fmtNum(cx + r) & " " & fmtNum(cy - k) & " " &
    fmtNum(cx + r) & " " & fmtNum(cy) & " c f Q\n"

proc displayOf(opts: seq[FieldOption], value: string): string =
  for o in opts:
    if value == o.value:
      return o.display
  value

proc flattenFields*(base: string, only: seq[string] = @[]): string =
  ## Bake fillable fields into page content and remove their widgets
  ## and field nodes (whole /AcroForm goes when empty). Text uses the
  ## /DA font at the widget rect (builtin Helvetica fallback, WinAnsi
  ## only); checks draw a stroked tick, radios a filled dot. Reports
  ## PdfError on signature fields, unknown names, encrypted input.
  var donor = openDoc(base)
  donor.checkDonor()
  let raw = donor.rawFields()
  var targets: seq[int] = @[]
  if only.len == 0:
    for i, f in raw:
      if f.fullName.len == 0:
        continue
      let kind = kindOf(f.inh)
      if kind in {fkText, fkCheckbox, fkRadio, fkDropdown, fkListBox}:
        targets.add(i)
  else:
    for name in only:
      var found = -1
      for i, f in raw:
        if f.fullName == name:
          found = i
      if found < 0:
        pdfFail("no form field named '" & name & "'")
      let kind = kindOf(raw[found].inh)
      if kind == fkSignature or kind == fkPushButton or
          kind == fkUnknown:
        pdfFail("field '" & name & "' cannot be flattened")
      targets.add(found)
  var u = beginUpdate(base)
  var bumped = initTable[int, int]()
  # Per-page accumulation keyed by page index: stamped ops, dropped
  # annot indexes, page paths, required DA fonts.
  var pageOps = initTable[int, string]()
  var dropIdx = initTable[int, HashSet[int]]()
  var pagePathOf = initTable[int, seq[PathStep]]()
  var needFont = initTable[int, seq[string]]()
  var fontNeeds = initTable[int, seq[string]]()
  var resNeeds = initTable[int, seq[string]]()
  for ti in targets:
    let f = raw[ti]
    let kind = kindOf(f.inh)
    var text = ""
    var doText = false
    var checkOn = false
    if kind == fkText:
      if f.inh.v.kind == coStr and f.inh.v.sval.len > 0:
        text = f.inh.v.sval.replace("\r\n", " ").replace("\n", " ")
          .replace("\r", " ")
        doText = true
    elif kind == fkCheckbox:
      checkOn = f.inh.v.kind == coName and f.inh.v.name != "Off"
    elif kind in {fkDropdown, fkListBox}:
      if f.inh.v.kind == coStr and f.inh.v.sval.len > 0:
        text = displayOf(parseOpt(f.inh.opt), f.inh.v.sval)
        doText = true
    var daFont = ""
    var daSize = -1.0
    parseDa(f.inh.da, daFont, daSize)
    if doText and daFont.len == 0:
      daFont = "Helv"
    if doText and daSize <= 0.0:
      daSize = 12.0
    for pos in donor.widgetPositions(f):
      pagePathOf[pos.page] = pos.pagePath
      if not dropIdx.hasKey(pos.page):
        dropIdx[pos.page] = initHashSet[int]()
      dropIdx[pos.page].incl(pos.annotIdx)
      let r = readRect(pos.widget)
      if doText:
        let size = min(daSize, max(4.0, (r.y2 - r.y1) * 0.7))
        let y = r.y1 + max(2.0, (r.y2 - r.y1 - size) * 0.4)
        pageOps.mgetOrPut(pos.page, "").add(
          stampText(r.x1 + 2.0, y, size, daFont, text))
        if daFont notin needFont.mgetOrPut(pos.page, @[]):
          needFont[pos.page].add(daFont)
      elif kind == fkCheckbox:
        var on = checkOn
        if pos.widget.dictGet("AS").kind == coName:
          on = pos.widget.dictGet("AS").name != "Off"
        if on:
          pageOps.mgetOrPut(pos.page, "").add(
            stampCheck(r.x1, r.y1, r.x2, r.y2))
      elif kind == fkRadio:
        var on = false
        if pos.widget.dictGet("AS").kind == coName:
          on = pos.widget.dictGet("AS").name != "Off"
        if on:
          pageOps.mgetOrPut(pos.page, "").add(
            stampDot(r.x1, r.y1, r.x2, r.y2))
  var touched = initHashSet[int]()
  for k in pageOps.keys:
    touched.incl(k)
  for k in dropIdx.keys:
    touched.incl(k)
  for page in touched:
    let ppath = pagePathOf[page]
    let (_, _, pageRef) = donor.navigate(u.rootNum, ppath)
    let pageVal = donor.resolve(pageRef)
    if pageVal.kind != coDict:
      pdfFail("page node is not a dictionary")
    var pkeys = pageVal.keys
    var pvals = pageVal.vals
    # Contents: extend (ref becomes a two-element array).
    if pageOps.hasKey(page):
      let sdict = CosObj(kind: coDict, keys: @["Length"],
        vals: @[CosObj(kind: coInt, ival: pageOps[page].len)])
      let snum = u.addObject(writeCos(CosObj(kind: coStream,
        streamDict: sdict.keys, streamVals: sdict.vals,
        raw: pageOps[page])))
      let sref = CosObj(kind: coRef, refNum: snum, refGen: 0)
      var ci = -1
      for i, k in pkeys:
        if k == "Contents":
          ci = i
      if ci < 0:
        pkeys.add("Contents")
        pvals.add(sref)
      elif pvals[ci].kind == coArray:
        pvals[ci].items.add(sref)
      else:
        pvals[ci] = CosObj(kind: coArray, items: @[pvals[ci], sref])
    # Annots: drop flattened widget indexes. A direct array folds
    # into the page rebuild; a referenced one stages on its own.
    var directAnnots = false
    if dropIdx.hasKey(page):
      var ai = -1
      for i, k in pkeys:
        if k == "Annots":
          ai = i
      if ai >= 0:
        let arr = donor.resolve(pvals[ai])
        if arr.kind != coArray:
          pdfFail("page /Annots is not an array")
        var kept: seq[CosObj] = @[]
        for j, a in arr.items:
          if j notin dropIdx[page]:
            kept.add(a)
        let fresh = CosObj(kind: coArray, items: kept)
        if pvals[ai].kind == coRef:
          var ap = ppath
          ap.add((isKey: true, key: "Annots", idx: 0))
          u.updateDeep(donor, bumped, u.rootNum, ap, fresh)
        else:
          pvals[ai] = fresh
          directAnnots = true
    # Resources: ensure every stamped DA font resolves (builtin
    # Helvetica fallback for missing entries). Direct dicts fold
    # into the page rebuild; referenced ones group below by object
    # number so shared dicts stage once.
    var fontFolded = false
    if needFont.hasKey(page):
      var ri = -1
      for i, k in pkeys:
        if k == "Resources":
          ri = i
      var res = if ri >= 0: donor.resolve(pvals[ri])
        else: CosObj(kind: coDict, keys: @[], vals: @[])
      if res.kind != coDict:
        pdfFail("page /Resources is not a dictionary")
      var rkeys = res.keys
      var rvals = res.vals
      var fi = -1
      for i, k in rkeys:
        if k == "Font":
          fi = i
      if fi >= 0 and rvals[fi].kind == coRef:
        for fn in needFont[page]:
          if fn notin fontNeeds.mgetOrPut(rvals[fi].refNum, @[]):
            fontNeeds[rvals[fi].refNum].add(fn)
      elif ri >= 0 and pvals[ri].kind == coRef:
        for fn in needFont[page]:
          if fn notin resNeeds.mgetOrPut(pvals[ri].refNum, @[]):
            resNeeds[pvals[ri].refNum].add(fn)
      else:
        var fontDict = if fi >= 0: donor.resolve(rvals[fi])
          else: CosObj(kind: coDict, keys: @[], vals: @[])
        if fontDict.kind != coDict:
          pdfFail("page /Resources /Font is not a dictionary")
        var fkeys = fontDict.keys
        var fvals = fontDict.vals
        for fn in needFont[page]:
          var present = false
          for k in fkeys:
            if k == fn:
              present = true
          if not present:
            fkeys.add(fn)
            fvals.add(builtinFontDict())
        let freshFonts = CosObj(kind: coDict, keys: fkeys, vals: fvals)
        if fi >= 0:
          rvals[fi] = freshFonts
        else:
          rkeys.add("Font")
          rvals.add(freshFonts)
        let freshRes = CosObj(kind: coDict, keys: rkeys, vals: rvals)
        if ri >= 0:
          pvals[ri] = freshRes
        else:
          pkeys.add("Resources")
          pvals.add(freshRes)
        fontFolded = true
    # Single page rebuild covers contents, direct annots, and
    # folded resources.
    var changed = pageOps.hasKey(page) or directAnnots or fontFolded
    if changed:
      u.updateDeep(donor, bumped, u.rootNum, ppath,
        CosObj(kind: coDict, keys: pkeys, vals: pvals),
        followRef = true)
  # Referenced font dicts: one stage each with the union of fonts.
  for num, fonts in fontNeeds:
    let fd = donor.resolve(CosObj(kind: coRef, refNum: num, refGen: 0))
    if fd.kind != coDict:
      pdfFail("page /Resources /Font is not a dictionary")
    var fkeys = fd.keys
    var fvals = fd.vals
    for fn in fonts:
      var present = false
      for k in fkeys:
        if k == fn:
          present = true
      if not present:
        fkeys.add(fn)
        fvals.add(builtinFontDict())
    u.stageBody(donor, bumped, num,
      writeCos(CosObj(kind: coDict, keys: fkeys, vals: fvals)))
  # Referenced Resources dicts with direct /Font: same treatment.
  for num, fonts in resNeeds:
    let rd = donor.resolve(CosObj(kind: coRef, refNum: num, refGen: 0))
    if rd.kind != coDict:
      pdfFail("page /Resources is not a dictionary")
    var rkeys = rd.keys
    var rvals = rd.vals
    var fi = -1
    for i, k in rkeys:
      if k == "Font":
        fi = i
    var fontDict = if fi >= 0: donor.resolve(rvals[fi])
      else: CosObj(kind: coDict, keys: @[], vals: @[])
    if fontDict.kind != coDict:
      pdfFail("page /Resources /Font is not a dictionary")
    var fkeys = fontDict.keys
    var fvals = fontDict.vals
    for fn in fonts:
      var present = false
      for k in fkeys:
        if k == fn:
          present = true
      if not present:
        fkeys.add(fn)
        fvals.add(builtinFontDict())
    let freshFonts = CosObj(kind: coDict, keys: fkeys, vals: fvals)
    if fi >= 0:
      rvals[fi] = freshFonts
    else:
      rkeys.add("Font")
      rvals.add(freshFonts)
    u.stageBody(donor, bumped, num,
      writeCos(CosObj(kind: coDict, keys: rkeys, vals: rvals)))
  # Prune flattened field nodes, grouped by container array. Empty
  # FT-less containers cascade upward so no hollow non-terminal
  # survives to trip the strict reader walk.
  var prunes = initTable[string, tuple[path: seq[PathStep],
      idxs: HashSet[int]]]()
  for ti in targets:
    let f = raw[ti]
    let cont = acroPath(f.path[0 .. ^2])
    let ckey = $cont
    if not prunes.hasKey(ckey):
      prunes[ckey] = (cont, initHashSet[int]())
    prunes[ckey].idxs.incl(f.path[^1].idx)
  var cascading = true
  while cascading:
    cascading = false
    var empties: seq[seq[PathStep]] = @[]
    for pr in prunes.values:
      let (_, _, contRef) = donor.navigate(u.rootNum, pr.path)
      let arr = donor.resolve(contRef)
      if arr.kind != coArray:
        pdfFail("form field container is not an array")
      if arr.items.len - pr.idxs.len <= 0 and pr.path.len >= 2:
        empties.add(pr.path)
    for epath in empties:
      let ownerPath = epath[0 .. ^2]
      let (_, _, ownerRef) = donor.navigate(u.rootNum, ownerPath)
      let owner = donor.resolve(ownerRef)
      if owner.kind == coDict and owner.dictGet("FT").kind == coNull and
          ownerPath[^1].isKey == false:
        let up = ownerPath[0 .. ^2]
        let ukey = $up
        let before = if prunes.hasKey(ukey): prunes[ukey].idxs.len
          else: -1
        if not prunes.hasKey(ukey):
          prunes[ukey] = (up, initHashSet[int]())
        prunes[ukey].idxs.incl(ownerPath[^1].idx)
        if prunes[ukey].idxs.len != before:
          cascading = true
  for pr in prunes.values:
    let (_, _, contRef) = donor.navigate(u.rootNum, pr.path)
    let arr = donor.resolve(contRef)
    var kept: seq[CosObj] = @[]
    for j, a in arr.items:
      if j notin pr.idxs:
        kept.add(a)
    u.updateDeep(donor, bumped, u.rootNum, pr.path,
      CosObj(kind: coArray, items: kept))
  # Drop /AcroForm when no value-holding field remains.
  var targeted = initHashSet[int]()
  for ti in targets:
    targeted.incl(ti)
  var remaining = 0
  for i, f in raw:
    if i notin targeted and f.fullName.len > 0 and
        kindOf(f.inh) != fkUnknown:
      inc remaining
  if remaining <= 0:
    # Drop the whole /AcroForm key from a fresh catalog generation.
    let catDict = donor.catalog()
    if catDict.dictGet("AcroForm").kind != coNull:
      var ckeys: seq[string] = @[]
      var cvals: seq[CosObj] = @[]
      for i, k in catDict.keys:
        if k == "AcroForm":
          continue
        ckeys.add(k)
        cvals.add(catDict.vals[i])
      u.stageBody(donor, bumped, u.rootNum,
        writeCos(CosObj(kind: coDict, keys: ckeys, vals: cvals)))
  u.finishUpdate()
