## Semantic views over tagged blocks whose payload is itself structured:
## type layers (`TySh`), shape fills (`vscg`) and smart objects (`SoLd`).
##
## Each of these used to be decoded by scanning the block bytes for ASCII
## markers such as `"tdta"` or `"RGBC"`, which happened to work on the one
## fixture we had but could not survive an unexpected layout. They now sit on
## the real descriptor grammar in `descriptor`, so they either parse properly
## or fail loudly.
##
## Every parser here keeps the block's own bytes. Nothing in this module
## rewrites a file; it only reads.

import std/options
import std/strutils

import ./descriptor
import ./error
import ./io
import ./layers
import ./path
import ./tagged

type
  TextEngine* = object
    ## A decoded `TySh` type-tool block.
    raw*: Span   ## the block payload, verbatim, as a window into the file
    version*: int
    transform*: array[6, float64] ## xx, xy, yx, yy, tx, ty
    textVersion*: int
    text*: string ## the descriptor's `Txt  ` field
    engineText*: string ## `/Editor /Text` from the EngineData markup
    fontNames*: seq[string]
    fontSizes*: seq[float64]
    hasText*: bool

  FillKind* {.pure.} = enum
    fkSolidColor, fkUnknown

  SolidFill* = object
    raw*: Span
    red*, green*, blue*: float64 ## 0..255

  FillContent* = object
    ## A `vscg` block: a 4-byte content key then its payload.
    raw*: Span
    key*: string ## "SoCo", "GrFl", "PtFl", ...
    solid*: Option[SolidFill]
    version*: int

  PlacedLayer* = object
    ## A smart object. `SoLd` carries a descriptor and `PlLd` a fixed struct;
    ## `kind` says which, since the two hold different information.
    raw*: Span
    kind*: string ## "SoLd" or "PlLd"
    version*: int
    uniqueId*: string ## Idnt
    placedId*: string ## placed file id, "" when absent
    page*: int32
    hasPage*: bool
    fileType*: int32
    hasFileType*: bool
    transform*: array[8, float64] ## Trnf: four placed corners as x,y
    hasTransform*: bool
    nonAffine*: array[8, float64]
    hasNonAffine*: bool
    boundTop*, boundLeft*, boundBottom*, boundRight*: float64
    hasBounds*: bool
    warpStyle*: string
    hasWarp*: bool
    width*, height*: float64 ## Sz object
    hasSize*: bool
    resolution*: float64
    resolutionUnit*: string
    hasResolution*: bool
    trailing*: Span
      ## `PlLd` only: the warp/bounds tail after the fixed struct, kept so a
      ## read/write cycle is byte exact.

# --- type layers ------------------------------------------------------------

proc tyShHeader*(data: Span): tuple[version: int,
    transform: array[6, float64], textVersion: int, descriptorVersion: int,
    body: Span] =
  ## Split a `TySh` payload into its fixed header and the descriptor that
  ## follows. The header is u16 version, six f64 for the transform, u16 text
  ## version and u32 descriptor version. The descriptor itself is a bare
  ## `TxLr` body with no version of its own, followed by warp data.
  if data.len < 54:
    invalid("short TySh block (" & $data.len & " bytes)")
  var r = initReader(data)
  result.version = int(r.readU16BE())
  if result.version != 1:
    invalid("unsupported TySh version " & $result.version)
  for i in 0 ..< 6:
    result.transform[i] = r.readF64BE()
  result.textVersion = int(r.readU16BE())
  result.descriptorVersion = int(r.readU32BE())
  if result.descriptorVersion != int(DescriptorVersion):
    invalid("unsupported TySh descriptor version " & $result.descriptorVersion)
  result.body = r.peekRest()

proc normalizeReturns*(s: string): string =
  ## Photoshop stores CR for a line break; normalise to LF.
  s.replace("\r\n", "\n").replace("\r", "\n")

proc parseEngineData*(d: Descriptor): string =
  ## The ASCII EngineData markup from a descriptor's `EngineData` item.
  let v = d.get("EngineData")
  if v.isNone:
    return ""
  let val = v.get()
  if val.kind != vRawData:
    return ""
  val.rawData.clone

proc extractTextField*(d: Descriptor): string =
  ## The descriptor's `Txt ` item, which holds the rendered text. Note the
  ## key is four characters: "Txt" plus one space.
  d.getText("Txt ")

proc extractParen*(data: string, openPos: int): string =
  ## The bytes of a PostScript `( ... )` string starting at `openPos`.
  var depth = 0
  var i = openPos
  while i < data.len:
    let c = data[i]
    if c == '\\' and i + 1 < data.len:
      i += 2
      continue
    if c == '(':
      inc depth
    elif c == ')':
      dec depth
      if depth == 0:
        return data[openPos + 1 ..< i]
    inc i
  ""

proc decodeParenString*(raw: string): string =
  ## A Paren string: UTF-16BE when it starts with a BOM, else raw bytes.
  if raw.len >= 2 and raw[0] == '\xFE' and raw[1] == '\xFF':
    var units = newSeq[uint16]((raw.len - 2) div 2)
    var i = 0
    while i < units.len:
      units[i] = (uint16(ord(raw[2 + 2 * i])) shl 8) or
        uint16(ord(raw[3 + 2 * i]))
      inc i
    return unicodeToString(units)
  raw

proc fontSetSlice*(engineData: string): string =
  ## The `/FontSet [ ... ]` section, which is where the real font names live.
  ## Scanning the whole document for `/Name (` also picks up unrelated
  ## entries such as colour profiles, so scope the search here. Falls back to
  ## the whole document when there is no FontSet.
  let start = engineData.find("/FontSet")
  if start < 0:
    return engineData
  let openBracket = engineData.find('[', start)
  if openBracket < 0:
    return engineData
  var depth = 0
  var i = openBracket
  while i < engineData.len:
    if engineData[i] == '[':
      inc depth
    elif engineData[i] == ']':
      dec depth
      if depth == 0:
        return engineData[openBracket .. i]
    inc i
  engineData[openBracket .. ^1]

proc extractFontNames*(engineData: string): seq[string] =
  ## Every `/Name (...)` inside the font set. Names are PostScript or family
  ## names (`ArialMT`, `MyriadPro-Regular`); map to a local font before
  ## shaping. The set repeats the same names for each style run, so
  ## duplicates are expected and kept in document order.
  let scope = fontSetSlice(engineData)
  result = @[]
  var i = 0
  while true:
    let idx = scope.find("/Name (", i)
    if idx < 0:
      break
    let openPos = idx + "/Name ".len
    let raw = extractParen(scope, openPos)
    var name = decodeParenString(raw).strip()
    if name.len > 0 and name.len < 256:
      result.add(name)
    i = openPos + raw.len + 2

proc extractEditorText*(engineData: string): string =
  ## The editor text lives in `/Editor << /Text ( ... ) >>`. Photoshop puts
  ## `/Editor` and `/Text` on separate lines, so find `/Text (` after the
  ## `/Editor` marker rather than looking for them on one line.
  let editor = engineData.find("/Editor")
  if editor < 0:
    return ""
  let textAt = engineData.find("/Text (", editor)
  if textAt < 0:
    return ""
  normalizeReturns(decodeParenString(
    extractParen(engineData, textAt + "/Text ".len)))

proc extractFontSizes*(engineData: string): seq[float64] =
  ## Every `/FontSize <float>` in the EngineData markup.
  result = @[]
  var i = 0
  const key = "/FontSize "
  while true:
    let idx = engineData.find(key, i)
    if idx < 0:
      break
    var j = idx + key.len
    var num = ""
    while j < engineData.len and engineData[j] in {'0'..'9', '.', '-', '+',
        'e', 'E'}:
      num.add(engineData[j])
      inc j
    try:
      result.add(parseFloat(num))
    except ValueError:
      discard
    i = j

proc parseTextEngine*(data: Span): TextEngine =
  ## Parse a `TySh` payload. Raises `PsdError` on a short or unsupported
  ## header; a block whose descriptor we cannot model yields `hasText`
  ## false rather than raising.
  let head = tyShHeader(data)
  result.version = head.version
  result.transform = head.transform
  result.textVersion = head.textVersion
  result.raw = data
  let vd = tryBareDescriptor(head.body)
  if vd.isSome:
    let d = vd.get()
    let engine = parseEngineData(d)
    result.engineText = extractEditorText(engine)
    result.fontNames = extractFontNames(engine)
    result.fontSizes = extractFontSizes(engine)
    result.text = d.getText("Txt ")
  result.hasText = result.engineText.len > 0 or result.text.len > 0

proc textOf*(layer: LayerRecord): Option[TextEngine] =
  let b = layer.getBlock("TySh")
  if b.isNone:
    return none(TextEngine)
  some(parseTextEngine(b.get().data))

proc isTextLayer*(layer: LayerRecord): bool {.inline.} =
  layer.getBlock("TySh").isSome

# --- shape fills -----------------------------------------------------------

proc parseFillContent*(data: Span): FillContent =
  ## A `vscg` payload: a 4-byte content key then, for `SoCo`, a versioned
  ## descriptor whose `Clr ` object is class `RGBC`.
  if data.len < 4:
    invalid("short fill content (" & $data.len & " bytes)")
  result.raw = data
  result.key = data.head(4).clone
  if result.key != "SoCo":
    return
  let vd = tryBlockDescriptor(TaggedBlock(signature: "", key: "",
    data: data, padding: none(Span)))
  if vd.isNone:
    return
  result.version = int(vd.get().version)
  let clr = vd.get().descriptor.getDescriptor("Clr ")
  if clr.isNone:
    return
  let rgb = clr.get()
  if rgb.classId.asString() != "RGBC":
    return
  if rgb.items.len != 3:
    return
  result.solid = some(SolidFill(raw: data, red: rgb.getDouble("Rd  "),
    green: rgb.getDouble("Grn "), blue: rgb.getDouble("Bl  ")))

proc fillContent*(layer: LayerRecord): Option[FillContent] =
  let b = layer.getBlock("vscg")
  if b.isNone:
    return none(FillContent)
  some(parseFillContent(b.get().data))

proc hasFillContent*(layer: LayerRecord): bool {.inline.} =
  layer.getBlock("vscg").isSome

proc vectorMask*(layer: LayerRecord): Option[VectorMaskBlock] =
  ## `vsms` is preferred; `vmsk` is the older key for the same data.
  for key in ["vsms", "vmsk"]:
    let b = layer.getBlock(key)
    if b.isSome:
      return some(parseVectorMaskBlock(b.get().data))
  none(VectorMaskBlock)

proc hasVectorMask*(layer: LayerRecord): bool {.inline.} =
  layer.getBlock("vsms").isSome or layer.getBlock("vmsk").isSome

# --- smart objects ---------------------------------------------------------

proc takeDoubles*(v: seq[float64], what: string): array[8, float64] =
  ## The `Trnf` and `nonAffineTransform` lists hold eight doubles each: four
  ## placed corner points as x,y.
  if v.len != 8:
    newPsdError(PsdErrorKind.Invalid,
      what & " wants 8 doubles, got " & $v.len)
  for i in 0 ..< 8:
    result[i] = v[i]

proc takeBounds*(d: Descriptor): tuple[ok: bool,
    top, left, bottom, right: float64] =
  const keys = ["Top ", "Left", "Btom", "Rght"]
  var vals: array[4, float64]
  for i, k in keys:
    let v = d.get(k)
    if v.isNone or v.get().kind != vDouble:
      return (false, 0, 0, 0, 0)
    vals[i] = v.get().double
  (true, vals[0], vals[1], vals[2], vals[3])

proc parsePlLd*(data: Span): PlacedLayer =
  ## The fixed version-3 struct: "plcL" + version + a 37-byte `$`-uuid +
  ## four u32 placement fields + eight f64 transform corners. The warp/bounds
  ## tail is preserved rather than modelled.
  const headLen = 4 + 4 + 37 + 16 + 64
  if data.len < headLen:
    invalid("short PlLd block (" & $data.len & " bytes, need " & $headLen & ")")
  var r = initReader(data.slice(4, data.len))
  result.raw = data
  result.kind = "PlLd"
  result.version = int(r.readU32BE())
  if result.version != 3:
    invalid("unsupported PlLd version " & $result.version)
  result.uniqueId = r.bytes(37).clone
  for c in result.uniqueId:
    if c notin {'$', '0'..'9', 'a'..'f', 'A'..'F', '-'}:
      invalid("bad PlLd unique id '" & result.uniqueId & "'")
  r.skip(16) # four u32 placement fields, kept opaquely
  for i in 0 ..< 8:
    result.transform[i] = r.readF64BE()
  result.hasTransform = true
  result.trailing = r.peekRest()

proc parsePlacedLayer*(data: Span, limits = defaultLimits()): PlacedLayer =
  ## A `SoLd` payload ("soLD" + block version + a versioned descriptor) or a
  ## `PlLd` fixed struct. Raises for anything else.
  if data.len < 8:
    invalid("short placed layer block (" & $data.len & " bytes)")
  let sig = data.head(4).clone
  if sig == "plcL":
    return parsePlLd(data)
  if sig != "soLD":
    invalid("not a placed-layer block (sig '" & sig & "')")
  var r = initReader(data)
  discard r.readStr4()
  result.raw = data
  result.kind = "SoLd"
  result.version = int(r.readU32BE())
  if result.version != 4:
    invalid("unsupported SoLd version " & $result.version)
  let vd = parseBlockDescriptor(data, PlacedBlockPrefixLen, limits)
  let d = vd.descriptor
  result.uniqueId = d.getText("Idnt")
  result.placedId = d.getText("placed")
  let pg = d.get("PgNm")
  if pg.isSome and pg.get().kind == vInteger:
    result.page = pg.get().integer
    result.hasPage = true
  let ft = d.get("Type")
  if ft.isSome and ft.get().kind == vInteger:
    result.fileType = ft.get().integer
    result.hasFileType = true
  let tr = d.getDoubles("Trnf")
  if tr.len > 0:
    result.transform = takeDoubles(tr, "Trnf")
    result.hasTransform = true
  let na = d.getDoubles("nonAffineTransform")
  if na.len > 0:
    result.nonAffine = takeDoubles(na, "nonAffineTransform")
    result.hasNonAffine = true
  # bounds live on the warp object when there is one, else at the top level
  var boundsDesc = d
  let warp = d.getDescriptor("warp")
  if warp.isSome:
    result.hasWarp = true
    let style = warp.get().get("warpStyle")
    if style.isSome and style.get().kind == vEnumerated:
      result.warpStyle = style.get().valueId.asString()
    let wb = warp.get().getDescriptor("bounds")
    if wb.isSome:
      boundsDesc = wb.get()
  let b = takeBounds(boundsDesc)
  result.hasBounds = b.ok
  if b.ok:
    result.boundTop = b.top
    result.boundLeft = b.left
    result.boundBottom = b.bottom
    result.boundRight = b.right
  let sz = d.getDescriptor("Sz  ")
  if sz.isSome:
    let w = sz.get().getDouble("Wdth")
    let h = sz.get().getDouble("Hght")
    if sz.get().has("Wdth") and sz.get().has("Hght"):
      result.width = w
      result.height = h
      result.hasSize = true
  let res = d.getUnitFloat("Rslt")
  if res.isSome:
    result.resolution = res.get().value
    result.resolutionUnit = res.get().unit
    result.hasResolution = true

proc placedLayer*(layer: LayerRecord,
    limits = defaultLimits()): Option[PlacedLayer] =
  ## `SoLd` when present, else `PlLd`, else `none`.
  for key in ["SoLd", "PlLd"]:
    let b = layer.getBlock(key)
    if b.isSome:
      return some(parsePlacedLayer(b.get().data, limits))
  none(PlacedLayer)

proc isSmartObject*(layer: LayerRecord): bool {.inline.} =
  ## True when the layer carries placed-layer data of either kind.
  layer.getBlock("SoLd").isSome or layer.getBlock("PlLd").isSome

proc tyShHeader*(data: string): tuple[version: int,
    transform: array[6, float64], textVersion: int, descriptorVersion: int,
    body: Span] =
  tyShHeader(toSpan(data))

proc parseTextEngine*(data: string): TextEngine =
  parseTextEngine(toSpan(data))

proc parseFillContent*(data: string): FillContent =
  parseFillContent(toSpan(data))

proc parsePlacedLayer*(data: string, limits = defaultLimits()): PlacedLayer =
  parsePlacedLayer(toSpan(data), limits)
