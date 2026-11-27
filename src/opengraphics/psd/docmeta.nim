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
