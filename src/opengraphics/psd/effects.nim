## Layer effects: typed read-only views over `lfx2` (and legacy `lrFX`).
##
## Layout follows Adobe's spec via
## `references/photocraft/crates/io/src/effects_map.rs` (clean-room: layouts
## only, no copied code). `lfx2` is a 4-byte version followed by a versioned
## descriptor whose items are the effects below. `lrFX` is the legacy flat
## form and is preserved raw.
##
## Every effect keeps its descriptor. `Effect.kind` tells what it is;
## `common` carries enabled/blend/opacity; the rest is per-kind scalars.
## Nothing here rewrites a file; it only reads.

import std/math
import std/options

import ./descriptor
import ./error
import ./io
import ./layers

type
  EffectKind* {.pure.} = enum
    ekDropShadow, ekInnerShadow, ekOuterGlow, ekInnerGlow,
    ekBevelEmboss, ekSatin, ekColorOverlay, ekGradientOverlay,
    ekPatternOverlay, ekStroke, ekUnknown

  FxCommon* = object
    enabled*: bool
    blend*: string ## effect blend key, e.g. "Mltp"; "" when absent
    opacity*: float32 ## 0..1

  Effect* = object
    raw*: Descriptor
    key*: string ## descriptor key, e.g. "DrSh"
    common*: FxCommon
    case kind*: EffectKind
    of ekDropShadow, ekInnerShadow:
      distance*, size*, blur*: float32
      angle*: float32
      useGlobalLight*: bool
      spread*: float32 ## 0..1 choke/spread (`Ckmt` percent)
      color*: array[3, float32] ## 0..255 RGB (`Clr `, black when absent)
      knocksOut*: bool ## `layerConceals`, drop shadows only
    of ekOuterGlow, ekInnerGlow:
      glowSize*, glowBlur*: float32
      glowPrecise*: bool ## GlwT PrBL; precise needs exact distances, skipped
      glowSpread*: float32 ## 0..1 (`Ckmt` percent)
      glowRange*: float32 ## 0..1 (`Inpr` percent, default 50)
      glowColor*: array[3, float32] ## 0..255 RGB (`Clr `, black when absent)
      glowGradient*: bool ## `Grad` paint present; gradient glows stay unpainted
    of ekColorOverlay:
      overlayColor*: array[3, float32] ## 0..255 RGB (`Clr `, black when absent)
    of ekBevelEmboss, ekSatin, ekGradientOverlay,
        ekPatternOverlay, ekStroke, ekUnknown:
      discard

const
  EffectKinds*: array[10, tuple[single, multi: string]] = [
    ("DrSh", "dropShadowMulti"),
    ("IrSh", "innerShadowMulti"),
    ("OrGl", ""),
    ("IrGl", ""),
    ("ebbl", ""),
    ("ChFX", ""),
    ("SoFi", "solidFillMulti"),
    ("GrFl", "gradientFillMulti"),
    ("patternFill", ""),
    ("FrFX", "frameFXMulti"),
  ]

proc kindFor*(key: string): EffectKind =
  case key
  of "DrSh": ekDropShadow
  of "IrSh": ekInnerShadow
  of "OrGl": ekOuterGlow
  of "IrGl": ekInnerGlow
  of "ebbl": ekBevelEmboss
  of "ChFX": ekSatin
  of "SoFi": ekColorOverlay
  of "GrFl": ekGradientOverlay
  of "patternFill": ekPatternOverlay
  of "FrFX": ekStroke
  else: ekUnknown

proc commonOf(d: Descriptor): FxCommon =
  result.enabled = d.getBool("enab", true)
  let m = d.get("Md  ")
  if m.isSome and m.get().kind == vEnumerated:
    result.blend = m.get().valueId.asString()
  let o = d.get("Opct")
  if o.isSome:
    case o.get().kind
    of vUnitFloat: result.opacity = float32(o.get().floatUnitValue / 100.0)
    of vDouble: result.opacity = float32(o.get().double / 100.0)
    of vInteger: result.opacity = float32(o.get().integer) / 100.0f32
    else: result.opacity = 1.0f32
  else:
    result.opacity = 1.0f32

proc numOf(d: Descriptor, key: string, default = 0.0f32): float32 =
  let v = d.get(key)
  if v.isNone: return default
  case v.get().kind
  of vDouble: float32(v.get().double)
  of vInteger: float32(v.get().integer)
  of vUnitFloat: float32(v.get().floatUnitValue)
  else: default

proc parseOne(key: string, d: Descriptor): Option[Effect] =
  let k = kindFor(key)
  let c = commonOf(d)
  case k
  of ekDropShadow, ekInnerShadow:
    var col = [0.0f32, 0.0f32, 0.0f32]
    let cd = d.getDescriptor("Clr ")
    if cd.isSome and cd.get().classId.asString() == "RGBC":
      let cc = cd.get()
      col = [cc.getDouble("Rd  ", 0.0).float32,
        cc.getDouble("Grn ", 0.0).float32, cc.getDouble("Bl  ", 0.0).float32]
    some(Effect(raw: d, key: key, kind: k, common: c,
      distance: numOf(d, "Dstn", 5.0),
      size: numOf(d, "blur", numOf(d, "Sz  ", 5.0)),
      blur: numOf(d, "blur", 5.0),
      angle: numOf(d, "Angl", 90.0),
      useGlobalLight: d.getBool("uglg", d.getBool("useGlobalAngle", true)),
      spread: clamp(numOf(d, "Ckmt") / 100.0f32, 0.0f32, 1.0f32),
      color: col,
      knocksOut: k == ekDropShadow and d.getBool("layerConceals", true)))
  of ekOuterGlow, ekInnerGlow:
    var col = [0.0f32, 0.0f32, 0.0f32]
    let cd = d.getDescriptor("Clr ")
    if cd.isSome and cd.get().classId.asString() == "RGBC":
      let cc = cd.get()
      col = [cc.getDouble("Rd  ", 0.0).float32,
        cc.getDouble("Grn ", 0.0).float32, cc.getDouble("Bl  ", 0.0).float32]
    let gt = d.get("GlwT")
    some(Effect(raw: d, key: key, kind: k, common: c,
      glowSize: numOf(d, "Sz  ", 5.0), glowBlur: numOf(d, "blur", 5.0),
      glowPrecise: gt.isSome and gt.get().kind == vEnumerated and
        gt.get().valueId.asString() == "PrBL",
      glowSpread: clamp(numOf(d, "Ckmt") / 100.0f32, 0.0f32, 1.0f32),
      glowRange: numOf(d, "Inpr", 50.0) / 100.0f32,
      glowColor: col,
      glowGradient: d.get("Grad").isSome))
  of ekColorOverlay:
    var col = [0.0f32, 0.0f32, 0.0f32]
    let cd = d.getDescriptor("Clr ")
    if cd.isSome and cd.get().classId.asString() == "RGBC":
      let cc = cd.get()
      col = [cc.getDouble("Rd  ", 0.0).float32,
        cc.getDouble("Grn ", 0.0).float32, cc.getDouble("Bl  ", 0.0).float32]
    some(Effect(raw: d, key: key, kind: k, common: c, overlayColor: col))
  else:
    some(Effect(raw: d, key: key, kind: k))

proc effectsFromDescriptor*(d: Descriptor): tuple[master: bool, effects: seq[Effect]] =
  let m = d.get("masterFXSwitch")
  result.master = not (m.isSome and m.get().kind == vBoolean and not m.get().boolean)
  result.effects = @[]
  for (single, multi) in EffectKinds:
    if multi.len > 0:
      let v = d.get(multi)
      if v.isSome and v.get().kind == vList:
        for it in v.get().items:
          if it.kind == vDescriptor:
            let e = parseOne(single, it.descriptor)
            if e.isSome: result.effects.add(e.get())
          elif it.kind == vGlobalObject:
            let e = parseOne(single, it.globalObject)
            if e.isSome: result.effects.add(e.get())
        continue
    let v = d.get(single)
    if v.isSome:
      if v.get().kind == vDescriptor:
        let e = parseOne(single, v.get().descriptor)
        if e.isSome: result.effects.add(e.get())
      elif v.get().kind == vGlobalObject:
        let e = parseOne(single, v.get().globalObject)
        if e.isSome: result.effects.add(e.get())

proc parseLfx2*(data: Span): Option[tuple[master: bool, effects: seq[Effect]]] =
  ## `lfx2` payload: 4-byte version, then a versioned descriptor.
  if data.len < 8: return none(tuple[master: bool, effects: seq[Effect]])
  try:
    let vd = parseVersionedDescriptor(data.slice(4, data.len))
    some(effectsFromDescriptor(vd.descriptor))
  except PsdError:
    none(tuple[master: bool, effects: seq[Effect]])

proc effectsOf*(layer: LayerRecord): Option[tuple[master: bool, effects: seq[Effect]]] =
  ## The layer's `lfx2` effects, or `none` when absent/unreadable.
  ## `lmfx` (mask effects) supersedes and stays raw; legacy `lrFX` is raw-only.
  let b = layer.getBlock("lfx2")
  if b.isNone: return none(tuple[master: bool, effects: seq[Effect]])
  parseLfx2(b.get().data)

proc hasEffects*(layer: LayerRecord): bool {.inline.} =
  layer.getBlock("lfx2").isSome or layer.getBlock("lrFX").isSome or
    layer.getBlock("lmfx").isSome

proc isKnownEffectsKey*(key: string): bool =
  for (s, m) in EffectKinds:
    if key == s or (m.len > 0 and key == m): return true
  key in ["masterFXSwitch", "Scl ", "numModifyingFX"]
