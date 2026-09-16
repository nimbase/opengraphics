## Smart objects: placed-layer data (`SoLd`, legacy `PlLd`).
##
## `tests/data/01.psd` layer 1 ("nim-lang") is a linked smart object:
## `SoLd` (1184 bytes: descriptor with file ids, page, type,
## transform, warp, bounds, size, resolution) plus the older `PlLd`
## (480 bytes: fixed struct with the same unique id and transform).
## No embedded file bytes are present (linked reference only);
## embedded-file extraction stays deferred.
##
## Layout reference: on-disk structure (libpsd has no smart-object
## support at all, so there is nothing to mirror there):
##   SoLd: 'soLD' + u32 version (=4) + descriptor (`psd/descriptor`):
##     Idnt/TEXT uuid, placed/TEXT file uuid, PgNm/long, Crop/long,
##     frameStep/Objc, duration/Objc, frameCount/long, Type/long,
##     Trnf/VlLs 8 doubles (4 placed corner points x,y), 
##     nonAffineTransform/VlLs 8 doubles, warp/Objc (warpStyle/enum,
##     value doubles, bounds/Objc with Top/Left/Btom/Rght doubles,
##     uOrder/vOrder mesh orders), Sz/Objc (Wdth/Hght doubles),
##     Rslt/UntF, comp/long
##   PlLd: 'plcL' + u32 version (=3) + 37-byte ASCII unique id
##     (`$` + uuid) + 4 x u32 + 8 x f64 transform + warp/bounds tail
##     (preserved opaquely)
##
## All payloads stay preserved verbatim in `Layer.extraBlocks`.

import std/options
import ./types
import ./reader
import ./layers
import ./descriptor

type
  PlacedLayer* = object
    raw*: seq[byte]
    kind*: string ## 'SoLd' or 'PlLd'
    version*: int
    uniqueId*: string ## Idnt uuid (SoLd) / `$`-uuid (PlLd)
    placedId*: string ## placed file uuid (SoLd only, "" when absent)
    page*: int32
    hasPage*: bool
    fileType*: int32 ## Type code, opaque (SoLd only)
    hasFileType*: bool
    transform*: array[8, float64] ## Trnf: 4 placed corners (x,y)
    hasTransform*: bool
    nonAffine*: array[8, float64]
    hasNonAffine*: bool
    boundTop*, boundLeft*, boundBottom*, boundRight*: float64
    hasBounds*: bool
    warpUOrder*, warpVOrder*: int32 ## warp mesh orders
    width*, height*: float64 ## Sz object
    hasSize*: bool
    resolution*: float64
    resolutionUnit*: string
    hasResolution*: bool
    warpStyle*: string ## e.g. 'warpNone'
    hasWarp*: bool
    trailingRaw*: seq[byte] ## PlLd warp/bounds tail, preserved

proc takeDoubles(v: seq[float64], name: string): array[8, float64] =
  if v.len != 8:
    raise newException(PsdError, "placed layer '" & name & "' wants " &
      "8 doubles, got " & $v.len)
  for i in 0 ..< 8:
    result[i] = v[i]

proc parseSoLd(data: seq[byte], limits: Limits): PlacedLayer =
  var r = initReader(data[4 .. ^1])
  let version = int(r.readU32BE())
  if version != 4:
    raise newException(PsdError, "unsupported SoLd version " & $version)
  let desc = parseDescriptor(r.readBytes(r.remaining()), limits)
  result = PlacedLayer(raw: data, kind: "SoLd", version: version,
    uniqueId: desc.getText("Idnt"), placedId: desc.getText("placed"))
  let pg = desc.findItem("PgNm")
  if pg >= 0 and desc.items[pg].value.kind == Long:
    result.page = desc.items[pg].value.num
    result.hasPage = true
  let ft = desc.findItem("Type")
  if ft >= 0 and desc.items[ft].value.kind == Long:
    result.fileType = desc.items[ft].value.num
    result.hasFileType = true
  let tr = desc.getDoubles("Trnf")
  if tr.len > 0:
    result.transform = takeDoubles(tr, "Trnf")
    result.hasTransform = true
  let na = desc.getDoubles("nonAffineTransform")
  if na.len > 0:
    result.nonAffine = takeDoubles(na, "nonAffineTransform")
    result.hasNonAffine = true
  let (wok, warp) = desc.getObject("warp")
  var boundsObj = DescObject()
  var hasBoundsObj = false
  if wok:
    result.hasWarp = true
    let si = warp.findItem("warpStyle")
    if si >= 0 and warp.items[si].value.kind == Enum:
      result.warpStyle = warp.items[si].value.enumValue
    let (bok2, bobj) = warp.getObject("bounds")
    if bok2:
      boundsObj = bobj
      hasBoundsObj = true
    let ui = warp.findItem("uOrder")
    if ui >= 0 and warp.items[ui].value.kind == Long:
      result.warpUOrder = warp.items[ui].value.num
    let vi = warp.findItem("vOrder")
    if vi >= 0 and warp.items[vi].value.kind == Long:
      result.warpVOrder = warp.items[vi].value.num
  if not hasBoundsObj:
    let (bok, bobj) = desc.getObject("bounds")
    if bok:
      boundsObj = bobj
      hasBoundsObj = true
  if hasBoundsObj:
    var vals: array[4, float64]
    var ok = true
    const keys = ["Top ", "Left", "Btom", "Rght"]
    for i, k in keys:
      let bi = boundsObj.findItem(k)
      if bi < 0 or boundsObj.items[bi].value.kind != Double:
        ok = false
        break
      vals[i] = boundsObj.items[bi].value.f
    if ok:
      result.boundTop = vals[0]
      result.boundLeft = vals[1]
      result.boundBottom = vals[2]
      result.boundRight = vals[3]
      result.hasBounds = true
  let (sok, sz) = desc.getObject("Sz  ")
  if sok:
    let wi = sz.findItem("Wdth")
    let hi = sz.findItem("Hght")
    if wi >= 0 and hi >= 0 and
        sz.items[wi].value.kind == Double and
        sz.items[hi].value.kind == Double:
      result.width = sz.items[wi].value.f
      result.height = sz.items[hi].value.f
      result.hasSize = true
  let (rok, unit, res) = desc.getUnitFloat("Rslt")
  if rok:
    result.resolution = res
    result.resolutionUnit = unit
    result.hasResolution = true

proc parsePlLd(data: seq[byte]): PlacedLayer =
  ## Fixed version-3 struct: sig + version + 37-byte `$`-uuid +
  ## 4 x u32 + 8 x f64 transform; the warp/bounds tail is preserved.
  const headLen = 4 + 4 + 37 + 16 + 64
  if data.len < headLen:
    raise newException(PsdError, "short PlLd block (" & $data.len &
      " bytes, need >= " & $headLen & ")")
  var r = initReader(data[4 .. ^1])
  let version = int(r.readU32BE())
  if version != 3:
    raise newException(PsdError, "unsupported PlLd version " & $version)
  let uuid = r.readStr(37)
  for c in uuid:
    if c notin {'$', '0'..'9', 'a'..'f', 'A'..'F', '-'}:
      raise newException(PsdError, "bad PlLd unique id")
  r.skip(16) # four u32 placement fields, preserved opaquely
  result = PlacedLayer(raw: data, kind: "PlLd", version: version,
    uniqueId: uuid, hasTransform: true)
  var bits: array[8, float64]
  for i in 0 ..< 8:
    var b: uint64 = 0
    for v in r.readBytes(8):
      b = (b shl 8) or uint64(v)
    bits[i] = cast[float64](b)
  result.transform = bits
  if r.remaining() > 0:
    result.trailingRaw = r.readBytes(r.remaining())

proc parsePlacedLayer*(data: seq[byte],
    limits = defaultLimits()): PlacedLayer =
  ## Parse one `SoLd` (descriptor) or `PlLd` (fixed struct) payload.
  if data.len < 4:
    raise newException(PsdError, "short placed layer (" & $data.len &
      " bytes)")
  let sig = char(data[0]) & char(data[1]) & char(data[2]) & char(data[3])
  if sig == "soLD":
    parseSoLd(data, limits)
  elif sig == "plcL":
    parsePlLd(data)
  else:
    raise newException(PsdError,
      "not a placed-layer block (sig '" & sig & "')")

proc placedLayer*(layer: Layer,
    limits = defaultLimits()): Option[PlacedLayer] =
  ## Parsed `SoLd` (preferred) or `PlLd` data, `none` when absent.
  for key in ["SoLd", "PlLd"]:
    let idx = findBlock(layer.extraBlocks, key)
    if idx >= 0:
      return some(parsePlacedLayer(layer.extraBlocks[idx].data, limits))
  none(PlacedLayer)

proc hasPlacedLayer*(layer: Layer): bool {.inline.} =
  findBlock(layer.extraBlocks, "SoLd") >= 0 or
    findBlock(layer.extraBlocks, "PlLd") >= 0

proc isSmartObject*(layer: Layer): bool {.inline.} =
  ## True when the layer carries placed-layer (`SoLd`/`PlLd`) data.
  layer.hasPlacedLayer()
