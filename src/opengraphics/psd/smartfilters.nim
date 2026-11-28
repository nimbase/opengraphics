## Smart-filter stacks: typed read-only views over `filterFX`.
##
## Layout via `references/photocraft` (`smart_map`, `blocks.parse_smart`):
## `SoLd`/`SoLE` descriptor holds `filterFX` (class `filterFXStyle`) with
## `enab`, mask flags and `filterFXList` (application order, first = bottom).
## Each item carries `Nm` (menu text), `blendOptions` (`Opct` UntF #Prc,
## `Md` enum BlnM), `enab`, optional `Fltr` (dialog params, class = filter
## class e.g. `GsnB`) and `filterID` (4-char code or numeric).
##
## `FEid`/`FXid` global blocks cache the smart filter's unfiltered pixels
## and mask, keyed by the placed object's id. Only the envelope is typed
## below (identity, rect, depth); the planes stay in `raw` until filter
## evaluation exists to use them.
## Nothing here rewrites a file; it only reads.

import std/options

import ./descriptor
import ./error
import ./io
import ./layers
import ./tagged

type
  SmartFilter* = object
    raw*: Descriptor
    name*: string ## localized menu text (`Nm`)
    filterClass*: string ## `Fltr` class, e.g. "GsnB"; "" when absent
    filterId*: int32
    hasFilterId*: bool
    command*: string ## mapped command, or "psd.unsupportedFilter"
    blend*: string ## `blendOptions.Md` value, e.g. "Nrml"; "" when absent
    opacity*: float32 ## 0..1
    visible*: bool

  FilterStack* = object
    enabled*: bool
    maskEnabled*: bool
    maskLinked*: bool
    filters*: seq[SmartFilter]

const
  UnsupportedFilter* = "psd.unsupportedFilter"
  FilterCommands*: array[54, tuple[class, command: string]] = [
    ("GsnB", "filter.blur.gaussianBlur"),
    ("boxblur", "filter.blur.boxBlur"),
    ("MtnB", "filter.blur.motionBlur"),
    ("surfaceBlur", "filter.blur.surfaceBlur"),
    ("SmrB", "filter.blur.smartBlur"),
    ("RdlB", "filter.blur.radialBlur"),
    ("UnsM", "filter.sharpen.unsharpMask"),
    ("AdNs", "filter.noise.addNoise"),
    ("Mdn ", "filter.noise.median"),
    ("HghP", "filter.other.highPass"),
    ("Mxm ", "filter.other.maximum"),
    ("Mnm ", "filter.other.minimum"),
    ("Ofst", "filter.other.offset"),
    ("Cstm", "filter.other.custom"),
    ("Msc ", "filter.pixelate.mosaic"),
    ("Mztn", "filter.pixelate.mezzotint"),
    ("ClrH", "filter.pixelate.colorHalftone"),
    ("Embs", "filter.stylize.emboss"),
    ("Dfs ", "filter.stylize.diffuse"),
    ("TrcC", "filter.stylize.traceContour"),
    ("Crst", "filter.pixelate.crystallize"),
    ("Pntl", "filter.pixelate.pointillize"),
    ("Wnd ", "filter.stylize.wind"),
    ("Extr", "filter.stylize.extrude"),
    ("Tls ", "filter.stylize.tiles"),
    ("Lvls", "image.adjustments.levels"),
    ("Crvs", "image.adjustments.curves"),
    ("adaptCorrect", "image.adjustments.shadowsHighlights"),
    ("Blr ", "filter.blur.blur"),
    ("BlrM", "filter.blur.blurMore"),
    ("Avrg", "filter.blur.average"),
    ("Dspc", "filter.noise.despeckle"),
    ("FndE", "filter.stylize.findEdges"),
    ("Fct ", "filter.pixelate.facet"),
    ("Frgm", "filter.pixelate.fragment"),
    ("Shrp", "filter.sharpen.sharpen"),
    ("ShrM", "filter.sharpen.sharpenMore"),
    ("ShrE", "filter.sharpen.sharpenEdges"),
    ("Slrz", "filter.stylize.solarize"),
    ("smartSharpen", "filter.sharpen.smartSharpen"),
    ("DstS", "filter.noise.dustAndScratches"),
    ("Pnch", "filter.distort.pinch"),
    ("Plr ", "filter.distort.polarCoordinates"),
    ("Rple", "filter.distort.ripple"),
    ("Sphr", "filter.distort.spherize"),
    ("Twrl", "filter.distort.twirl"),
    ("Wave", "filter.distort.wave"),
    ("ZgZg", "filter.distort.zigZag"),
    ("Invr", "image.adjustments.invert"),
    ("LnsF", "filter.render.lensFlare"),
    ("GEfc", "psd.unsupportedFilter"),
    ("cameraRaw", "psd.unsupportedFilter"),
    ("Displace", "psd.unsupportedFilter"),
    ("HStr", "psd.unsupportedFilter"),
  ]

proc commandFor*(filterClass: string): string =
  for (c, cmd) in FilterCommands:
    if c == filterClass: return cmd
  UnsupportedFilter

proc parseSmartFilter*(d: Descriptor): SmartFilter =
  result.raw = d
  result.name = d.getText("Nm  ")
  result.visible = d.getBool("enab", true)
  let fl = d.getDescriptor("Fltr")
  if fl.isSome:
    result.filterClass = fl.get().classId.asString()
    result.command = commandFor(result.filterClass)
  else:
    result.command = commandFor("")
  if result.command == UnsupportedFilter and result.filterClass.len == 0:
    # No-options filters (Blur, Sharpen...) carry only filterID; keep the
    # numeric id as the identity and stay unsupported without a class.
    result.command = UnsupportedFilter
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

type
  FilterCacheItem* = object
    ## One `FEid`/`FXid` global block: the cached filter source for the
    ## placed object `placedId`, over `rect` at `depth` bits. The RLE planes
    ## and mask stay in `raw`; only the envelope is typed.
    placedId*: string
    rect*: Rect
    depth*: int
    raw*: Span

proc parseFilterCache*(data: Span): Option[FilterCacheItem] =
  ## Envelope of one `FEid`/`FXid` item: a length prefix trio, the placed id
  ## as a length-byte string, three opaque words, the item rect and the bit
  ## depth. The string padding is not fixed across writers, so both
  ## alignments are tried and the one with a sane rect wins; anything else
  ## returns `none` and the caller keeps the block raw.
  if data.len < 16: return none(FilterCacheItem)
  var r = initReader(data)
  try:
    discard r.readU32BE() # version-ish
    discard r.readU32BE() # flags-ish, zero in the wild
    let rest = int(r.readU32BE())
    if rest + 12 != data.len: return none(FilterCacheItem)
    if r.remaining() < 1: return none(FilterCacheItem)
    let n = int(r.readU8())
    if n < 1 or n > 128: return none(FilterCacheItem)
    let idAbs = r.pos
    if data.len < (idAbs - data.start) + n + 12 + 16 + 4:
      return none(FilterCacheItem)
    var idBytes = newString(n)
    for k in 0 ..< n:
      let b = ord(data.byteAt((idAbs - data.start) + k))
      if b < 0x20 or b > 0x7E: return none(FilterCacheItem)
      idBytes[k] = char(b)
    for pad in [0, 1]:
      let baseRel = (idAbs - data.start) + n + pad
      if data.len < baseRel + 12 + 16 + 4: continue
      var f = initReader(data.slice(baseRel, data.len))
      discard f.readU32BE() # three opaque words
      discard f.readU32BE()
      discard f.readU32BE()
      let top = f.readI32BE()
      let left = f.readI32BE()
      let bottom = f.readI32BE()
      let right = f.readI32BE()
      let depth = int(f.readU32BE())
      if top >= bottom or left >= right: continue
      if abs(int64(bottom) - int64(top)) > 300000 or
          abs(int64(right) - int64(left)) > 300000:
        continue
      if depth notin [1, 8, 16, 32]: continue
      return some(FilterCacheItem(placedId: idBytes,
        rect: Rect(top: top, left: left, bottom: bottom, right: right),
        depth: depth, raw: data))
    none(FilterCacheItem)
  except PsdError:
    none(FilterCacheItem)

proc filterCacheItems*(blocks: openArray[TaggedBlock]): seq[FilterCacheItem] =
  ## Every parseable `FEid`/`FXid` cache item; unreadable blocks stay raw in
  ## the file and are skipped here rather than raising.
  for b in blocks:
    if b.key == "FEid" or b.key == "FXid":
      let it = parseFilterCache(b.data)
      if it.isSome: result.add(it.get())

proc placedFilterCache*(blocks: openArray[TaggedBlock],
    placedId: string): Option[FilterCacheItem] =
  ## The cache item for one placed object id, or `none`.
  for it in filterCacheItems(blocks):
    if it.placedId == placedId: return some(it)
  none(FilterCacheItem)
