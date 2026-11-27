## Document metadata: guides, layer comps, extra channels.
##
## Read-only views over image resources. Layouts via Adobe's spec and
## `references/photocraft` (clean-room: layouts only).
##
## - 1032: u32 version (=1), u32 gridH, u32 gridV (1/32 px), u32 count, then
##   per guide u32 location (1/32 px) + u8 direction (0 vertical, 1 horizontal).
## - 1092: u32 version (=2), u32 gridH, u32 gridV, u32 count, then per guide
##   i32 pos, u8 dir, u8 unknown(0), u8 r,g,b.
## - 1065: u32 version (16) + CompList descriptor with `list` of Comp
##   (`Nm  `, `comment`, `compID`, `capturedInfo`) and `lastAppliedComp`.
## - 1097: u32 count + per guide GUIDs (kept raw; only counted).
## - Extra channels: merged planes beyond color+alpha (spot/alpha).

import std/options
import std/strutils

import ./descriptor
import ./error
import ./file
import ./header
import ./io
import ./resources

type
  Guide* = object
    position*: float64 ## pixels
    horizontal*: bool
    color*: array[3, uint8]
    hasColor*: bool

  Guides* = object
    gridH*, gridV*: float64 ## pixels
    guides*: seq[Guide]

  LayerComp* = object
    id*: int
    name*: string
    comment*: string
    captured*: int

  Comps* = object
    comps*: seq[LayerComp]
    lastApplied*: Option[int]

proc parseGuides1032*(data: Span): Guides =
  if data.len < 16:
    invalid("short guides resource (" & $data.len & " bytes)")
  var r = initReader(data)
  let ver = r.readU32BE()
  if ver != 1:
    invalid("unsupported guides version " & $ver)
  let gh = r.readU32BE()
  let gv = r.readU32BE()
  let count = r.readU32BE()
  result.gridH = float64(gh) / 32.0
  result.gridV = float64(gv) / 32.0
  for _ in 0 ..< int(count):
    if r.remaining() < 5: break
    let loc = r.readU32BE()
    let dir = r.readU8() != 0
    result.guides.add(Guide(position: float64(loc) / 32.0,
      horizontal: dir))

proc parseGuides1092*(data: Span): Guides =
  if data.len < 16:
    invalid("short guides v2 resource (" & $data.len & " bytes)")
  var r = initReader(data)
  let ver = r.readU32BE()
  if ver != 2:
    invalid("unsupported guides v2 version " & $ver)
  let gh = r.readU32BE()
  let gv = r.readU32BE()
  let count = r.readU32BE()
  result.gridH = float64(gh) / 32.0
  result.gridV = float64(gv) / 32.0
  for _ in 0 ..< int(count):
    if r.remaining() < 9: break
    let pos = r.readI32BE()
    let dir = r.readU8() != 0
    discard r.readU8() # unknown, always 0
    let rr = r.readU8()
    let gg = r.readU8()
    let bb = r.readU8()
    result.guides.add(Guide(position: float64(pos) / 32.0,
      horizontal: dir, color: [rr, gg, bb], hasColor: true))

proc guidesOf*(resources: openArray[ImageResource]): Guides =
  ## 1092 when present (has colors), else 1032, else empty.
  for id in [1092, 1032]:
    let res = getResource(resources, id)
    if res.isSome:
      try:
        if id == 1092:
          return parseGuides1092(res.get().data)
        else:
          let g = parseGuides1032(res.get().data)
          # Overlay 1092 colors when both present? Caller prefers 1092, so
          # 1032 alone has no colors.
          return g
      except PsdError:
        continue
  Guides()

proc parseComps*(data: Span): Comps =
  var r = initReader(data)
  if r.remaining() < 4:
    invalid("short comps resource")
  let ver = r.readU32BE()
  if ver != 16:
    invalid("unsupported comps version " & $ver)
  let vd =
    try: parseVersionedDescriptor(data)
    except PsdError as e: raise e
  let d = vd.descriptor
  let lst = d.get("list")
  if lst.isSome and lst.get().kind == vList:
    for it in lst.get().items:
      let dd = if it.kind == vDescriptor: it.descriptor
        elif it.kind == vGlobalObject: it.globalObject
        else: continue
      let cid = dd.get("compID")
      var id = 0
      if cid.isSome:
        case cid.get().kind
        of vInteger: id = int(cid.get().integer)
        of vDouble: id = int(cid.get().double)
        else: discard
      let cap = dd.get("capturedInfo")
      var cp = 0
      if cap.isSome:
        case cap.get().kind
        of vInteger: cp = int(cap.get().integer)
        of vDouble: cp = int(cap.get().double)
        else: discard
      result.comps.add(LayerComp(id: id, name: dd.getText("Nm  "),
        comment: dd.getText("comment"), captured: cp))
  let last = d.get("lastAppliedComp")
  if last.isSome:
    case last.get().kind
    of vInteger: result.lastApplied = some(int(last.get().integer))
    of vDouble: result.lastApplied = some(int(last.get().double))
    else: discard

proc compsOf*(resources: openArray[ImageResource]): Option[Comps] =
  let res = getResource(resources, 1065)
  if res.isNone: return none(Comps)
  try: some(parseComps(res.get().data))
  except PsdError: none(Comps)

proc extraChannelCount*(f: PsdFile): int =
  ## Merged planes beyond color + alpha (spot/alpha channels).
  let need = f.header.colorMode.colorChannelCount()
  let color = if need > 0: need else: min(f.header.channels, 3)
  let hasAlpha = f.header.channels > color
  f.header.channels - color - (if hasAlpha: 1 else: 0)

type
  DuotoneInk* = object
    name*: string
    space*: uint16
    comps*: array[4, uint16]
    curve*: seq[tuple[at, v: float64]]

  Duotone* = object
    inks*: seq[DuotoneInk]
    dotGain*: int

proc parseDuotone*(data: Span): Duotone =
  ## 524-byte color-mode data for duotone (mode 8): version 1, 1..4 inks,
  ## 4x10B colors, 4x64B Pascal names, 4x28B curves, u16 dot gain.
  if data.len < 524:
    invalid("short duotone block (" & $data.len & " bytes, need 524)")
  var r = initReader(data)
  let ver = r.readU16BE()
  if ver != 1:
    invalid("unsupported duotone version " & $ver)
  let n = int(r.readU16BE())
  if n < 1 or n > 4:
    invalid("duotone ink count " & $n & " out of 1..4")
  var colors: array[4, tuple[space: uint16, c: array[4, uint16]]]
  for i in 0 ..< 4:
    colors[i].space = r.readU16BE()
    for k in 0 ..< 4:
      colors[i].c[k] = r.readU16BE()
  var names: array[4, string]
  for i in 0 ..< 4:
    if r.remaining() < 64:
      invalid("short duotone names")
    let blk = r.bytes(64).clone
    let ln = min(int(ord(blk[0])), 63)
    names[i] = blk[1 ..< 1 + ln]
  # curves: 4x (13xi16 + i16 zero)
  var curves: array[4, seq[tuple[at, v: float64]]]
  const grayAt = [0.0, 5.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0,
    80.0, 90.0, 95.0, 100.0]
  for i in 0 ..< 4:
    for j, at in grayAt:
      let v = r.readI16BE()
      if v >= 0:
        curves[i].add((at / 100.0, float64(v) / 1000.0))
    discard r.readI16BE() # trailing zero word
  result.dotGain = int(r.readU16BE())
  for i in 0 ..< n:
    result.inks.add(DuotoneInk(name: names[i], space: colors[i].space,
      comps: colors[i].c, curve: curves[i]))

proc duotoneOf*(f: PsdFile): Option[Duotone] =
  if f.header.colorMode.kind != cmDuotone: return none(Duotone)
  try: some(parseDuotone(f.colorModeData))
  except PsdError: none(Duotone)

proc alternateDuotoneColors*(resources: openArray[ImageResource]): seq[array[3, uint16]] =
  ## Resource 1066: alternate Lab colors for book inks, in ink order.
  ## Each is 10B (space + 4 comps like duotone inks); only Lab entries are
  ## returned with their three channels, others as zeros.
  let res = getResource(resources, 1066)
  if res.isNone or res.get().data.len < 4: return @[]
  var r = initReader(res.get().data)
  try:
    if r.readU16BE() != 1: return @[]
    let n = int(r.readU16BE())
    for _ in 0 ..< n:
      if r.remaining() < 10: break
      let space = r.readU16BE()
      var c: array[4, uint16]
      for k in 0 ..< 4: c[k] = r.readU16BE()
      if space == 7: # Lab
        result.add([c[0], c[1], c[2]])
      else:
        result.add([0'u16, 0, 0])
  except PsdError:
    discard

type
  ChannelMeta* = object
    id*: int ## resource id holding the name
    name*: string

proc channelNames*(resources: openArray[ImageResource]): seq[string] =
  ## Alpha/spot channel names from 1006 (Unicode) or 1045 (ASCII), in order.
  for id in [1006, 1045]:
    let res = getResource(resources, id)
    if res.isNone: continue
    var r = initReader(res.get().data)
    try:
      if id == 1006:
        # u32 count? Actually a series of Unicode strings; read to end.
        while r.remaining() >= 4:
          let units = r.readUnicodeUnits()
          result.add(unicodeToString(units))
        if result.len > 0: return result
      else:
        # 1045: Pascal strings? Read length-prefixed ASCII to end.
        while r.remaining() >= 1:
          let n = int(r.readU8())
          if n > r.remaining(): break
          result.add(r.bytes(n).clone)
          if (r.offset and 1) != 0 and r.remaining() > 0:
            discard r.readU8() # pad
        if result.len > 0: return result
    except PsdError:
      continue
  @[]

type
  Note* = object
    author*, name*, text*: string
    open*: bool

proc parseAnno*(data: Span): seq[Note] =
  ## Global `Anno` block: u16 major (=2), u16 minor (=1), u32 count, then per
  ## annotation u32 length (incl. itself), type `txtA`/`sndA`, open u8, flags
  ## u8, optional-blocks u16, icon rect + popup rect (4xi32 each), color
  ## (u16 space + 4xu16), author/name/date Pascal strings, then u32 length of
  ## the data block (`txtC`/`sndM`, u32 size, payload). Text is UTF-16BE with
  ## BOM, lines separated by CR. Sound annotations are skipped (kept raw by
  ## the file model).
  if data.len < 8: invalid("short Anno block")
  var r = initReader(data)
  if r.readU16BE() != 2: invalid("unsupported Anno major version")
  discard r.readU16BE() # minor
  let n = int(r.readU32BE())
  for _ in 0 ..< n:
    if r.remaining() < 4: break
    let ln = int(r.readU32BE())
    if ln < 4 or ln - 4 > r.remaining(): break
    var body = r.sub(ln - 4)
    try:
      let typ = body.readStr4()
      let open = body.readU8() != 0
      discard body.readU8() # flags
      discard body.readU16BE() # optional blocks
      for _ in 0 ..< 8: discard body.readI32BE() # icon + popup rects
      discard body.readU16BE() # color space
      for _ in 0 ..< 4: discard body.readU16BE()
      let author = body.readPascal(2)
      discard body.readPascal(2) # name
      discard body.readPascal(2) # date
      if body.remaining() < 4: continue
      let dlen = int(body.readU32BE())
      if dlen < 4 or dlen - 4 > body.remaining(): continue
      var db = body.sub(dlen - 4)
      let dtype = db.readStr4()
      if typ == "txtA" and dtype == "txtC":
        if db.remaining() < 4: continue
        let size = int(db.readU32BE())
        if size > db.remaining(): continue
        let raw = db.bytes(min(size, db.remaining())).clone
        # UTF-16BE with BOM; strip BOM, CR-separated.
        var units: seq[uint16] = @[]
        var i = 0
        if raw.len >= 2 and ord(raw[0]) == 0xFE and ord(raw[1]) == 0xFF:
          i = 2
        while i + 1 < raw.len:
          units.add((uint16(ord(raw[i])) shl 8) or uint16(ord(raw[i + 1])))
          i += 2
        result.add(Note(author: author, text: unicodeToString(units)
          .replace("\r", "\n"), open: open))
    except PsdError:
      continue

proc notesOf*(f: PsdFile): seq[Note] =
  for b in f.globalBlocks:
    if b.key == "Anno":
      try: return parseAnno(b.data)
      except PsdError: continue
  @[]
