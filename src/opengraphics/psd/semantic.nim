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
  TextRun* = object
    ## One style run: `length` chars in `text`/`engineText` rendered alike.
    length*: int
    fontIndex*: int ## into `fontNames`, -1 when unknown
    fontSize*: float64
    tracking*: int
    leading*: float64
    hasLeading*: bool

  ParagraphRun* = object
    length*: int
    justification*: int ## 0 left, 1 right, 2 center, 3 justify, ...

  TextEngine* = object
    ## A decoded `TySh` type-tool block.
    raw*: Span   ## the block payload, verbatim, as a window into the file
    version*: int
    transform*: array[6, float64] ## xx, xy, yx, yy, tx, ty
    textVersion*: int
    text*: string ## the descriptor's `Txt  ` field
    engineText*: string ## `/Editor /Text` from the EngineData markup
    engineData*: string ## full EngineData markup, for runs/paragraphs
    fontNames*: seq[string]
    fontSizes*: seq[float64]
    runLengths*: seq[int] ## `/RunLengthArray`, parallel to text
    runs*: seq[TextRun]
    paragraphs*: seq[ParagraphRun]
    warpStyle*: string ## warp `warpStyle` enum value, "" when unwarped
    hasWarp*: bool
    bounds*: array[4, float32] ## trailing left,top,right,bottom text-space bounds
    hasBounds*: bool
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
    gradAngle*: float64
    gradScale*: float64
    gradStyle*: string
    gradReverse*: bool
    gradDither*: bool
    gradAlign*: bool
    gradOffsetX*, gradOffsetY*: float64
    gradStops*: seq[tuple[pos: float64, r, g, b: float64]]
    gradOpacity*: seq[tuple[pos, opacity: float64]]
    patName*, patId*: string
    patScale*: float64
    patAngle*: float64
    patLink*: bool
    patPhaseX*, patPhaseY*: float64

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

proc extractInts*(engineData, key: string): seq[int] =
  ## Ints inside `/Key [ a b c ]`, e.g. `/RunLengthArray [ 8 7 5 ]`.
  result = @[]
  let at = engineData.find(key)
  if at < 0: return
  let open = engineData.find('[', at)
  if open < 0 or open > at + key.len + 4: return
  let close = engineData.find(']', open)
  if close < 0: return
  for tok in engineData[open + 1 ..< close].splitWhitespace():
    try: result.add(parseInt(tok))
    except ValueError: discard

proc extractRunLengths*(engineData: string): seq[int] =
  extractInts(engineData, "/RunLengthArray")

proc extractJustifications*(engineData: string): seq[int] =
  ## Every `/Justification <int>` in paragraph style sheets.
  result = @[]
  var i = 0
  const key = "/Justification "
  while true:
    let idx = engineData.find(key, i)
    if idx < 0: break
    var j = idx + key.len
    var num = ""
    while j < engineData.len and engineData[j] in {'0'..'9', '-'}:
      num.add(engineData[j])
      inc j
    try: result.add(parseInt(num))
    except ValueError: discard
    i = j

proc extractTrackings*(engineData: string): seq[int] =
  result = @[]
  var i = 0
  const key = "/Tracking "
  while true:
    let idx = engineData.find(key, i)
    if idx < 0: break
    var j = idx + key.len
    var num = ""
    while j < engineData.len and engineData[j] in {'0'..'9', '-'}:
      num.add(engineData[j])
      inc j
    try: result.add(parseInt(num))
    except ValueError: discard
    i = j

proc extractLeadings*(engineData: string): seq[float64] =
  result = @[]
  var i = 0
  const key = "/Leading "
  while true:
    let idx = engineData.find(key, i)
    if idx < 0: break
    var j = idx + key.len
    var num = ""
    while j < engineData.len and engineData[j] in {'0'..'9', '.', '-', '+',
        'e', 'E'}:
      num.add(engineData[j])
      inc j
    try: result.add(parseFloat(num))
    except ValueError: discard
    i = j

proc extractFontIndices*(engineData: string): seq[int] =
  ## Every `/Font <int>` (style-run font reference into `/FontSet`).
  result = @[]
  var i = 0
  while true:
    let idx = engineData.find("/Font ", i)
    if idx < 0: break
    # `/FontSet` and `/FontSize` share the prefix; only a bare `/Font ` counts.
    let after = idx + "/Font ".len
    if after < engineData.len and engineData[after] in {'0'..'9'}:
      var j = after
      var num = ""
      while j < engineData.len and engineData[j] in {'0'..'9'}:
        num.add(engineData[j])
        inc j
      try: result.add(parseInt(num))
      except ValueError: discard
      i = j
    else:
      i = idx + 6

proc buildRuns*(engineData: string): tuple[lengths: seq[int], runs: seq[TextRun],
    paragraphs: seq[ParagraphRun]] =
  let lengths = extractRunLengths(engineData)
  let sizes = extractFontSizes(engineData)
  let fonts = extractFontIndices(engineData)
  let tracks = extractTrackings(engineData)
  let leads = extractLeadings(engineData)
  let justs = extractJustifications(engineData)
  var runs: seq[TextRun] = @[]
  for i, ln in lengths:
    runs.add(TextRun(length: ln,
      fontIndex: if i < fonts.len: fonts[i] else: -1,
      fontSize: if i < sizes.len: sizes[i] else: 0.0,
      tracking: if i < tracks.len: tracks[i] else: 0,
      leading: if i < leads.len: leads[i] else: 0.0,
      hasLeading: i < leads.len))
  var paras: seq[ParagraphRun] = @[]
  for i, ln in lengths:
    paras.add(ParagraphRun(length: ln,
      justification: if i < justs.len: justs[i] else: 0))
  (lengths, runs, paras)

proc parseTextEngine*(data: Span): TextEngine =
  ## Parse a `TySh` payload. Raises `PsdError` on a short or unsupported
  ## header; a block whose descriptor we cannot model yields `hasText`
  ## false rather than raising. Trailing warp + bounds are parsed when
  ## present: a versioned warp descriptor, then four big-endian f32
  ## (left, top, right, bottom) in text space.
  let head = tyShHeader(data)
  result.version = head.version
  result.transform = head.transform
  result.textVersion = head.textVersion
  result.raw = data
  try:
    let tp = parseDescriptorPrefix(head.body)
    let d = tp.descriptor
    let engine = parseEngineData(d)
    result.engineData = engine
    result.engineText = extractEditorText(engine)
    result.fontNames = extractFontNames(engine)
    result.fontSizes = extractFontSizes(engine)
    let built = buildRuns(engine)
    result.runLengths = built.lengths
    result.runs = built.runs
    result.paragraphs = built.paragraphs
    result.text = d.getText("Txt ")
    var rest = head.body.slice(tp.consumed, head.body.len)
    # Warp: versioned descriptor when present, else raw.
    if rest.len >= 4:
      try:
        let wv = parseVersionedDescriptor(rest)
        result.hasWarp = true
        let ws = wv.descriptor.get("warpStyle")
        if ws.isSome and ws.get().kind == vEnumerated:
          result.warpStyle = ws.get().valueId.asString()
        # consume warp descriptor bytes: version + body
        let wbytes = wv.toBytes().len
        if rest.len >= wbytes:
          rest = rest.slice(wbytes, rest.len)
        else:
          rest = rest.slice(rest.len, rest.len)
      except PsdError:
        discard
    if rest.len >= 16:
      try:
        var r = initReader(rest.slice(rest.len - 16, rest.len))
        result.bounds = [r.readF32BE(), r.readF32BE(), r.readF32BE(),
          r.readF32BE()]
        result.hasBounds = true
      except PsdError:
        discard
  except PsdError:
    discard
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
  ## A `vscg` payload: a 4-byte content key then a versioned descriptor.
  ## `SoCo` carries `Clr ` (RGBC); `GrFl` carries gradient settings with
  ## `Grad`; `PtFl` carries a `Ptrn` pattern reference. Unknown keys keep
  ## `key` with raw only.
  if data.len < 4:
    invalid("short fill content (" & $data.len & " bytes)")
  result.raw = data
  result.key = data.head(4).clone
  result.gradAlign = true
  result.patLink = true
  result.patScale = 1.0
  result.gradScale = 1.0
  let vd = tryBlockDescriptor(TaggedBlock(signature: "", key: "",
    data: data, padding: none(Span)))
  if vd.isNone:
    return
  result.version = int(vd.get().version)
  let d = vd.get().descriptor
  if result.key == "SoCo":
    let clr = d.getDescriptor("Clr ")
    if clr.isNone: return
    let rgb = clr.get()
    if rgb.classId.asString() != "RGBC": return
    if rgb.items.len != 3: return
    result.solid = some(SolidFill(raw: data, red: rgb.getDouble("Rd  "),
      green: rgb.getDouble("Grn "), blue: rgb.getDouble("Bl  ")))
  elif result.key == "GrFl":
    result.gradAngle = d.get("Angl").map(proc(v: Value): float64 =
      if v.kind == vUnitFloat: v.floatUnitValue else: 90.0).get(90.0)
    let sc = d.get("Scl ")
    if sc.isSome and sc.get().kind == vUnitFloat:
      result.gradScale = sc.get().floatUnitValue / 100.0
    let ty = d.get("Type")
    if ty.isSome and ty.get().kind == vEnumerated:
      result.gradStyle = ty.get().valueId.asString()
    result.gradReverse = d.getBool("Rvrs", false)
    result.gradDither = d.getBool("Dthr", false)
    result.gradAlign = d.getBool("Algn", true)
    let ofs = d.getDescriptor("Ofst")
    if ofs.isSome:
      let o = ofs.get()
      let hx = o.get("Hrzn")
      let vy = o.get("Vrtc")
      if hx.isSome and hx.get().kind == vUnitFloat:
        result.gradOffsetX = hx.get().floatUnitValue / 100.0
      if vy.isSome and vy.get().kind == vUnitFloat:
        result.gradOffsetY = vy.get().floatUnitValue / 100.0
    let grad = d.getDescriptor("Grad")
    if grad.isSome:
      let g = grad.get()
      for it in g.items:
        if it.value.kind == vList:
          for sv in it.value.items:
            if sv.kind != vDescriptor and sv.kind != vGlobalObject: continue
            let sd = if sv.kind == vDescriptor: sv.descriptor else: sv.globalObject
            let loc = sd.get("Lctn")
            if loc.isNone or loc.get().kind != vInteger: continue
            let pos = float64(loc.get().integer) / 4096.0
            let clr = sd.getDescriptor("Clr ")
            if clr.isSome:
              let c = clr.get()
              # RGBC doubles 0..255; other classes skipped.
              if c.classId.asString() == "RGBC":
                result.gradStops.add((pos, c.getDouble("Rd  "),
                  c.getDouble("Grn "), c.getDouble("Bl  ")))
              continue
            let op = sd.get("Opct")
            if op.isSome and op.get().kind == vUnitFloat:
              result.gradOpacity.add((pos, op.get().floatUnitValue / 100.0))
  elif result.key == "PtFl":
    let ptrn = d.getDescriptor("Ptrn")
    if ptrn.isSome:
      let p = ptrn.get()
      result.patName = p.getText("Nm  ")
      result.patId = p.getText("Idnt")
    let sc = d.get("Scl ")
    if sc.isSome:
      case sc.get().kind
      of vUnitFloat: result.patScale = sc.get().floatUnitValue / 100.0
      of vDouble: result.patScale = sc.get().double / 100.0
      of vInteger: result.patScale = float64(sc.get().integer) / 100.0
      else: discard
    let an = d.get("Angl")
    if an.isSome and an.get().kind == vUnitFloat:
      result.patAngle = an.get().floatUnitValue
    result.patLink = d.getBool("Algn", true)
    let ph = d.getDescriptor("phase")
    if ph.isSome:
      let p = ph.get()
      let hx = p.get("Hrzn")
      let vy = p.get("Vrtc")
      if hx.isSome and hx.get().kind == vDouble:
        result.patPhaseX = hx.get().double
      if vy.isSome and vy.get().kind == vDouble:
        result.patPhaseY = vy.get().double

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
  if sig != "soLD" and sig != "soLE":
    invalid("not a placed-layer block (sig '" & sig & "')")
  var r = initReader(data)
  discard r.readStr4()
  result.raw = data
  result.kind = if sig == "soLE": "SoLE" else: "SoLd"
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
  ## `SoLd`/`SoLE` when present, else `PlLd`, else `none`.
  for key in ["SoLd", "SoLE", "PlLd"]:
    let b = layer.getBlock(key)
    if b.isSome:
      return some(parsePlacedLayer(b.get().data, limits))
  none(PlacedLayer)

proc isSmartObject*(layer: LayerRecord): bool {.inline.} =
  ## True when the layer carries placed-layer data of any kind.
  layer.getBlock("SoLd").isSome or layer.getBlock("SoLE").isSome or
    layer.getBlock("PlLd").isSome

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
