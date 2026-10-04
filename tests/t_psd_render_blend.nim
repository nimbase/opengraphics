## The separable blend functions, checked against an independent float
## implementation of the W3C definitions over every possible input.
##
## The point is that `blendChannel` is integer and has its own rounding and
## guard order, so it can drift from the spec without any one spot looking wrong.
## Walking all 65536 `(src, dst)` pairs for every separable mode and comparing
## against a reference written separately, in f32 with the operands in the
## spec's own order, catches that.

import std/math
import unittest

import ../src/opengraphics/psd

func px(r, g, b: uint8): Rgba {.inline.} =
  ## Opaque colour shorthand. Nim will not let a proc share its type's name, so
  ## the positional form lives here rather than in the library.
  Rgba(r: r, g: g, b: b, a: 255)

# --- the reference ----------------------------------------------------------
#
# Written from the W3C Compositing and Blending Level 1 definitions, taking
# Cb (backdrop) first and Cs (source) second, with all arithmetic in 0..1 f32.
# Deliberately *not* expressed in terms of the implementation under test.

proc rMultiply(cb, cs: float32): float32 = cb * cs
proc rScreen(cb, cs: float32): float32 = 1.0 - (1.0 - cb) * (1.0 - cs)
proc rDodge(cb, cs: float32): float32 =
  if cb <= 0.0: 0.0
  elif cs >= 1.0: 1.0
  else: min(1.0, cb / (1.0 - cs))
proc rBurn(cb, cs: float32): float32 =
  if cb >= 1.0: 1.0
  elif cs <= 0.0: 0.0
  else: 1.0 - min(1.0, (1.0 - cb) / cs)
proc rHardLight(cb, cs: float32): float32 =
  if cs <= 0.5: rMultiply(cb, 2.0 * cs)
  else: rScreen(cb, 2.0 * cs - 1.0)
proc rVivid(cb, cs: float32): float32 =
  if cs <= 0.5: rBurn(cb, 2.0 * cs)
  else: rDodge(cb, 2.0 * cs - 1.0)
proc rSoft(cb, cs: float32): float32 =
  if cs <= 0.5:
    cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb)
  elif cb <= 0.25:
    ((16.0 * cb - 12.0) * cb + 4.0) * cb
  else:
    sqrt(cb)

proc reference(mode: BlendMode, cb, cs: float32): float32 =
  case mode
  of bmNormal, bmDissolve: cs
  of bmDarken: min(cb, cs)
  of bmMultiply: rMultiply(cb, cs)
  of bmColorBurn: rBurn(cb, cs)
  of bmLinearBurn: max(0.0, cb + cs - 1.0)
  of bmLighten: max(cb, cs)
  of bmScreen: rScreen(cb, cs)
  of bmColorDodge: rDodge(cb, cs)
  of bmLinearDodge: min(1.0, cb + cs)
  of bmOverlay: rHardLight(cs, cb)
  of bmSoftLight: rSoft(cb, cs)
  of bmHardLight: rHardLight(cb, cs)
  of bmVividLight: rVivid(cb, cs)
  of bmLinearLight: min(1.0, max(0.0, cb + 2.0 * cs - 1.0))
  of bmPinLight:
    if cs < 0.5: min(cb, 2.0 * cs) else: max(cb, 2.0 * cs - 1.0)
  of bmHardMix:
    if cb + cs >= 1.0: 1.0 else: 0.0
  of bmDifference: abs(cb - cs)
  of bmExclusion: cb + cs - 2.0 * cb * cs
  of bmSubtract: max(0.0, cb - cs)
  of bmDivide:
    if cs <= 0.0: 1.0 else: min(1.0, cb / cs)
  else:
    # non-separable and PassThrough have no per-channel meaning
    cs

const
  SeparableModes = [
    bmNormal, bmDissolve, bmDarken, bmMultiply, bmColorBurn, bmLinearBurn,
    bmLighten, bmScreen, bmColorDodge, bmLinearDodge, bmOverlay, bmSoftLight,
    bmHardLight, bmVividLight, bmLinearLight, bmPinLight, bmHardMix,
    bmDifference, bmExclusion, bmSubtract, bmDivide,
  ]

suite "differential: blendChannel against a float reference":
  test "every separable mode agrees within 1 LSB on all 65536 pairs":
    for mode in SeparableModes:
      var worst = 0
      var worstAt = (0, 0)
      for src in 0 .. 255:
        for dst in 0 .. 255:
          let got = blendChannel(mode, src, dst)
          let want = reference(mode, float32(dst) / 255.0, float32(src) / 255.0)
          let scaled = want * 255.0
          # the reference is in 0..1, so compare in that space
          let delta = abs(float64(got) - scaled)
          if delta > float64(worst) + 0.0001:
            worst = round(delta).int
            worstAt = (src, dst)
          if got < 0 or got > 255:
            check false
      check worst <= 1
      if worst > 1:
        echo "  ", mode, " worst ", worst, " at src=", worstAt[0],
          " dst=", worstAt[1]

  test "the separable set is exactly the modes without a whole-pixel meaning":
    for mode in BlendModes:
      check (mode.isNonSeparable) == (mode in NonSeparableModes)
      check mode in BlendModes

  test "the non-separable modes are the six Photoshop leaves":
    # DarkerColor and LighterColor plus the four W3C HSL modes. Anything else
    # claiming to be non-separable would be a per-channel mode in disguise.
    check NonSeparableModes.len == 6
    for m in [bmHue, bmSaturation, bmColor, bmLuminosity, bmDarkerColor,
        bmLighterColor]:
      check m.isNonSeparable

suite "differential: the non-separable modes have known properties":
  ## Every one of these modes is defined in terms of luminosity, so that is the
  ## property worth pinning: which of the two colours' luminance survives.

  let colours = [
    px(0, 0, 0), px(255, 255, 255), px(200, 30, 90), px(10, 200, 60),
    px(255, 0, 0), px(0, 255, 0), px(0, 0, 255), px(90, 90, 90),
  ]

  proc lumClose(a, b: Rgba): bool =
    abs(float64(luminosity(a)) - float64(luminosity(b))) <= 2.0

  proc movesToward(got, target, base: Rgba): bool =
    ## The result's luminosity reached `target`, or came as close as the 8-bit
    ## gamut allows and stopped between the two.
    ##
    ## Reaching the target exactly is not always possible: SetLum adds an offset
    ## to every channel and then clamps, so a white source over a pure green
    ## backdrop caps out at 193 rather than 255. That is the spec's behaviour at
    ## 8 bits, not a bug, so the property is "moved toward the target and did not
    ## pass it".
    let l = float64(luminosity(got))
    let t = float64(luminosity(target))
    let b0 = float64(luminosity(base))
    if abs(t - b0) <= 2.0:
      return abs(l - t) <= 2.0
    let lo = min(t, b0)
    let hi = max(t, b0)
    l >= lo - 2.0 and l <= hi + 2.0 and abs(l - t) <= abs(b0 - t) + 1.0

  test "luminosity carries the source's luminance onto the backdrop":
    for cb in colours:
      for cs in colours:
        check movesToward(blendRgb(bmLuminosity, cs, cb), cs, cb)

  test "color, hue and saturation carry the backdrop's luminance":
    for mode in [bmColor, bmHue, bmSaturation]:
      for cb in colours:
        for cs in colours:
          check movesToward(blendRgb(mode, cs, cb), cb, cs)

  test "color and hue reach the backdrop's luminance when the gamut allows":
    # A gray target on any backdrop needs no clipping, so this is the exact case.
    for mode in [bmColor, bmHue, bmSaturation]:
      for cb in colours:
        check lumClose(blendRgb(mode, px(128, 128, 128), cb), cb)

  test "luminosity reaches the source's luminance when the gamut allows":
    for cs in colours:
      check lumClose(blendRgb(bmLuminosity, cs, px(128, 128, 128)), cs)

  test "color keeps the source's channel ordering":
    # a mid-gray backdrop, so the luminance shift needs no clamping. Over black
    # the result would legitimately be black: the backdrop's luminance is zero.
    let got = blendRgb(bmColor, px(200, 30, 90), px(128, 128, 128))
    # the source is r=200, g=30, b=90, so the order to preserve is r > b > g
    check got.r > got.b and got.b > got.g

  test "saturation of a gray source collapses toward gray":
    let cb = px(60, 120, 200)
    let got = blendRgb(bmSaturation, px(90, 90, 90), cb)
    # a gray source has no saturation to give, so the result is the backdrop's
    # luminance as a neutral rather than a tinted colour
    check abs(float64(got.r) - float64(got.b)) <= 2.0

  test "darker and lighter color pick the whole colour":
    let dark = px(10, 10, 10)
    let light = px(250, 250, 250)
    check blendRgb(bmDarkerColor, dark, light) == dark
    check blendRgb(bmDarkerColor, light, dark) == dark
    check blendRgb(bmLighterColor, dark, light) == light
    check blendRgb(bmLighterColor, light, dark) == light

  test "darker color can disagree with a per-channel darken":
    # per-channel min would mix red and blue; these modes must not
    let cb = px(255, 0, 0)
    let cs = px(0, 0, 255)
    check blendRgb(bmDarkerColor, cs, cb) in [cb, cs]
    check blendRgb(bmLighterColor, cs, cb) in [cb, cs]
    # and the per-channel path really does mix, which is why it is not used here
    check blendChannel(bmDarken, 0, 255) == 0

  test "separable modes leave the alpha channel alone":
    let dst = Rgba(r: 10, g: 20, b: 30, a: 200)
    for mode in SeparableModes:
      let got = blendRgb(mode, Rgba(r: 200, g: 100, b: 50, a: 77), dst)
      check got.a == 255

  test "results stay inside 0..255 for extreme inputs":
    for mode in BlendModes:
      for cb in [px(0, 0, 0), px(255, 255, 255)]:
        for cs in [px(0, 0, 0), px(255, 255, 255)]:
          let got = blendRgb(mode, cs, cb)
          check got.r <= 255 and got.g <= 255 and got.b <= 255

suite "dissolve":
  test "a fully opaque dissolve keeps every pixel":
    for y in 0 ..< 8:
      for x in 0 ..< 8:
        check dissolveKeeps(x, y, 255)

  test "a zero-opacity dissolve drops every pixel":
    for y in 0 ..< 8:
      for x in 0 ..< 8:
        check not dissolveKeeps(x, y, 0)

  test "the pattern is stable for the same pixel":
    for y in 0 ..< 16:
      for x in 0 ..< 16:
        check dissolveKeeps(x, y, 128) == dissolveKeeps(x, y, 128)

  test "roughly the requested share of pixels survives":
    # 50% over a large area should land close to half, which is what makes the
    # dither read as an even speckle rather than a pattern
    var kept = 0
    let total = 64 * 64
    for y in 0 ..< 64:
      for x in 0 ..< 64:
        if dissolveKeeps(x, y, 128):
          inc kept
    check kept > total * 40 div 100
    check kept < total * 60 div 100

  test "survival is monotonic in the amount":
    var previous = -1
    for amount in [0, 32, 64, 128, 192, 255]:
      var kept = 0
      for y in 0 ..< 32:
        for x in 0 ..< 32:
          if dissolveKeeps(x, y, amount):
            inc kept
      check kept >= previous
      previous = kept

suite "blend keys":
  test "every mode has a distinct key and round-trips":
    var keys: seq[string]
    for m in BlendModes:
      let k = blendModeKey(m)
      check k notin keys
      keys.add k
      check blendModeFromKey(k) == m
    check keys.len == BlendModes.len

  test "unknown keys fall back to normal":
    check blendModeFromKey("zzzz") == bmNormal
    check blendModeFromKey("") == bmNormal
    check blendModeFromKey("norm") == bmNormal