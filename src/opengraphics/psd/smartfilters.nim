## Smart-filter stacks: typed read-only views over `filterFX`.
##
## Layout via `references/photocraft` (`smart_map`, `blocks.parse_smart`):
## `SoLd`/`SoLE` descriptor holds `filterFX` (class `filterFXStyle`) with
## `enab`, mask flags and `filterFXList` (application order, first = bottom).
## Each item carries `Nm` (menu text), `blendOptions` (`Opct` UntF #Prc,
## `Md` enum BlnM), `enab`, optional `Fltr` (dialog params, class = filter
## class e.g. `GsnB`) and `filterID` (4-char code or numeric).
##
## `FEid`/`FXid` global blocks cache pixels + mask and are kept raw here;
## the layer's own pixels stay the filtered-without-mask source.
## Nothing here rewrites a file; it only reads.

import std/options

import ./descriptor
import ./error
import ./io
import ./layers

type
  SmartFilter* = object
    raw*: Descriptor
    name*: string ## localized menu text (`Nm`)
    filterClass*: string ## `Fltr` class, e.g. "GsnB"; "" when absent
    filterId*: int32
    hasFilterId*: bool
    blend*: string ## `blendOptions.Md` value, e.g. "Nrml"; "" when absent
    opacity*: float32 ## 0..1
    visible*: bool

  FilterStack* = object
    enabled*: bool
    maskEnabled*: bool
    maskLinked*: bool
    filters*: seq[SmartFilter]

proc parseSmartFilter*(d: Descriptor): SmartFilter =
  result.raw = d
  result.name = d.getText("Nm  ")
  result.visible = d.getBool("enab", true)
  let fl = d.getDescriptor("Fltr")
  if fl.isSome:
    result.filterClass = fl.get().classId.asString()
  let fid = d.get("filterID")
  if fid.isSome and fid.get().kind == vInteger:
    result.filterId = fid.get().integer
    result.hasFilterId = true
  let bo = d.getDescriptor("blendOptions")
  if bo.isSome:
    let b = bo.get()
    let md = b.get("Md  ")
    if md.isSome and md.get().kind == vEnumerated:
      result.blend = md.get().valueId.asString()
    let op = b.get("Opct")
    if op.isSome:
      case op.get().kind
      of vUnitFloat: result.opacity = float32(op.get().floatUnitValue / 100.0)
      of vDouble: result.opacity = float32(op.get().double / 100.0)
      of vInteger: result.opacity = float32(op.get().integer) / 100.0f32
      else: result.opacity = 1.0f32
    else:
      result.opacity = 1.0f32
  else:
    result.opacity = 1.0f32
    result.blend = "Nrml"

proc parseFilterStack*(d: Descriptor): Option[FilterStack] =
  let fx = d.getDescriptor("filterFX")
  if fx.isNone: return none(FilterStack)
  let f = fx.get()
  result = some(FilterStack(
    enabled: f.getBool("enab", true),
    maskEnabled: f.getBool("filterMaskEnable", true),
    maskLinked: f.getBool("filterMaskLinked", false)))
  let lst = f.get("filterFXList")
  if lst.isSome and lst.get().kind == vList:
    for it in lst.get().items:
      if it.kind == vDescriptor:
        result.get().filters.add(parseSmartFilter(it.descriptor))
      elif it.kind == vGlobalObject:
        result.get().filters.add(parseSmartFilter(it.globalObject))

proc filtersOfLayer*(layer: LayerRecord): Option[FilterStack] =
  ## The layer's smart-filter stack, from `SoLd`/`SoLE`'s descriptor.
  ## `none` when absent or unreadable; `PlLd` layers predate filters.
  for key in ["SoLd", "SoLE"]:
    let b = layer.getBlock(key)
    if b.isNone: continue
    if b.get().data.len < 8: continue
    try:
      let vd = parseVersionedDescriptor(b.get().data.slice(8, b.get().data.len))
      let st = parseFilterStack(vd.descriptor)
      if st.isSome: return st
    except PsdError:
      continue
  none(FilterStack)

proc hasSmartFilters*(layer: LayerRecord): bool {.inline.} =
  filtersOfLayer(layer).isSome and filtersOfLayer(layer).get().filters.len > 0
