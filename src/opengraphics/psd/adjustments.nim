## Adjustment layers: typed read-only views over the 16 adjustment keys.
##
## An adjustment layer is a normal layer record carrying one of the keys in
## `AdjustmentKeys` (`levl`, `curv`, `hue2`, ...) instead of pixels. The binary
## layouts below follow Adobe's spec section "Adjustment layer", as
## reimplemented in `references/photocraft/crates/io/src/adjust_map.rs`
## (clean-room: layouts only, no copied code).
##
## Every parser here keeps the block's own bytes. `Adjustment.kind == akUnsupported`
## means the bytes are preserved but not interpreted (unknown version, noise
## gradient, profile lookup, extended `brit` Light block, ...). Nothing here
## rewrites a file; it only reads.

import std/math
import std/options

import ./descriptor
import ./error
import ./header
import ./io
import ./layers

type
  Channels* {.pure.} = enum
    ## Per-channel record interpretation, from the document mode.
    chRgb, chGray, chCmyk, chLab, chOther

  LevelsChannel* = object
    inBlack*, inWhite*, outBlack*, outWhite*: float32 ## 0..1
    gamma*: float32

  CurvePoint* = object
    input*, output*: float32 ## 0..1

  HueRange* = object
    hue*, saturation*, lightness*: float32
    bounds*: array[4, float32] ## canonical degrees

  AdjustmentKind* {.pure.} = enum
    akLevels, akCurves, akHueSaturation, akBrightnessContrast,
    akInvert, akThreshold, akPosterize, akExposure,
    akVibrance, akColorBalance, akChannelMixer, akGradientMap,
    akPhotoFilter, akSelectiveColor, akBlackWhite, akColorLookup,
    akUnsupported

  Adjustment* = object
    raw*: Span
    key*: string ## 4-byte block key, e.g. "levl"
    case kind*: AdjustmentKind
    of akLevels:
      levelsMaster*: LevelsChannel
      levelsChannels*: array[3, LevelsChannel]
      levelsBlack*: LevelsChannel
    of akCurves:
      curvesMaster*: seq[CurvePoint]
      curvesChannels*: array[3, seq[CurvePoint]]
      curvesBlack*: seq[CurvePoint]
      curvesPencil*: bool
    of akHueSaturation:
      hue*, saturation*, lightness*: float32
      hueColorize*: bool
      hueRanges*: array[6, HueRange]
    of akBrightnessContrast:
      brightness*, contrast*: float32
      bcLegacy*: bool
    of akInvert:
      discard
    of akThreshold:
      threshold*: float32 ## 0..1
    of akPosterize:
      posterizeLevels*: uint32
    of akExposure:
      exposure*, offset*, gamma*: float32
    of akVibrance:
      vibrance*, satBoost*: float32
    of akColorBalance:
      cbShadows*, cbMidtones*, cbHighlights*: array[3, float32]
      cbPreserve*: bool
    of akChannelMixer:
      mixerMatrix*: array[3, array[4, float32]]
      mixerMono*: bool
    of akGradientMap:
      gradStops*: seq[tuple[pos: float32, rgb: array[3, float32]]]
      gradReverse*, gradDither*: bool
    of akPhotoFilter:
      pfColor*: array[3, float32]
      pfDensity*: float32
      pfPreserve*: bool
    of akSelectiveColor:
      selRelative*: bool
      selAdjust*: array[9, array[4, float32]]
    of akBlackWhite:
      bwWeights*: array[6, float32]
      bwTint*: Option[array[3, float32]]
    of akColorLookup:
      clName*: string
      clSize*: int
      clDither*: bool
    of akUnsupported:
      unsupportedReason*: string

const
  AdjustmentKeys* = ["levl", "curv", "hue2", "brit", "nvrt", "thrs",
    "post", "expA", "vibA", "blnc", "mixr", "grdm", "phfl", "selc",
    "blwh", "clrL"]

proc channelsFor*(m: ColorMode): Channels =
  case m.kind
  of cmRgb: chRgb
  of cmGrayscale, cmBitmap, cmDuotone: chGray
  of cmCmyk: chCmyk
  of cmLab: chLab
  else: chOther

proc isAdjustmentKey*(key: string): bool {.inline.} =
  key in AdjustmentKeys

proc defaultLevelsChannel*(): LevelsChannel =
  LevelsChannel(inBlack: 0, inWhite: 1, outBlack: 0, outWhite: 1, gamma: 1)

proc lineCurve*(): seq[CurvePoint] =
  @[CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]

proc be16(data: Span, at: int): Option[uint16] =
  if at < 0 or at + 2 > data.len: return none(uint16)
  var r = initReader(data.slice(at, at + 2))
  try: some(r.readU16BE())
  except PsdError: none(uint16)

proc bei16(data: Span, at: int): Option[int16] =
  let v = be16(data, at)
  if v.isNone: none(int16) else: some(cast[int16](v.get()))

proc be32(data: Span, at: int): Option[uint32] =
  if at < 0 or at + 4 > data.len: return none(uint32)
  var r = initReader(data.slice(at, at + 4))
  try: some(r.readU32BE())
  except PsdError: none(uint32)

proc bef32(data: Span, at: int): Option[float32] =
  if at < 0 or at + 4 > data.len: return none(float32)
  var r = initReader(data.slice(at, at + 4))
  try: some(r.readF32BE())
  except PsdError: none(float32)

proc unsupported*(key: string, data: Span, reason = ""): Adjustment =
  Adjustment(raw: data, key: key, kind: akUnsupported,
    unsupportedReason: reason)

proc levelsRec(data: Span, at: int): Option[LevelsChannel] =
  let a = be16(data, at)
  let b = be16(data, at + 2)
  let c = be16(data, at + 4)
  let d = be16(data, at + 6)
  let g = be16(data, at + 8)
  if a.isNone or b.isNone or c.isNone or d.isNone or g.isNone:
    return none(LevelsChannel)
  some(LevelsChannel(
    inBlack: float32(a.get()) / 255.0f32,
    inWhite: float32(b.get()) / 255.0f32,
    outBlack: float32(c.get()) / 255.0f32,
    outWhite: float32(d.get()) / 255.0f32,
    gamma: float32(g.get()) / 100.0))

proc parseCurves(data: Span): Option[tuple[master: seq[CurvePoint],
    ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool]] =
  if data.len < 7: return none(tuple[master: seq[CurvePoint],
    ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
  var r = initReader(data)
  let pencil = try: r.readU8() != 0 except PsdError: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
  let version = try: r.readU16BE() except PsdError: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
  if version != 1 and version != 4: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
  let bits = try: r.readU32BE() except PsdError: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
  var curves: array[5, seq[CurvePoint]] = [lineCurve(), lineCurve(),
    lineCurve(), lineCurve(), lineCurve()]
  for bit in 0 ..< 32:
    if (bits and (1'u32 shl bit)) == 0: continue
    if bit >= 5: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
    if pencil:
      if r.remaining() < 256: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
      let m = r.bytes(256)
      var pts: seq[CurvePoint] = @[]
      # Compress the 256-entry map to line segments: keep turning points.
      var prev = -1.0f32
      for i in 0 ..< 256:
        let v = float32(m.byteAt(i)) / 255.0
        if i == 0 or i == 255 or abs(v - prev) > 1.0 / 255.0 + 1e-6:
          pts.add(CurvePoint(input: float32(i) / 255.0f32, output: v))
          prev = v
      curves[bit] = pts
    else:
      if r.remaining() < 2: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
      let n = try: int(r.readU16BE()) except PsdError: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
      if n > 64 or r.remaining() < n * 4: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
      var pts: seq[CurvePoint] = @[]
      for _ in 0 ..< n:
        let o = try: r.readU16BE() except PsdError: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
        let i = try: r.readU16BE() except PsdError: return none(tuple[master: seq[CurvePoint], ch: array[3, seq[CurvePoint]], black: seq[CurvePoint], pencil: bool])
        pts.add(CurvePoint(input: float32(i) / 255.0f32, output: float32(o) / 255.0f32))
      curves[bit] = pts
  some((curves[0], [curves[1], curves[2], curves[3]], curves[4], pencil))

proc descNum(d: Descriptor, key: string): Option[float32] =
  let v = d.get(key)
  if v.isNone: return none(float32)
  case v.get().kind
  of vInteger: some(float32(v.get().integer))
  of vDouble: some(float32(v.get().double))
  of vUnitFloat: some(float32(v.get().floatUnitValue))
  else: none(float32)

proc descBool(d: Descriptor, key: string): Option[bool] =
  let v = d.get(key)
  if v.isNone or v.get().kind != vBoolean: none(bool)
  else: some(v.get().boolean)

proc versionedDesc(data: Span): Option[Descriptor] =
  try:
    let vd = parseVersionedDescriptor(data)
    some(vd.descriptor)
  except PsdError:
    none(Descriptor)

proc parseVibrance(data: Span): Option[tuple[v, s: float32]] =
  let d = versionedDesc(data)
  if d.isNone: return none(tuple[v, s: float32])
  let dd = d.get()
  let gv = descNum(dd, "vibrance")
  let gs = descNum(dd, "Strt")
  some((gv.get(0.0).clamp(-100.0f32, 100.0f32), gs.get(0.0).clamp(-100.0f32, 100.0f32)))

proc parseBlackWhite(data: Span): Option[tuple[w: array[6, float32],
    tint: Option[array[3, float32]]]] =
  let d = versionedDesc(data)
  if d.isNone: return none(tuple[w: array[6, float32], tint: Option[array[3, float32]]])
  const keys = ["Rd  ", "Yllw", "Grn ", "Cyn ", "Bl  ", "Mgnt"]
  const defaults = [40.0f32, 60.0f32, 40.0f32, 60.0f32, 20.0f32, 80.0f32]
  var w = defaults
  for i, k in keys:
    let v = descNum(d.get(), k)
    if v.isSome: w[i] = v.get().clamp(-200.0f32, 300.0f32)
  let useTint = descBool(d.get(), "useTint").get(false)
  var tint: Option[array[3, float32]] = none(array[3, float32])
  if useTint:
    let td = d.get().getDescriptor("tintColor")
    if td.isSome:
      let t = td.get()
      # RGBC doubles 0..255, else fall back to default warm tint.
      let r = t.getDouble("Rd  ", -1.0)
      if r >= 0:
        tint = some([float32(t.getDouble("Rd  ") / 255.0f32),
          float32(t.getDouble("Grn ") / 255.0f32),
          float32(t.getDouble("Bl  ") / 255.0f32)])
      else:
        tint = some([225.0f32 / 255.0f32, 211.0f32 / 255.0f32, 179.0f32 / 255.0f32])
    else:
      tint = some([225.0f32 / 255.0f32, 211.0f32 / 255.0f32, 179.0f32 / 255.0f32])
  some((w, tint))

proc parseColorBalance(data: Span): Option[tuple[s, m, h: array[3, float32], p: bool]] =
  if data.len < 19: return none(tuple[s, m, h: array[3, float32], p: bool])
  var tone: array[3, array[3, float32]]
  for k in 0 ..< 3:
    for i in 0 ..< 3:
      let v = bei16(data, (k * 3 + i) * 2)
      if v.isNone: return none(tuple[s, m, h: array[3, float32], p: bool])
      tone[k][i] = float32(v.get()).clamp(-100.0f32, 100.0f32)
  var r = initReader(data.slice(18, data.len))
  let p = try: r.readU8() != 0 except PsdError: return none(tuple[s, m, h: array[3, float32], p: bool])
  some((tone[0], tone[1], tone[2], p))

proc parseSelective(data: Span): Option[tuple[rel: bool,
    adj: array[9, array[4, float32]]]] =
  if data.len < 84: return none(tuple[rel: bool, adj: array[9, array[4, float32]]])
  let v = be16(data, 0)
  if v.isNone or v.get() != 1: return none(tuple[rel: bool, adj: array[9, array[4, float32]]])
  let m = be16(data, 2)
  if m.isNone: return none(tuple[rel: bool, adj: array[9, array[4, float32]]])
  var adj: array[9, array[4, float32]]
  for rr in 0 ..< 9:
    for k in 0 ..< 4:
      let x = bei16(data, 4 + (rr + 1) * 8 + k * 2)
      if x.isNone: return none(tuple[rel: bool, adj: array[9, array[4, float32]]])
      adj[rr][k] = float32(x.get())
  some((m.get() == 0, adj))

proc parsePhotoFilter(data: Span): Option[tuple[c: array[3, float32],
    d: float32, p: bool]] =
  let ver = be16(data, 0)
  if ver.isNone: return none(tuple[c: array[3, float32], d: float32, p: bool])
  var color = [0.0f32, 0, 0]
  var at = 0
  if ver.get() == 2:
    if data.len < 17: return none(tuple[c: array[3, float32], d: float32, p: bool])
    let space = be16(data, 2)
    if space.isNone: return none(tuple[c: array[3, float32], d: float32, p: bool])
    # Only RGB (0) is decoded here; other spaces keep the block unsupported
    # rather than guessing a conversion.
    if space.get() != 0:
      return none(tuple[c: array[3, float32], d: float32, p: bool])
    for i in 0 ..< 3:
      let c = be16(data, 4 + i * 2)
      if c.isNone: return none(tuple[c: array[3, float32], d: float32, p: bool])
      color[i] = float32(c.get()) / 65535.0f32
    at = 12
  elif ver.get() == 3:
    if data.len < 19: return none(tuple[c: array[3, float32], d: float32, p: bool])
    # XYZ relative to D50 white, 1.0 = 32768 (inferred from Photoshop presets).
    const D50 = [0.9642f32, 1.0f32, 0.8249f32]
    var rel: array[3, float32]
    for i in 0 ..< 3:
      let x = be32(data, 2 + i * 4)
      if x.isNone: return none(tuple[c: array[3, float32], d: float32, p: bool])
      rel[i] = float32(x.get()) / 32768.0f32
      if rel[i] > 2.0f32: return none(tuple[c: array[3, float32], d: float32, p: bool])
    let xyz = [rel[0] * D50[0], rel[1], rel[2] * D50[2]]
    # XYZ D50 -> linear sRGB, then gamma.
    const M = [[3.1338561f32, -1.6168667f32, -0.4906146f32],
      [-0.9787684f32, 1.9161415f32, 0.0334540f32],
      [0.0719453f32, -0.2289914f32, 1.4052427f32]]
    var lin: array[3, float32]
    for i in 0 ..< 3:
      lin[i] = (M[i][0] * xyz[0] + M[i][1] * xyz[1] + M[i][2] * xyz[2]).clamp(0.0f32, 1.0f32)
    for i in 0 ..< 3:
      let v = lin[i]
      color[i] = if v <= 0.0031308f32: 12.92f32 * v
        else: 1.055f32 * pow(v, 1.0f32 / 2.4f32) - 0.055f32
    at = 14
  else:
    return none(tuple[c: array[3, float32], d: float32, p: bool])
  let den = be32(data, at)
  if den.isNone: return none(tuple[c: array[3, float32], d: float32, p: bool])
  if at + 5 > data.len: return none(tuple[c: array[3, float32], d: float32, p: bool])
  var r = initReader(data.slice(at + 4, data.len))
  let p = try: r.readU8() != 0 except PsdError: return none(tuple[c: array[3,float32], d: float32, p: bool])
  some((color, (float32(den.get()) / 100.0f32).clamp(0.0f32, 1.0f32), p))

proc parseChannelMixer(data: Span): Option[tuple[m: array[3, array[4, float32]], mono: bool]] =
  if data.len < 4: return none(tuple[m: array[3, array[4, float32]], mono: bool])
  let ver = be16(data, 0)
  let mon = be16(data, 2)
  if ver.isNone or mon.isNone or ver.get() != 1:
    return none(tuple[m: array[3, array[4, float32]], mono: bool])
  var m: array[3, array[4, float32]]
  for rr in 0 ..< 3:
    if 4 + rr * 10 + 10 > data.len:
      if mon.get() != 0 and rr > 0:
        m[rr] = [0.0f32, 0, 0, 0]
        continue
      return none(tuple[m: array[3, array[4, float32]], mono: bool])
    for k in 0 ..< 4:
      let idx = if k < 3: k else: 4 # constant lives at slot 4, black at 3 skipped in RGB
      let v = bei16(data, 4 + rr * 10 + idx * 2)
      if v.isNone: return none(tuple[m: array[3, array[4, float32]], mono: bool])
      m[rr][k] = (float32(v.get()).clamp(-200.0f32, 200.0f32)) / 100.0f32
  some((m, mon.get() != 0))

proc decodeKnownColor(space: uint16, c: array[4, uint16]): Option[array[3, float32]] =
  ## Minimal color decode for gradient stops: RGB (0) and gray. Others return
  ## none so the gradient stays unsupported rather than wrong.
  case space
  of 0: # RGB
    some([float32(c[0]) / 65535.0f32, float32(c[1]) / 65535.0f32,
      float32(c[2]) / 65535.0f32])
  of 1: # HSB - convert via simple HSV->RGB
    let h = float32(c[0]) / 65535.0f32 * 360.0f32
    let s = float32(c[1]) / 65535.0f32
    let b = float32(c[2]) / 65535.0f32
    let hh = (h mod 360.0f32) / 60.0f32
    let i = int(hh) mod 6
    let f = hh - float32(int(hh))
    let p = b * (1.0f32 - s)
    let q = b * (1.0f32 - s * f)
    let t = b * (1.0f32 - s * (1.0f32 - f))
    case i
    of 0: some([b, t, p])
    of 1: some([q, b, p])
    of 2: some([p, b, t])
    of 3: some([p, q, b])
    of 4: some([t, p, b])
    else: some([b, p, q])
  of 2: # CMYK naive preview: invert and take min
    let cc = float32(c[0]) / 65535.0f32
    let mm = float32(c[1]) / 65535.0f32
    let yy = float32(c[2]) / 65535.0f32
    let kk = float32(c[3]) / 65535.0f32
    some([(1.0f32 - min(1.0f32, cc + kk)).clamp(0.0f32, 1.0f32),
      (1.0f32 - min(1.0f32, mm + kk)).clamp(0.0f32, 1.0f32),
      (1.0f32 - min(1.0f32, yy + kk)).clamp(0.0f32, 1.0f32)])
  else: none(array[3, float32])

proc parseGradientMap(data: Span): Option[tuple[stops: seq[tuple[pos: float32,
    rgb: array[3, float32]]], rev, dith: bool]] =
  let ver = be16(data, 0)
  if ver.isNone: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
  var at = 0
  if ver.get() == 1: at = 4
  elif ver.get() == 3: at = 8
  else: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
  if data.len < 3: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
  var r0 = initReader(data.slice(2, 4))
  let rev = try: r0.readU8() != 0 except PsdError: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
  let dith = try: r0.readU8() != 0 except PsdError: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
  # name: u32 count of UTF-16 units
  let nameCount = be32(data, at)
  if nameCount.isNone: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
  let nc = int(nameCount.get())
  if nc < 0 or nc > 1_000_000: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
  at += 4 + nc * 2
  let n = be16(data, at)
  if n.isNone: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
  at += 2
  let count = int(n.get())
  if count < 2 or count > 1000: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
  var stops: seq[tuple[pos: float32, rgb: array[3, float32]]] = @[]
  for _ in 0 ..< count:
    let loc = be32(data, at)
    let space = be16(data, at + 8)
    if loc.isNone or space.isNone: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
    var comps: array[4, uint16]
    for k in 0 ..< 4:
      let c = be16(data, at + 10 + k * 2)
      if c.isNone: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
      comps[k] = c.get()
    let rgb = decodeKnownColor(space.get(), comps)
    if rgb.isNone: return none(tuple[stops: seq[tuple[pos: float32, rgb: array[3, float32]]], rev, dith: bool])
    stops.add((pos: float32(loc.get()) / 4096.0f32, rgb: rgb.get()))
    at += 20
  some((stops, rev, dith))

proc isExtendedBrit(cged: Option[Span]): bool =
  ## True when CgEd carries keys beyond brightness/contrast (Photoshop Light).
  if cged.isNone: return false
  try:
    let vd = parseVersionedDescriptor(cged.get())
    const known = ["Vrsn", "Brgh", "Cntr", "means", "Lab ", "useLegacy",
      "Auto", "presetKind", "presetFileName"]
    for item in vd.descriptor.items:
      var found = false
      for n in known:
        if item.key.asString() == n: found = true
      if not found: return true
    false
  except PsdError:
    false

proc parseAdjustment*(key: string, data: Span, cged: Option[Span] = none(Span),
    channels: Channels = chRgb): Adjustment =
  ## Parse one adjustment block. Unknown keys and malformed payloads become
  ## `akUnsupported` with the raw bytes kept.
  case key
  of "nvrt":
    Adjustment(raw: data, key: key, kind: akInvert)
  of "thrs":
    let v = be16(data, 0)
    if v.isNone: return unsupported(key, data, "truncated thrs")
    Adjustment(raw: data, key: key, kind: akThreshold,
      threshold: float32(v.get()) / 255.0f32)
  of "post":
    let v = be16(data, 0)
    if v.isNone: return unsupported(key, data, "truncated post")
    Adjustment(raw: data, key: key, kind: akPosterize,
      posterizeLevels: uint32(v.get()))
  of "brit":
    if isExtendedBrit(cged):
      return unsupported(key, data, "extended brit (Light) unsupported")
    if cged.isSome:
      try:
        let vd = parseVersionedDescriptor(cged.get())
        let b = descNum(vd.descriptor, "Brgh")
        let c = descNum(vd.descriptor, "Cntr")
        let leg = descBool(vd.descriptor, "useLegacy").get(false)
        if b.isSome or c.isSome:
          return Adjustment(raw: data, key: key, kind: akBrightnessContrast,
            brightness: b.get(0.0), contrast: c.get(0.0), bcLegacy: leg)
      except PsdError:
        discard
    let b = bei16(data, 0)
    let c = bei16(data, 2)
    if b.isNone or c.isNone: return unsupported(key, data, "truncated brit")
    Adjustment(raw: data, key: key, kind: akBrightnessContrast,
      brightness: float32(b.get()), contrast: float32(c.get()), bcLegacy: true)
  of "hue2":
    if data.len < 12: return unsupported(key, data, "truncated hue2")
    var r = initReader(data)
    try:
      discard r.readU16BE() # version
      let colorize = r.readU8() != 0
      discard r.readU8()
      let baseHue = float32(r.readI16BE())
      let baseSat = float32(r.readI16BE())
      let baseLig = float32(r.readI16BE())
      # six ranges at byte 16
      var ranges: array[6, HueRange]
      if data.len >= 16 + 6 * 14:
        for i in 0 ..< 6:
          let at = 16 + i * 14
          let a = bei16(data, at)
          let b = bei16(data, at + 2)
          let c = bei16(data, at + 4)
          let d = bei16(data, at + 6)
          let h = bei16(data, at + 8)
          let s = bei16(data, at + 10)
          let l = bei16(data, at + 12)
          if a.isSome and b.isSome and c.isSome and d.isSome and
              h.isSome and s.isSome and l.isSome:
            ranges[i] = HueRange(hue: float32(h.get()), saturation: float32(s.get()),
              lightness: float32(l.get()),
              bounds: [float32(a.get()), float32(b.get()), float32(c.get()), float32(d.get())])
      let hue = if colorize: baseHue - float32(int(baseHue / 360.0) * 360) mod 360.0 else: baseHue
      Adjustment(raw: data, key: key, kind: akHueSaturation,
        hue: hue, saturation: baseSat, lightness: baseLig,
        hueColorize: colorize, hueRanges: ranges)
    except PsdError:
      unsupported(key, data, "truncated hue2")
  of "expA":
    let e = bef32(data, 2)
    let o = bef32(data, 6)
    let g = bef32(data, 10)
    if e.isNone or o.isNone or g.isNone:
      return unsupported(key, data, "truncated expA")
    Adjustment(raw: data, key: key, kind: akExposure,
      exposure: e.get(), offset: o.get(), gamma: g.get())
  of "levl":
    let m = levelsRec(data, 2)
    let rr = levelsRec(data, 12)
    let g = levelsRec(data, 22)
    let b = levelsRec(data, 32)
    if m.isNone or rr.isNone or g.isNone or b.isNone:
      return unsupported(key, data, "truncated levl")
    var k = levelsRec(data, 42)
    if k.isNone: k = some(defaultLevelsChannel())
    Adjustment(raw: data, key: key, kind: akLevels,
      levelsMaster: m.get(), levelsChannels: [rr.get(), g.get(), b.get()],
      levelsBlack: k.get())
  of "curv":
    let c = parseCurves(data)
    if c.isNone: return unsupported(key, data, "unreadable curv")
    Adjustment(raw: data, key: key, kind: akCurves,
      curvesMaster: c.get().master, curvesChannels: c.get().ch,
      curvesBlack: c.get().black, curvesPencil: c.get().pencil)
  of "selc":
    let s = parseSelective(data)
    if s.isNone: return unsupported(key, data, "unreadable selc")
    Adjustment(raw: data, key: key, kind: akSelectiveColor,
      selRelative: s.get().rel, selAdjust: s.get().adj)
  of "vibA":
    let v = parseVibrance(data)
    if v.isNone: return unsupported(key, data, "unreadable vibA")
    Adjustment(raw: data, key: key, kind: akVibrance,
      vibrance: v.get().v, satBoost: v.get().s)
  of "blnc":
    let v = parseColorBalance(data)
    if v.isNone: return unsupported(key, data, "truncated blnc")
    Adjustment(raw: data, key: key, kind: akColorBalance,
      cbShadows: v.get().s, cbMidtones: v.get().m, cbHighlights: v.get().h,
      cbPreserve: v.get().p)
  of "blwh":
    let v = parseBlackWhite(data)
    if v.isNone: return unsupported(key, data, "unreadable blwh")
    Adjustment(raw: data, key: key, kind: akBlackWhite,
      bwWeights: v.get().w, bwTint: v.get().tint)
  of "phfl":
    let v = parsePhotoFilter(data)
    if v.isNone: return unsupported(key, data, "unreadable phfl")
    Adjustment(raw: data, key: key, kind: akPhotoFilter,
      pfColor: v.get().c, pfDensity: v.get().d, pfPreserve: v.get().p)
  of "mixr":
    let v = parseChannelMixer(data)
    if v.isNone: return unsupported(key, data, "unreadable mixr")
    Adjustment(raw: data, key: key, kind: akChannelMixer,
      mixerMatrix: v.get().m, mixerMono: v.get().mono)
  of "grdm":
    let v = parseGradientMap(data)
    if v.isNone: return unsupported(key, data, "unreadable grdm")
    Adjustment(raw: data, key: key, kind: akGradientMap,
      gradStops: v.get().stops, gradReverse: v.get().rev, gradDither: v.get().dith)
  of "clrL":
    # Version 1 + versioned descriptor with LUT3DFileData. Profile lookups
    # stay unsupported with the reason kept.
    let ver = be16(data, 0)
    if ver.isNone or ver.get() != 1:
      return unsupported(key, data, "unknown clrL version")
    try:
      let vd = parseVersionedDescriptor(data.slice(2, data.len))
      let fmt = vd.descriptor.get("LUTFormat")
      var fname = vd.descriptor.getText("LUT3DFileName")
      if fname.len == 0: fname = vd.descriptor.getText("NM  ")
      let dith = descBool(vd.descriptor, "Dthr").get(false)
      let raw = vd.descriptor.get("LUT3DFileData")
      if raw.isNone or raw.get().kind != vRawData or raw.get().rawData.len == 0:
        return unsupported(key, data,
          "profile lookup without LUT file data")
      discard fmt
      Adjustment(raw: data, key: key, kind: akColorLookup,
        clName: fname, clSize: 0, clDither: dith)
    except PsdError as e:
      unsupported(key, data, "unreadable clrL: " & e.msg)
  else:
    unsupported(key, data, "unknown adjustment key")

proc adjustmentOf*(layer: LayerRecord, channels: Channels = chRgb): Option[Adjustment] =
  ## The layer's adjustment, checking all 16 keys plus `CgEd` for `brit`.
  for k in AdjustmentKeys:
    let b = layer.getBlock(k)
    if b.isSome:
      var cged: Option[Span] = none(Span)
      if k == "brit":
        let c = layer.getBlock("CgEd")
        if c.isSome: cged = some(c.get().data)
      return some(parseAdjustment(k, b.get().data, cged, channels))

proc isAdjustmentLayer*(layer: LayerRecord): bool {.inline.} =
  for k in AdjustmentKeys:
    if layer.getBlock(k).isSome: return true
  false

proc adjustmentLabel*(key: string): string =
  case key
  of "levl": "Levels"
  of "curv": "Curves"
  of "hue2": "Hue/Saturation"
  of "brit": "Brightness/Contrast"
  of "nvrt": "Invert"
  of "thrs": "Threshold"
  of "post": "Posterize"
  of "expA": "Exposure"
  of "vibA": "Vibrance"
  of "blnc": "Color Balance"
  of "mixr": "Channel Mixer"
  of "grdm": "Gradient Map"
  of "phfl": "Photo Filter"
  of "selc": "Selective Color"
  of "blwh": "Black & White"
  of "clrL": "Color Lookup"
  else: "adjustment"
