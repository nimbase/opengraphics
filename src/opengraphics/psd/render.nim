## Composites a layer stack into an `ImageBuf`.
##
## This never reads the stored flattened composite: it walks the layer tree and
## blends, so it works on a file whose composite is missing or stale. Use
## `renderToComposite` to replace a document's stored image with a fresh render.
##
## Behaviour reference (clean-room reimplementation, no copied code): libpsd
## `src/blend.c` `psd_layer_blend` for stacking order, opacity and mask
## handling; the blend functions follow the W3C Compositing and Blending
## Level 1 definitions, with `Cb` the backdrop (canvas) and `Cs` the source
## (layer).
##
## ## The two blend paths
##
## The 21 separable modes are per-channel, so `blendChannel` handles them in
## integer arithmetic and stays `pure`, which makes every formula pinnable.
##
## The six non-separable modes cannot be per-channel. Hue, Saturation, Color
## and Luminosity are defined in terms of a colour's luminosity; DarkerColor and
## LighterColor pick one whole colour over the other. `blendRgb` takes the whole
## pixel and does the work in f32, which is what the W3C definitions require.
##
## ## Deliberate simplifications, all listed here
##
## - Everything composites at 8 bits. 16- and 32-bit sources are scaled down by
##   `planeToU8`, so precision is lost. There is no float or 16-bit compositor.
## - Dissolve is a deterministic dither keyed on the pixel position rather than
##   a random number. Photoshop draws fresh noise each time; a stable hash gives
##   the same speckle on every render, which is what a renderer and its tests
##   both need.
## - Clipped layers paint only where the base layer below has content, a
##   canvas-shape approximation of clipping groups.
## - Mask `invert` is applied; mask coordinates are used as stored, with no
##   `relative` shift.
## - A group with a blending mode of its own is rendered onto an isolated
##   canvas and blended as one layer, which costs a full-canvas buffer per such
##   group. Pass-through groups, the default, blend straight into the backdrop.

import std/algorithm
import std/math
import std/options

import ./adjustments
import ./document
import ./effects
import ./error
import ./layers
import ./pixels
import ./path
import ./raster
import ./tagged

type
  BlendMode* {.pure.} = enum
    ## The 27 layer blend modes plus Normal and the group marker PassThrough.
    bmNormal = 0
    bmDissolve
    bmDarken
    bmMultiply
    bmColorBurn
    bmLinearBurn
    bmDarkerColor
    bmLighten
    bmScreen
    bmColorDodge
    bmLinearDodge
    bmLighterColor
    bmOverlay
    bmSoftLight
    bmHardLight
    bmVividLight
    bmLinearLight
    bmPinLight
    bmHardMix
    bmDifference
    bmExclusion
    bmSubtract
    bmDivide
    bmHue
    bmSaturation
    bmColor
    bmLuminosity
    bmPassThrough

const
  BlendModes* = [
    bmNormal, bmDissolve, bmDarken, bmMultiply, bmColorBurn, bmLinearBurn,
    bmDarkerColor, bmLighten, bmScreen, bmColorDodge, bmLinearDodge,
    bmLighterColor, bmOverlay, bmSoftLight, bmHardLight, bmVividLight,
    bmLinearLight, bmPinLight, bmHardMix, bmDifference, bmExclusion,
    bmSubtract, bmDivide, bmHue, bmSaturation, bmColor, bmLuminosity,
  ]
    ## Every mode that has a 4-byte key, so tests can walk them all.

const
  NonSeparableModes* = [bmDarkerColor, bmLighterColor, bmHue, bmSaturation,
    bmColor, bmLuminosity]
    ## The modes that need the whole pixel rather than one channel.

proc isNonSeparable*(m: BlendMode): bool {.inline.} =
  ## Whether this mode must go through `blendRgb`.
  m in NonSeparableModes

proc blendModeFromKey*(key: string): BlendMode =
  ## Map a 4-byte Photoshop blend key to a mode. Unlisted keys fall back to
  ## Normal, which is what Photoshop itself does with a mode it cannot read.
  case key
  of "norm": bmNormal
  of "diss": bmDissolve
  of "dark": bmDarken
  of "mul ": bmMultiply
  of "idiv": bmColorBurn
  of "lbrn": bmLinearBurn
  of "dkCl": bmDarkerColor
  of "lite": bmLighten
  of "scrn": bmScreen
  of "div ": bmColorDodge
  of "lddg": bmLinearDodge
  of "lgCl": bmLighterColor
  of "over": bmOverlay
  of "sLit": bmSoftLight
  of "hLit": bmHardLight
  of "vLit": bmVividLight
  of "lLit": bmLinearLight
  of "pLit": bmPinLight
  of "hMix": bmHardMix
  of "diff": bmDifference
  of "smud": bmExclusion
  of "fsub": bmSubtract
  of "fdiv": bmDivide
  of "hue ": bmHue
  of "sat ": bmSaturation
  of "colr": bmColor
  of "lum ": bmLuminosity
  of "pass": bmPassThrough
  else: bmNormal

proc blendModeKey*(m: BlendMode): string =
  ## The 4-byte key Photoshop stores for a mode, so a parsed file round-trips
  ## its own blend settings.
  case m
  of bmNormal: "norm"
  of bmDissolve: "diss"
  of bmDarken: "dark"
  of bmMultiply: "mul "
  of bmColorBurn: "idiv"
  of bmLinearBurn: "lbrn"
  of bmDarkerColor: "dkCl"
  of bmLighten: "lite"
  of bmScreen: "scrn"
  of bmColorDodge: "div "
  of bmLinearDodge: "lddg"
  of bmLighterColor: "lgCl"
  of bmOverlay: "over"
  of bmSoftLight: "sLit"
  of bmHardLight: "hLit"
  of bmVividLight: "vLit"
  of bmLinearLight: "lLit"
  of bmPinLight: "pLit"
  of bmHardMix: "hMix"
  of bmDifference: "diff"
  of bmExclusion: "smud"
  of bmSubtract: "fsub"
  of bmDivide: "fdiv"
  of bmHue: "hue "
  of bmSaturation: "sat "
  of bmColor: "colr"
  of bmLuminosity: "lum "
  of bmPassThrough: "pass"

# --- separable blend functions, integer ---------------------------------------
#
# Each takes the backdrop first and the source second, matching the W3C
# definition B(Cb, Cs). `blendChannel` takes them the other way round, because
# that is the order every caller already has the values in.

proc bMultiply*(cb, cs: int): int {.inline.} = cb * cs div 255

proc bScreen*(cb, cs: int): int {.inline.} =
  255 - (255 - cb) * (255 - cs) div 255

proc bColorDodge*(cb, cs: int): int {.inline.} =
  ## W3C ColorDodge. The `cb == 0` guard is required: without it the division
  ## would be by 255 and produce a wrong answer instead of the defined 0.
  if cb == 0: 0
  elif cs == 255: 255
  else: min(255, cb * 255 div (255 - cs))

proc bColorBurn*(cb, cs: int): int {.inline.} =
  ## W3C ColorBurn, the mirror of ColorDodge.
  if cb == 255: 255
  elif cs == 0: 0
  else: 255 - min(255, (255 - cb) * 255 div cs)

proc bHardLight*(cb, cs: int): int {.inline.} =
  if cs < 128: bMultiply(cb, min(255, 2 * cs))
  else: bScreen(cb, max(0, 2 * cs - 255))

proc bOverlay*(cb, cs: int): int {.inline.} =
  ## W3C Overlay is HardLight with the operands swapped.
  bHardLight(cs, cb)

proc bVividLight*(cb, cs: int): int {.inline.} =
  if cs <= 128: bColorBurn(cb, min(255, 2 * cs))
  else: bColorDodge(cb, max(0, 2 * cs - 255))

proc bPinLight*(cb, cs: int): int {.inline.} =
  if cs < 128: min(cb, 2 * cs)
  else: max(cb, 2 * cs - 255)

proc bSoftLight*(cb, cs: int): int =
  ## W3C SoftLight. The curve genuinely needs a fractional exponent and a square
  ## root, so this one mode does its arithmetic in f32 even though its inputs
  ## and result are integers.
  ##
  ## The branch is `cs <= 127`, not `cs <= 128`: the spec's threshold is a
  ## normalised 0.5, and 128/255 is 0.50196, which is *above* it. Testing
  ## `cs <= 128` sends 128 down the wrong branch and is off by up to 64.
  if cs <= 127:
    # Cb - (1-2Cs)*Cb*(1-Cb), scaled back into 0..255
    let fcb = float64(cb) / 255.0
    let fcs = float64(cs) / 255.0
    result = round((fcb - (1.0 - 2.0 * fcs) * fcb * (1.0 - fcb)) * 255.0).int
  elif cb <= 63:
    # ((16Cb - 12)Cb + 4)Cb
    let fcb = float64(cb) / 255.0
    result = round(((16.0 * fcb - 12.0) * fcb + 4.0) * fcb * 255.0).int
  else:
    result = round(sqrt(float64(cb) * 255.0)).int

proc blendChannel*(mode: BlendMode, src, dst: int): int =
  ## Blend one channel, `src` the layer and `dst` the canvas, 0..255 in and out.
  ## Pure, so unit tests can pin every formula.
  ##
  ## Only the separable modes mean anything here. The non-separable ones and
  ## PassThrough return `src`, which is the correct answer for none of them:
  ## `blendRgb` is what the compositor calls, and it handles them properly.
  case mode
  of bmNormal, bmDissolve, bmPassThrough: src
  of bmDarken: min(src, dst)
  of bmMultiply: bMultiply(dst, src)
  of bmColorBurn: bColorBurn(dst, src)
  of bmLinearBurn: max(0, src + dst - 255)
  of bmLighten: max(src, dst)
  of bmScreen: bScreen(dst, src)
  of bmColorDodge: bColorDodge(dst, src)
  of bmLinearDodge: min(255, src + dst)
  of bmOverlay: bOverlay(dst, src)
  of bmSoftLight: bSoftLight(dst, src)
  of bmHardLight: bHardLight(dst, src)
  of bmVividLight: bVividLight(dst, src)
  of bmLinearLight: min(255, max(0, dst + 2 * src - 255))
  of bmPinLight: bPinLight(dst, src)
  of bmHardMix:
    if src + dst >= 255: 255 else: 0
  of bmDifference: abs(dst - src)
  of bmExclusion: dst + src - 2 * dst * src div 255
  of bmSubtract: max(0, dst - src)
  of bmDivide:
    if src == 0: 255
    else: min(255, dst * 255 div src)
  of bmDarkerColor, bmLighterColor, bmHue, bmSaturation, bmColor, bmLuminosity:
    src ## needs the whole pixel; see `blendRgb`

# --- non-separable blend functions, f32 ---------------------------------------

proc luminosity*(c: Rgba): float32 {.inline.} =
  ## W3C Lum(C) = 0.3R + 0.59G + 0.11B.
  0.3 * float32(c.r) + 0.59 * float32(c.g) + 0.11 * float32(c.b)

proc saturation*(c: Rgba): float32 {.inline.} =
  ## W3C Sat(C) = max(C) - min(C).
  float32(max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)))

proc clipColor*(c: Rgba): Rgba =
  ## W3C ClipColor: shift the colour until its channels fit 0..1, leaving its
  ## luminosity and saturation alone.
  var r = float32(c.r) / 255.0
  var g = float32(c.g) / 255.0
  var b = float32(c.b) / 255.0
  # The W3C definition computes `l = Lum(C)` first and then never reads it: the
  # clip is pure, with no luminosity term. Kept as a comment so the divergence
  # from `setLum` below does not look like an oversight.
  let n = min(r, min(g, b))
  let x = max(r, max(g, b))
  if n < 0.0:
    r -= n
    g -= n
    b -= n
  if x > 1.0:
    r += 1.0 - x
    g += 1.0 - x
    b += 1.0 - x
  let cl = proc(v: float32): uint8 =
    round(v * 255.0).clamp(0.0, 255.0).uint8
  Rgba(r: cl(r), g: cl(g), b: cl(b), a: 255)

proc setLum*(c: Rgba, l: float32): Rgba =
  ## W3C SetLum(C, l) = C + (l - Lum(C)), clamped. `l` is 0..255.
  let d = l - luminosity(c)
  let cl = proc(v: uint8): uint8 =
    (float32(v) + d).clamp(0.0, 255.0).uint8
  Rgba(r: cl(c.r), g: cl(c.g), b: cl(c.b), a: 255)

proc blendRgb*(mode: BlendMode, src, dst: Rgba): Rgba =
  ## Blend one whole pixel, `src` the layer over `dst` the canvas.
  ##
  ## The separable modes are per-channel and delegate to `blendChannel`. The six
  ## non-separable modes need the whole colour: the four HSL ones are defined by
  ## shifting luminosity, and DarkerColor/LighterColor take one colour or the
  ## other wholesale, which per-channel blending cannot express.
  if not mode.isNonSeparable:
    return Rgba(
      r: uint8(blendChannel(mode, int(src.r), int(dst.r))),
      g: uint8(blendChannel(mode, int(src.g), int(dst.g))),
      b: uint8(blendChannel(mode, int(src.b), int(dst.b))),
      a: 255)
  case mode
  of bmDarkerColor:
    if luminosity(src) <= luminosity(dst): src else: dst
  of bmLighterColor:
    if luminosity(src) >= luminosity(dst): src else: dst
  of bmHue:
    # the source's hue and saturation, the backdrop's luminosity
    setLum(clipColor(src), luminosity(dst))
  of bmSaturation:
    setLum(clipColor(setLum(src, luminosity(dst))), luminosity(dst))
  of bmColor:
    setLum(src, luminosity(dst))
  of bmLuminosity:
    setLum(dst, luminosity(src))
  else:
    Rgba(r: src.r, g: src.g, b: src.b, a: 255)

# --- dissolve ----------------------------------------------------------------

proc dissolveKeeps*(x, y: int, amount: int): bool {.inline.} =
  ## Whether the pixel at `(x, y)` survives an opacity of `amount` under
  ## Dissolve.
  ##
  ## A stable hash of the position rather than a random draw, so the same file
  ## renders the same speckle every time. The constants are the usual
  ## odd-one-out mixers; any good avalanche works.
  if amount >= 255:
    return true
  if amount <= 0:
    return false
  var h = uint32(x) * 0x9E3779B1'u32 xor uint32(y) * 0x85EBCA6B'u32
  h = h xor (h shr 15)
  h = h * 0x2545F491'u32
  h = h xor (h shr 13)
  (h and 0xFF'u32) < uint32(amount)

# --- compositing --------------------------------------------------------------

type
  MaskSampler = object
    ## One layer's user-mask channel, decoded once up front.
    ##
    ## Sampling the mask per pixel meant a full channel inflate for every pixel
    ## inside the mask rect: O(W*H) inflations of an O(W*H) channel. Hoisting the
    ## decode out of the pixel loop makes it one.
    present: bool    ## either mask resolved to something usable
    rasterPresent: bool
    rect: Rect       ## the raster mask's rect, which sizes its plane
    defaultColor: int
    invert: bool
    rasterPlane: string
    vectorPresent: bool
    vectorPlane: string  ## layer-rect sized, so index is (y-top)*w + (x-left)
    vectorInvert: bool
    vectorTop, vectorLeft: int32
    vectorWidth: int

proc initMaskSampler(doc: Document, index: int): MaskSampler =
  ## The masks of layer `index`, resolved into one coverage source.
  ##
  ## A layer can carry both a raster user mask (channel -2) and a vector mask
  ## (`vmsk` / `vsms`), and Photoshop intersects them: a pixel needs both to
  ## allow it through. Rather than two samplers sampled per pixel, the two are
  ## multiplied together once here so the compositing loop keeps sampling a
  ## single plane.
  let layer = doc.layers()[index]
  let r = layer.rect

  # The raster mask.
  let m = layer.layerMask()
  if m.isSome:
    let mm = m.get()
    result.rasterPresent = true
    # `present` even when the plane turns out to be unusable: the record's
    # default colour is then the mask everywhere, which is the documented
    # reading of a mask whose channel cannot be decoded. Deriving `present` from
    # whether a plane decoded would silently discard the mask entirely.
    result.present = true
    result.rect = mm.rect
    result.defaultColor = int(mm.defaultColor)
    result.invert = mm.flags.invert
    let mr = result.rect
    if mr.width() > 0 and mr.height() > 0:
      let plane = doc.layerPlane(index, ChannelUserMask)
      if plane.len == mr.width() * mr.height():
        result.rasterPlane = plane

  # The vector mask, rasterised once to the layer's own size. `vmsk`/`vsms`
  # knots are fractions of the *document*, so rasterising at the layer rect is
  # the right resolution: the compositor only ever asks about pixels inside it.
  if layer.hasVectorMask():
    let vb = layer.vectorMask().get()
    if (vb.flags and VectorFlagDisabled) == 0 and r.width() > 0 and r.height() > 0:
      let plane = rasterizeBlock(vb, r.width(), r.height())
      if plane.len == r.width() * r.height():
        result.vectorPresent = true
        result.vectorPlane = plane
        result.vectorTop = r.top
        result.vectorLeft = r.left
        result.vectorWidth = r.width()
        # `VectorFlagInvert` is the vector equivalent of the raster invert flag.
        result.vectorInvert = (vb.flags and VectorFlagInvert) != 0
        result.present = true


proc sampleAt(m: MaskSampler, x, y: int): int =
  ## Combined mask coverage 0..255 at canvas coords, with invert applied.
  if not m.present:
    return 255
  var v = 255
  if m.rasterPresent:
    var rv = m.defaultColor
    let r = m.rect
    if x >= int(r.left) and x < int(r.right) and y >= int(r.top) and
        y < int(r.bottom) and m.rasterPlane.len > 0:
      let mw = r.width()
      rv = ord(m.rasterPlane[(y - int(r.top)) * mw + (x - int(r.left))])
    if m.invert:
      rv = 255 - rv
    v = rv
  if m.vectorPresent:
    var vv = ord(m.vectorPlane[(y - m.vectorTop) * m.vectorWidth + (x - m.vectorLeft)])
    if m.vectorInvert:
      vv = 255 - vv
    v = v * vv div 255
  v

# --- adjustment layers --------------------------------------------------------
#
# An adjustment layer has no pixels of its own: it transforms the backdrop
# beneath it, then blends the result back with its opacity, mask, clipping
# and blend mode. Layouts live in `psd/adjustments`; evaluation here follows
# `references/photocraft/crates/compose/src/adjust.rs` (clean-room: formulas
# only). Only the exact 8-bit kinds are applied yet; anything else stays
# transparent, which is the previous behaviour.

const
  LevelsToePower = 2.2
  LegacyPivot = 128.0 / 255.0
  D50White = [0.96422, 1.0, 0.82521]
  SrgbToXyzD50 = [[0.436074, 0.385064, 0.143080],
    [0.222504, 0.716878, 0.060618],
    [0.013932, 0.097104, 0.714173]]
  XyzD50ToSrgb = [[3.133856, -1.616867, -0.490615],
    [-0.978768, 1.916142, 0.033454],
    [0.071945, -0.228991, 1.405243]]

proc levelsGammaNim(u, g: float64): float64 =
  ## Midtone gamma with the shadow toe Photoshop uses above gamma 1.
  let c = 1.0 / g
  if g <= 1.0:
    return pow(u, c)
  let a = pow(2.0, g)
  let q = LevelsToePower
  let u1 = pow((1.0 - c / q) / (a * (1.0 - 1.0 / q)), 1.0 / (1.0 - c))
  if u >= u1 or u1 <= 0.0:
    return pow(u, c)
  let b = (a * u1 - pow(u1, c)) / pow(u1, q)
  if b != b or b == Inf or b == NegInf: # non-finite
    return pow(u, c)
  a * u - b * pow(u, q)

proc levelsChannelNim(ch: LevelsChannel, v: float64): float64 =
  ## `levels_q` at the 8-bit quantum: every step rounds half up to a level.
  const q = 255.0
  let whole = proc(x: float64): float64 = floor(x * q + 0.5) / q
  let rng = max(float64(ch.inWhite) - float64(ch.inBlack), 1e-6)
  let vq = round(v * q) / q
  let u = floor(clamp((vq - float64(ch.inBlack)) / rng, 0.0, 1.0) * q +
    0.5 + 1e-3) / q
  let t = whole(levelsGammaNim(u, max(float64(ch.gamma), 0.01)))
  whole(float64(ch.outBlack) + t *
    (float64(ch.outWhite) - float64(ch.outBlack)))

proc sortedCurvePts(pts: seq[CurvePoint]): seq[tuple[x, y: float64]] =
  ## Finite points sorted by input, first wins within 1e-6.
  for p in pts:
    let x = float64(p.input)
    let y = float64(p.output)
    if x != x or y != y or x == Inf or x == NegInf or y == Inf or y == NegInf:
      continue
    result.add((x, y))
  result.sort(proc(a, b: tuple[x, y: float64]): int = cmp(a.x, b.x))
  var kept: seq[tuple[x, y: float64]] = @[]
  for p in result:
    if kept.len > 0 and abs(p.x - kept[^1].x) < 1e-6:
      continue
    kept.add(p)
  kept

proc curveTable256*(pts: seq[CurvePoint], pencil: bool): array[256, float64] =
  ## One Curves curve sampled at the 256 whole levels: natural cubic spline
  ## (constant outside the ends, clamped), or piecewise linear for pencil.
  let clean = sortedCurvePts(pts)
  if clean.len < 2:
    for i in 0 ..< 256:
      result[i] = float64(i) / 255.0
    return
  if pencil:
    var seg = 0
    for k in 0 ..< 256:
      let xv = float64(k) / 255.0
      if xv <= clean[0].x:
        result[k] = clamp(clean[0].y, 0.0, 1.0)
        continue
      if xv >= clean[^1].x:
        result[k] = clamp(clean[^1].y, 0.0, 1.0)
        continue
      while seg + 1 < clean.len - 1 and clean[seg + 1].x < xv:
        inc seg
      let (x0, y0) = clean[seg]
      let (x1, y1) = clean[seg + 1]
      let t = if x1 > x0: (xv - x0) / (x1 - x0) else: 0.0
      result[k] = clamp(y0 + (y1 - y0) * t, 0.0, 1.0)
    return
  # Natural spline: tridiagonal solve for second derivatives, in float64.
  let n = clean.len
  var m2 = newSeq[float64](n)
  if n > 2:
    var xs = newSeq[float64](n)
    var ys = newSeq[float64](n)
    for i, p in clean:
      xs[i] = p.x
      ys[i] = p.y
    var c = newSeq[float64](n)
    var d = newSeq[float64](n)
    for i in 1 ..< n - 1:
      let (h0, h1) = (xs[i] - xs[i - 1], xs[i + 1] - xs[i])
      let aa = h0 / 6.0
      let bb = (h0 + h1) / 3.0
      let cc = h1 / 6.0
      let rr = (ys[i + 1] - ys[i]) / h1 - (ys[i] - ys[i - 1]) / h0
      let denom = bb - aa * c[i - 1]
      c[i] = cc / denom
      d[i] = (rr - aa * d[i - 1]) / denom
    for i in countdown(n - 2, 1):
      m2[i] = d[i] - c[i] * m2[i + 1]
  for k in 0 ..< 256:
    let xv = float64(k) / 255.0
    if xv <= clean[0].x:
      result[k] = clamp(clean[0].y, 0.0, 1.0)
      continue
    if xv >= clean[n - 1].x:
      result[k] = clamp(clean[n - 1].y, 0.0, 1.0)
      continue
    var i = n - 2
    for j in 0 ..< n - 1:
      if xv <= clean[j + 1].x:
        i = j
        break
    let h = clean[i + 1].x - clean[i].x
    let a = (clean[i + 1].x - xv) / h
    let b = (xv - clean[i].x) / h
    result[k] = clamp(a * clean[i].y + b * clean[i + 1].y +
      ((a * a * a - a) * m2[i] + (b * b * b - b) * m2[i + 1]) * h * h / 6.0,
      0.0, 1.0)

type
  CurvesTables* = tuple[ch: array[3, array[256, int]], master: array[256, int]]

proc srgbToLinearNim(v: float64): float64 =
  ## sRGB transfer: encoded to linear light.
  if v <= 0.04045: v / 12.92
  else: pow((v + 0.055) / 1.055, 2.4)

proc linearToSrgbNim(v: float64): float64 =
  ## sRGB transfer: linear light to encoded.
  if v <= 0.0031308: v * 12.92
  else: 1.055 * pow(v, 1.0 / 2.4) - 0.055

proc photoMatrixFor*(adj: Adjustment): array[3, array[3, float64]] =
  ## Photo filter gel as a 3x3 over linear light: XYZ_D50_TO_SRGB x diag(s)
  ## x SRGB_TO_XYZ_D50, where s scales each ink by the filter color.
  let d = clamp(float64(adj.pfDensity), 0.0, 1.0)
  var flin: array[3, float64]
  for i in 0 ..< 3:
    flin[i] = srgbToLinearNim(clamp(float64(adj.pfColor[i]), 0.0, 1.0))
  var s: array[3, float64]
  for i in 0 ..< 3:
    let xyz = SrgbToXyzD50[i][0] * flin[0] + SrgbToXyzD50[i][1] * flin[1] +
      SrgbToXyzD50[i][2] * flin[2]
    s[i] = 1.0 - d + d * xyz / D50White[i]
  for r in 0 ..< 3:
    for c in 0 ..< 3:
      result[r][c] = XyzD50ToSrgb[r][0] * s[0] * SrgbToXyzD50[0][c] +
        XyzD50ToSrgb[r][1] * s[1] * SrgbToXyzD50[1][c] +
        XyzD50ToSrgb[r][2] * s[2] * SrgbToXyzD50[2][c]

proc photoPixel*(m: array[3, array[3, float64]], preserve: bool,
    r, g, b: int): tuple[r, g, b: int] =
  ## One pixel through a photo filter matrix, with optional SetLum preserve.
  let c = [float64(r) / 255.0, float64(g) / 255.0, float64(b) / 255.0]
  let lin = [srgbToLinearNim(c[0]), srgbToLinearNim(c[1]),
    srgbToLinearNim(c[2])]
  var e: array[3, float64]
  for i in 0 ..< 3:
    e[i] = linearToSrgbNim(m[i][0] * lin[0] + m[i][1] * lin[1] +
      m[i][2] * lin[2])
  if preserve:
    let want = 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
    let got = 0.3 * e[0] + 0.59 * e[1] + 0.11 * e[2]
    let d = want - got
    for i in 0 ..< 3:
      e[i] += d
  (clamp(int(round(e[0] * 255.0)), 0, 255),
    clamp(int(round(e[1] * 255.0)), 0, 255),
    clamp(int(round(e[2] * 255.0)), 0, 255))

type
  GradientStop* = tuple[pos: float64, rgb: array[3, float64]]

  HueSatTables* = tuple[hasRanges: bool,
    dh, ds, dl: seq[float64]]

proc remEuclidNim(a, b: float64): float64 =
  ## Non-negative remainder for positive `b`, like Rust's `rem_euclid`.
  a - floor(a / b) * b

proc rgbToHslNim*(c: array[3, float64]): tuple[h, s, l: float64] =
  let mx = max(c[0], max(c[1], c[2]))
  let mn = min(c[0], min(c[1], c[2]))
  let l = (mx + mn) / 2.0
  if abs(mx - mn) < 1e-7:
    return (0.0, 0.0, l)
  let d = mx - mn
  let s = if l > 0.5: d / (2.0 - mx - mn) else: d / (mx + mn)
  let h =
    if mx == c[0]: remEuclidNim((c[1] - c[2]) / d, 6.0)
    elif mx == c[1]: (c[2] - c[0]) / d + 2.0
    else: (c[0] - c[1]) / d + 4.0
  (h / 6.0, s, l)

proc hueRgbNim(h, p, q: float64): array[3, float64] =
  proc f(t: float64): float64 =
    let tt = remEuclidNim(t, 1.0)
    if tt < 1.0 / 6.0: p + (q - p) * 6.0 * tt
    elif tt < 0.5: q
    elif tt < 2.0 / 3.0: p + (q - p) * (2.0 / 3.0 - tt) * 6.0
    else: p
  [f(h + 1.0 / 3.0), f(h), f(h - 1.0 / 3.0)]

proc hslToRgbNim*(h, s, l: float64): array[3, float64] =
  if s <= 0.0:
    return [l, l, l]
  let q = if l < 0.5: l * (1.0 + s) else: l + s - l * s
  hueRgbNim(h, 2.0 * l - q, q)

proc hueSatPixelNim*(c: array[3, float64], hue, s, l: float64,
    colorize: bool): array[3, float64] =
  ## One Hue/Saturation evaluation: hue in degrees, saturation and
  ## lightness as -1..1 fractions.
  if colorize:
    let ll = rgbToHslNim(c).l
    let lighten = if l > 0.0: ll + (1.0 - ll) * l else: ll * (1.0 + l)
    return hslToRgbNim(remEuclidNim(hue, 360.0) / 360.0,
      min(abs(s), 1.0), lighten)
  let lighten = proc(v: float64): float64 =
    if l > 0.0: v + (1.0 - v) * l else: v * (1.0 + l)
  let lc = [lighten(c[0]), lighten(c[1]), lighten(c[2])]
  let (hh, ss, ll) = rgbToHslNim(lc)
  let hh2 = remEuclidNim(hh + hue / 360.0, 1.0)
  var ss2 = if s > 0.0: ss / max(1.0 - s, 1.0 / 512.0)
    else: ss * (1.0 + s)
  ss2 = clamp(ss2, 0.0, 1.0)
  hslToRgbNim(hh2, ss2, ll)

proc rangeWeightNim*(bounds: array[4, float64],
    deg: float64): float64 =
  ## How much a hue in degrees belongs to a range, 0..1, wrap-aware.
  let a = bounds[0]
  proc rel(x: float64): float64 =
    if x != x: 0.0 else: remEuclidNim(x - a, 360.0)
  let b = rel(bounds[1])
  var c = rel(bounds[2])
  if c < b:
    c = b
  var d = rel(bounds[3])
  if d < c:
    d = c
  let h = rel(deg)
  if h <= b:
    if b <= 0.0: 1.0 else: h / b
  elif h <= c:
    1.0
  elif h <= d:
    if d <= c: 1.0 else: (d - h) / (d - c)
  else:
    0.0

proc hueSatTablesFor*(adj: Adjustment): HueSatTables =
  ## Per-hue range tables (4096 entries over the color wheel), or no ranges.
  for r in adj.hueRanges:
    if r.hue != 0.0f32 or r.saturation != 0.0f32 or r.lightness != 0.0f32:
      result.hasRanges = true
      break
  if not result.hasRanges:
    return
  const N = 4096
  result.dh = newSeq[float64](N)
  result.ds = newSeq[float64](N)
  result.dl = newSeq[float64](N)
  for k in 0 ..< N:
    let deg = float64(k) / float64(N - 1) * 360.0
    var acc = [0.0, 0.0, 0.0]
    for r in adj.hueRanges:
      if r.hue == 0.0f32 and r.saturation == 0.0f32 and
          r.lightness == 0.0f32:
        continue
      let w = rangeWeightNim([float64(r.bounds[0]), float64(r.bounds[1]),
        float64(r.bounds[2]), float64(r.bounds[3])], deg)
      acc[0] += w * float64(r.hue)
      acc[1] += w * float64(r.saturation) / 100.0
      acc[2] += w * float64(r.lightness) / 100.0
    result.dh[k] = acc[0]
    result.ds[k] = acc[1]
    result.dl[k] = acc[2]

proc hueSatLutNim*(tab: openArray[float64], v: float64): float64 =
  ## Linear sample of a hue table at 0..1 turns.
  let x = clamp(v, 0.0, 1.0) * float64(tab.len - 1)
  let i = min(int(x), tab.len - 2)
  let f = x - float64(i)
  tab[i] * (1.0 - f) + tab[i + 1] * f

const
  BrightnessKnee* = 126.0 / 255.0
  BrightnessEaseFrom* = 109.5

type
  BrightRoll* = tuple[s, e, x0, alpha: float64, hermite: bool]

proc brightRollNew(b: float64): BrightRoll =
  ## The raised curve's line slope and roll-off for one slider magnitude.
  let s = pow(1.375, b / 50.0)
  let e = 1.0 / (1.0 + 0.084 * b)
  let x0 = min(BrightnessKnee / s, 1.0)
  let secant = (1.0 - BrightnessKnee) / max(1.0 - x0, 1e-6)
  let alpha = s / secant
  let beta = e / secant
  (s: s, e: e, x0: x0, alpha: alpha,
    hermite: alpha * alpha + beta * beta <= 9.0)

proc brightRollEval(r: BrightRoll, x: float64): float64 =
  ## The line, then a monotone roll-off to (1, 1).
  if x <= r.x0:
    return min(BrightnessKnee, r.s * x)
  let h = max(1.0 - r.x0, 1e-6)
  let t = clamp((x - r.x0) / h, 0.0, 1.0)
  let (t2, t3) = (t * t, t * t * t)
  let y =
    if r.hermite:
      (2.0 * t3 - 3.0 * t2 + 1.0) * BrightnessKnee +
        (t3 - 2.0 * t2 + t) * h * r.s + (-2.0 * t3 + 3.0 * t2) +
        (t3 - t2) * h * r.e
    else:
      1.0 - (1.0 - BrightnessKnee) * pow(1.0 - t, r.alpha)
  clamp(y, 0.0, 1.0)

proc brightness150Nim(x: float64): float64 =
  ## The modern Brightness curve at +150: line, Hermite, exponential tail.
  const S = 2.585
  const C = 0.131
  const D = 0.4 / 255.0
  const X1 = 52.0 / 255.0
  const X2 = 168.0 / 255.0
  let tail = 1.0 - D * (exp((1.0 - x) / C) - 1.0)
  let xc = clamp(x, 0.0, 1.0)
  if xc <= X1:
    return S * xc
  if xc >= X2:
    return min(tail, 1.0)
  let y1 = S * X1
  let y2 = 1.0 - D * (exp((1.0 - X2) / C) - 1.0)
  let m2 = D / C * exp((1.0 - X2) / C)
  let h = X2 - X1
  let t = (xc - X1) / h
  let (t2, t3) = (t * t, t * t * t)
  (2.0 * t3 - 3.0 * t2 + 1.0) * y1 + (t3 - 2.0 * t2 + t) * h * S +
    (-2.0 * t3 + 3.0 * t2) * y2 + (t3 - t2) * h * m2

proc modernBrightnessNim*(v, b: float64): float64 =
  ## Modern Brightness: raised curve, easing into the +150 shape past 109.5;
  ## lowering inverts the raised curve by bisection.
  if b == 0.0 or b != b or b == Inf or b == NegInf:
    return v
  let vv = clamp(v, 0.0, 1.0)
  let mag = abs(b)
  let roll = brightRollNew(mag)
  let toward150 = clamp((mag - BrightnessEaseFrom) / (150.0 - BrightnessEaseFrom),
    0.0, 1.0)
  proc raised(x: float64): float64 =
    let y = brightRollEval(roll, x)
    if toward150 <= 0.0:
      return y
    let target = brightness150Nim(x)
    let held = min(y, target)
    clamp(held + toward150 * (target - held), 0.0, 1.0)
  if b > 0.0:
    return raised(vv)
  if vv <= 0.0 or vv >= 1.0:
    return vv
  var lo = 0.0
  var hi = 1.0
  for _ in 0 ..< 32:
    let mid = 0.5 * (lo + hi)
    if raised(mid) < vv:
      lo = mid
    else:
      hi = mid
  0.5 * (lo + hi)

proc modernContrastNim*(v, c: float64): float64 =
  ## Modern Contrast: cubic Hermite pinned at black, middle gray and white.
  let vv = clamp(v, 0.0, 1.0)
  if c == 0.0:
    return vv
  let k = c / 128.0
  let (en, mid) = (1.0 - k, 1.0 + k)
  proc half(t: float64): float64 =
    en * 0.5 * (t * t * t - 2.0 * t * t + t) +
      (-2.0 * t * t * t + 3.0 * t * t) * 0.5 +
      mid * 0.5 * (t * t * t - t * t)
  if vv <= 0.5: half(vv / 0.5)
  else: 1.0 - half((1.0 - vv) / 0.5)

proc modernLutNim*(brightness, contrast: float64): seq[float64] =
  ## Brightness then contrast over 4096 samples, as Photoshop applies them.
  const N = 4096
  result = newSeq[float64](N)
  for k in 0 ..< N:
    let x = float64(k) / float64(N - 1)
    result[k] = modernContrastNim(modernBrightnessNim(x, brightness),
      contrast)

const
  VibranceBoost* = [0.5001, 0.0887, 0.4374, 0.7573, -0.8113, 0.5154, 2.8026]
  VibranceGrey* = [0.288, 0.712]

proc vibranceHsvHue(c: array[3, float64], mx, mn: float64): float64 =
  ## HSV hue in degrees, given the extreme channels.
  let d = mx - mn
  let h =
    if mx == c[0]: remEuclidNim((c[1] - c[2]) / d, 6.0)
    elif mx == c[1]: (c[2] - c[0]) / d + 2.0
    else: (c[0] - c[1]) / d + 4.0
  h * 60.0

proc vibranceSkin(h: float64): float64 =
  ## How much positive Vibrance treats a hue as skin: full on 0-30 degrees,
  ## fading out by 45 and back in from 300.
  if h <= 30.0: 1.0
  elif h < 45.0: (45.0 - h) / 15.0
  elif h < 300.0: 0.0
  else: (h - 300.0) / 60.0

proc vibranceLinNim*(c: array[3, float64], v: float64): array[3, float64] =
  ## The Vibrance slider on a linear-light pixel: saturation `t` and peak `V`
  ## reshaped, positives boosted away from skin hues.
  let mx = max(c[0], max(c[1], c[2]))
  let mn = min(c[0], min(c[1], c[2]))
  if mx <= 0.0 or mx - mn <= 1e-9:
    return c
  let t = 1.0 - mn / mx
  let shape = t * (1.0 - t) * (2.0 - t + t * t) * mx * max(1.0 - mx, 0.0)
  var t2, v2: float64
  if v < 0.0:
    let a = -v
    t2 = t * (1.0 - a / 4.0) * (1.0 - a + a * t * (1.0 + t) / 2.0)
    v2 = mx - a * shape
  else:
    let w = vibranceSkin(vibranceHsvHue(c, mx, mn))
    let a = v * (1.0 - w) + 0.64 * pow(v, 1.6) * w
    let boost = exp((VibranceBoost[0] * a + VibranceBoost[1] * a * a) *
      pow(t, VibranceBoost[2]) * pow(1.0 - t, VibranceBoost[3]) *
      ((VibranceBoost[4] + VibranceBoost[5] * a +
        VibranceBoost[6] * (1.0 - t)) * max(1.0 - mx, 0.0)))
    t2 = min(t * (1.0 + boost), 1.0)
    v2 = mx + v / 4.0 * shape
  let m2 = v2 * (1.0 - t2)
  let k = (v2 - m2) / (mx - mn)
  [m2 + (c[0] - mn) * k, m2 + (c[1] - mn) * k, m2 + (c[2] - mn) * k]

type
  BalanceCurveNim* = tuple[b, w, e: float64, hasKnee: bool,
    u0, s0, kp, kd: float64]

proc balanceFinite(v: float32): float64 =
  ## Slider value clamped to its range, non-finite treated as zero.
  let x = float64(v)
  if x != x or x == Inf or x == NegInf: 0.0
  else: clamp(x, -100.0, 100.0)

proc balanceCurveFor*(shadows, midtones, highlights: array[3, float32],
    preserve: bool, ch: int): BalanceCurveNim =
  ## One channel's color balance curve: black/white points from the shadow and
  ## highlight sliders, a midtone gamma with a Hermite join above gamma 1.
  var sh, md, hl: array[3, float64]
  for i in 0 ..< 3:
    sh[i] = balanceFinite(shadows[i])
    md[i] = balanceFinite(midtones[i])
    hl[i] = balanceFinite(highlights[i])
  let (ownSh, ownMd, ownHl) = (sh[ch], md[ch], hl[ch])
  let (maxSh, maxMd) = (max(sh[0], max(sh[1], sh[2])), max(md[0], max(md[1], md[2])))
  let (minMd, minHl) = (min(md[0], min(md[1], md[2])), min(hl[0], min(hl[1], hl[2])))
  var black, white, m: float64
  if preserve:
    black = maxSh - ownSh
    white = ownHl - minHl
    m = ownMd - (maxMd + minMd) / 2.0
  else:
    black = max(-ownSh, 0.0)
    white = max(ownHl, 0.0)
    m = ownMd + (ownSh + ownHl) / 2.0
  let gamma = pow(2.0, m / 100.0)
  let e = 1.0 / max(gamma, 0.01)
  result = (b: black / 255.0, w: 1.0 - white / 255.0, e: e, hasKnee: false,
    u0: 0.0, s0: 0.0, kp: 0.0, kd: 0.0)
  if gamma > 1.0:
    let s0 = pow(2.0, gamma)
    let u0 = min(2.0 * pow(s0, 1.0 / (e - 1.0)), 1.0)
    if u0 == u0 and u0 > 0.0:
      result.hasKnee = true
      result.u0 = u0
      result.s0 = s0
      result.kp = pow(u0, e)
      result.kd = e * pow(u0, e - 1.0)

proc balanceEvalNim*(c: BalanceCurveNim, v: float64): float64 =
  ## The curve at one 0..1 sample.
  var vv = if v != v: 0.0 else: clamp(v, 0.0, 1.0)
  if vv >= c.w:
    return 1.0
  if vv <= c.b:
    return 0.0
  let u = (vv - c.b) / (c.w - c.b)
  if c.hasKnee and u < c.u0:
    let t = u / c.u0
    let (t2, t3) = (t * t, t * t * t)
    return clamp((t3 - 2.0 * t2 + t) * c.u0 * c.s0 +
      (3.0 * t2 - 2.0 * t3) * c.kp + (t3 - t2) * c.u0 * c.kd, 0.0, 1.0)
  pow(u, c.e)

const
  Bayer4 = [0.0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

proc bayer4Nim(x, y: int): float64 =
  ## Centered 4x4 Bayer offset, so dither adds no overall bias.
  (Bayer4[(y and 3) * 4 + (x and 3)] + 0.5) / 16.0 - 0.5

proc gradientSampleNim(stops: openArray[GradientStop],
    t: float64): array[3, float64] =
  ## Linear interpolation between stops, clamped outside the ends.
  if stops.len == 0:
    return [t, t, t]
  if stops.len == 1 or t <= stops[0].pos:
    return stops[0].rgb
  for i in 0 ..< stops.len - 1:
    if t <= stops[i + 1].pos:
      let k = if stops[i + 1].pos > stops[i].pos:
        (t - stops[i].pos) / (stops[i + 1].pos - stops[i].pos)
      else: 0.0
      let a = stops[i].rgb
      let b = stops[i + 1].rgb
      return [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k,
        a[2] + (b[2] - a[2]) * k]
  stops[^1].rgb

proc curvesTablesFor*(adj: Adjustment): CurvesTables =
  ## 8-bit RGB Curves tables: each channel snapped to a whole level, then the
  ## master at that level, as Photoshop does.
  var floats: array[4, array[256, float64]]
  floats[0] = curveTable256(adj.curvesChannels[0], adj.curvesPencil)
  floats[1] = curveTable256(adj.curvesChannels[1], adj.curvesPencil)
  floats[2] = curveTable256(adj.curvesChannels[2], adj.curvesPencil)
  floats[3] = curveTable256(adj.curvesMaster, adj.curvesPencil)
  for i in 0 ..< 3:
    for v in 0 ..< 256:
      result.ch[i][v] = clamp(int(round(floats[i][v] * 255.0)), 0, 255)
  for v in 0 ..< 256:
    result.master[v] = clamp(int(round(floats[3][v] * 255.0)), 0, 255)

proc adjustPixel*(adj: Adjustment, r, g, b: int): tuple[r, g, b: int] =
  ## One 8-bit RGB pixel through a supported adjustment. Callers check
  ## `isSupportedAdjustment` first; unsupported kinds return the pixel.
  ## Curves, photo filter, gradient map, color balance, hue/saturation and
  ## modern brightness/contrast need per-layer tables and run in
  ## `applyAdjustmentLayer` instead.
  case adj.kind
  of akInvert:
    (255 - r, 255 - g, 255 - b)
  of akThreshold:
    let t = round(float64(adj.threshold) * 255.0)
    let s = 30 * r + 59 * g + 11 * b
    if float64(s) > 100.0 * t - 50.0: (255, 255, 255) else: (0, 0, 0)
  of akPosterize:
    let n = max(2, min(int(adj.posterizeLevels), 255))
    let f = proc(v: int): int =
      var bin = (v * n) div 256
      if bin > n - 1: bin = n - 1
      (bin * 255) div (n - 1)
    (f(r), f(g), f(b))
  of akLevels:
    let f = proc(v: int, ch: LevelsChannel): int =
      let x = levelsChannelNim(ch, float64(v) / 255.0)
      clamp(int(round(levelsChannelNim(adj.levelsMaster, x) * 255.0)), 0, 255)
    (f(r, adj.levelsChannels[0]), f(g, adj.levelsChannels[1]),
      f(b, adj.levelsChannels[2]))
  of akBrightnessContrast:
    if not adj.bcLegacy:
      return (r, g, b)
    let bb = float64(adj.brightness) / 255.0
    let cc = clamp(float64(adj.contrast), -100.0, 99.0)
    let k = if cc >= 0.0: 1.0 / (1.0 - cc / 100.0) else: 1.0 + cc / 100.0
    let (pre, post) = if cc >= 0.0: (bb, 0.0) else: (0.0, bb)
    let f = proc(v: int): int =
      let x = ((float64(v) / 255.0 + pre - LegacyPivot) * k +
        LegacyPivot + post) * 255.0
      clamp(int(round(x)), 0, 255)
    (f(r), f(g), f(b))
  of akExposure:
    # Linear light through Gamma 2.2, the document tone curve Photoshop uses
    # for RGB exposure: (lin*2^exposure + offset)^(1/gamma), back to levels.
    let m = pow(2.0, float64(adj.exposure))
    let gam = max(float64(adj.gamma), 0.01)
    let f = proc(v: int): int =
      var lin = pow(float64(v) / 255.0, 2.2) * m + float64(adj.offset)
      if lin < 0.0:
        lin = 0.0
      if gam != 1.0:
        lin = pow(lin, 1.0 / gam)
      clamp(int(round(pow(lin, 1.0 / 2.2) * 255.0)), 0, 255)
    (f(r), f(g), f(b))
  of akChannelMixer:
    # Straight matrix on the channel levels: out = row.R*R + row.G*G +
    # row.B*B + const*255, clamped. Monochrome uses the first row thrice.
    let mx = adj.mixerMatrix
    let f = proc(v0, v1, v2, row: int): int =
      let m = mx[row]
      let x = float64(m[0]) * float64(v0) + float64(m[1]) * float64(v1) +
        float64(m[2]) * float64(v2) + float64(m[3]) * 255.0
      clamp(int(round(x)), 0, 255)
    if adj.mixerMono:
      let x = f(r, g, b, 0)
      (x, x, x)
    else:
      (f(r, g, b, 0), f(r, g, b, 1), f(r, g, b, 2))
  of akBlackWhite:
    # Weighted gray from the extreme and middle channels, then the tint's
    # hue and saturation at that gray's luminosity.
    let w = adj.bwWeights
    let mx = max(r, max(g, b))
    let mn = min(r, min(g, b))
    let md = r + g + b - mx - mn
    let p = if r >= g and r >= b: 0 elif g >= b: 2 else: 4
    let s = if b <= r and b <= g: 1 elif r <= g: 3 else: 5
    let gray = clamp((float64(mn) + float64(md - mn) * float64(w[s]) / 100.0 +
      float64(mx - md) * float64(w[p]) / 100.0) / 255.0, 0.0, 1.0)
    if adj.bwTint.isSome:
      let t = adj.bwTint.get()
      let tint = Rgba(
        r: uint8(clamp(int(round(t[0] * 255.0)), 0, 255)),
        g: uint8(clamp(int(round(t[1] * 255.0)), 0, 255)),
        b: uint8(clamp(int(round(t[2] * 255.0)), 0, 255)), a: 255)
      let o = setLum(tint, float32(gray * 255.0))
      (int(o.r), int(o.g), int(o.b))
    else:
      let v = clamp(int(round(gray * 255.0)), 0, 255)
      (v, v, v)
  of akSelectiveColor:
    # Each range shifts the inks (1 - R,G,B) by its percentages plus black,
    # weighted by how much the color belongs to the range. Relative scales
    # by the ink present; absolute by the room the ink has.
    let c = [float64(r) / 255.0, float64(g) / 255.0, float64(b) / 255.0]
    let mx = max(c[0], max(c[1], c[2]))
    let mn = min(c[0], min(c[1], c[2]))
    let md = c[0] + c[1] + c[2] - mx - mn
    let top = proc(i: int): float64 =
      if c[i] >= mx: mx - md else: 0.0
    let bot = proc(i: int): float64 =
      if c[i] <= mn: md - mn else: 0.0
    let w = [top(0), bot(2), top(1), bot(0), top(2), bot(1),
      max(0.0, (mn - 0.5) * 2.0),
      clamp(1.0 - abs(mx - 0.5) - abs(mn - 0.5), 0.0, 1.0),
      max(0.0, (0.5 - mx) * 2.0)]
    var o: array[3, int]
    for i in 0 ..< 3:
      let ink = 1.0 - c[i]
      var dd = 0.0
      for rr in 0 ..< 9:
        if w[rr] <= 0.0:
          continue
        let a = float64(adj.selAdjust[rr][i]) / 100.0 +
          float64(adj.selAdjust[rr][3]) / 100.0
        var d = a
        if adj.selRelative:
          d = d * ink
        elif d > 0.0:
          d = d * min(1.0, 2.0 * (1.0 - ink))
        else:
          d = d * min(1.0, 2.0 * ink)
        dd += d * w[rr]
      o[i] = clamp(int(round((c[i] - dd) * 255.0)), 0, 255)
    (o[0], o[1], o[2])
  of akVibrance:
    # Both sliders work in linear light through the sRGB tone curve:
    # Vibrance reshapes saturation and peak first, then Saturation moves
    # each channel away from the R/G grey.
    let vv = float64(adj.vibrance) / 100.0
    let ss = float64(adj.satBoost) / 100.0
    if vv == 0.0 and ss == 0.0:
      return (r, g, b)
    var lin = [srgbToLinearNim(float64(r) / 255.0),
      srgbToLinearNim(float64(g) / 255.0),
      srgbToLinearNim(float64(b) / 255.0)]
    if vv != 0.0:
      lin = vibranceLinNim(lin, vv)
    if ss != 0.0:
      let gr = VibranceGrey[0] * lin[0] + VibranceGrey[1] * lin[1]
      for i in 0 ..< 3:
        lin[i] = clamp(gr + (1.0 + ss) * (lin[i] - gr), 0.0, 1.0)
    (clamp(int(round(linearToSrgbNim(lin[0]) * 255.0)), 0, 255),
      clamp(int(round(linearToSrgbNim(lin[1]) * 255.0)), 0, 255),
      clamp(int(round(linearToSrgbNim(lin[2]) * 255.0)), 0, 255))
  else:
    (r, g, b)

proc isSupportedAdjustment*(adj: Adjustment): bool =
  ## Kinds `applyAdjustmentLayer` evaluates. Color lookup stays transparent:
  ## its profile payload carries no usable table data.
  case adj.kind
  of akInvert, akThreshold, akPosterize, akLevels, akCurves, akExposure,
     akChannelMixer, akBlackWhite, akPhotoFilter, akGradientMap,
     akColorBalance, akSelectiveColor, akHueSaturation, akVibrance,
     akBrightnessContrast: true
  else: false

proc compositeOver(dst: var Rgba, src: Rgba, mode: BlendMode, opacity,
    maskValue: int) =
  ## Source-over blend of one layer pixel onto the canvas.
  var sa = int(src.a) * opacity div 255
  if maskValue < 255:
    sa = sa * maskValue div 255
  if sa <= 0:
    return
  if dst.a == 0:
    # Nothing below: keep the source colour with its alpha, mirroring libpsd
    # rather than blending against black.
    dst = Rgba(r: src.r, g: src.g, b: src.b, a: uint8(sa))
    return
  let blended = blendRgb(mode, src, dst)
  var mix = sa
  if dst.a != 255:
    mix = sa * 255 div (sa + (255 - sa) * int(dst.a) div 255)
    dst.a = uint8(int(dst.a) + (255 - int(dst.a)) * sa div 255)
  dst.r = uint8(int(dst.r) + (int(blended.r) - int(dst.r)) * mix div 255)
  dst.g = uint8(int(dst.g) + (int(blended.g) - int(dst.g)) * mix div 255)
  dst.b = uint8(int(dst.b) + (int(blended.b) - int(dst.b)) * mix div 255)

type
  ClipBase = object
    has: bool
    rect: Rect
    img: ImageBuf

proc layerIndexOf(doc: Document, l: LayerRecord): int =
  ## Position of a layer record inside the document, matched on identity of
  ## its rect and name.
  let all = doc.layers()
  for i, cand in all:
    if cand.rect == l.rect and cand.name == l.name:
      return i
  -1

proc compositeBuffer(canvas: var ImageBuf, layer: ImageBuf, mode: BlendMode,
    opacity: int) =
  ## Blend a finished buffer onto the canvas as though it were one layer. Used
  ## for a group that has a blending mode of its own.
  if layer.isEmpty() or opacity <= 0:
    return
  for y in 0 ..< canvas.height:
    for x in 0 ..< canvas.width:
      let spx = layer.getPixel(x, y)
      if spx.a == 0:
        continue
      var dp = canvas.getPixel(x, y)
      compositeOver(dp, spx, mode, opacity, 255)
      canvas.setPixel(x, y, dp)

proc ramp(v: int, blackLo, blackHi, whiteLo, whiteHi: int): int =
  ## Coverage 0..255 of one Blend If quadruple.
  ##
  ## A quadruple is `(blackLo, blackHi, whiteLo, whiteHi)`. Below `blackLo`
  ## nothing passes; between the two blacks the result ramps up; between the two
  ## whites it ramps back down; above `whiteHi` nothing passes. Photoshop's
  ## default is `0, 0, 255, 255`, which is 255 everywhere, so a layer with no
  ## Blend If set costs one comparison per channel.
  if v < blackLo or v > whiteHi:
    return 0
  var t = 255
  # Rounded rather than truncated. Truncation biases every ramp downwards by up
  # to half a level, and the bias compounds when two ramps multiply.
  if blackHi > blackLo and v < blackHi:
    let span = blackHi - blackLo
    t = ((v - blackLo) * 255 + span div 2) div span
  elif whiteHi > whiteLo and v > whiteLo:
    let span = whiteHi - whiteLo
    t = ((whiteHi - v) * 255 + span div 2) div span
  t

proc isDefaultBlendIf*(ranges: seq[BlendRange]): bool =
  ## Whether the ranges are Photoshop's "no restriction" default, which lets the
  ## compositor skip Blend If entirely.
  for r in ranges:
    if r.source != [0'u8, 0'u8, 255'u8, 255'u8] or
        r.dest != [0'u8, 0'u8, 255'u8, 255'u8]:
      return false
  true

proc blendIfAt*(ranges: seq[BlendRange], compositeGray, srcValue,
    dstValue: int): int =
  ## Blend If coverage for one pixel, 0..255.
  ##
  ## Each record carries a *source* quadruple, applied to the backdrop value, and
  ## a *destination* quadruple, applied to the layer's own value. They multiply.
  ##
  ## The first record is the composite (grey) one; the rest are per channel, in
  ## colour plane order. Only as many per-channel records as the caller supplies
  ## are consulted, so an 8-bit grayscale document does not read past the end of
  ## a two-record list.
  if ranges.len == 0:
    return 255
  var cov = ramp(compositeGray, int(ranges[0].dest[0]), int(ranges[0].dest[1]),
    int(ranges[0].dest[2]), int(ranges[0].dest[3]))
  if cov == 0:
    return 0
  cov = cov * ramp(dstValue, int(ranges[0].source[0]), int(ranges[0].source[1]),
    int(ranges[0].source[2]), int(ranges[0].source[3])) div 255
  if cov == 0 or ranges.len < 2:
    return cov
  # The layer's own value against the destination quadruple of record 1, which
  # is the first colour channel's.
  cov = cov * ramp(srcValue, int(ranges[1].dest[0]), int(ranges[1].dest[1]),
    int(ranges[1].dest[2]), int(ranges[1].dest[3])) div 255
  if cov == 0 or ranges.len < 3:
    return cov
  cov = cov * ramp(dstValue, int(ranges[2].dest[0]), int(ranges[2].dest[1]),
    int(ranges[2].dest[2]), int(ranges[2].dest[3])) div 255
  cov

proc compositeGrayOf(px: Rgba): int {.inline.} =
  ## Photoshop's composite grey: the Rec. 709 luma of the pixel.
  (54 * int(px.r) + 183 * int(px.g) + 19 * int(px.b) + 128) div 256

proc blendLayerOnto(doc: Document, index: int, li: LayerImage,
    canvas: var ImageBuf, groupOpacity: int, base: ClipBase) =
  ## Composite one pixel layer over the canvas region it covers.
  ## `groupOpacity` folds ancestor folder opacity in. `li` is the already-decoded
  ## layer image, so the caller decodes each layer once rather than per use.
  let layer = doc.layers()[index]
  let opacity = layer.opacity * groupOpacity div 255
  if opacity <= 0 or li.img.isEmpty():
    return
  let mode = blendModeFromKey(layer.blendMode)
  if mode == bmPassThrough:
    return
  let dissolve = mode == bmDissolve
  # Built when *either* kind of mask is present. Gating this on a raster mask
  # alone left a vector mask parsed and rasterised but never consulted, which is
  # exactly the bug this wiring exists to fix.
  let mask = if layer.layerMask().isSome or layer.hasVectorMask:
               initMaskSampler(doc, index)
             else: MaskSampler()
  # Blend If ("Blend Using Blend If"), computed per pixel from the record's
  # blending ranges. A layer whose ranges are the Photoshop default pays one
  # comparison per channel and gets 255 back.
  let defaultRanges = layer.blendingRanges.ranges()
  let blendIf = if defaultRanges.len == 0 or isDefaultBlendIf(defaultRanges):
                  @[] else: defaultRanges
  let clipped = layer.clipping != 0
  let r = layer.rect
  let x0 = max(int(r.left), 0)
  let y0 = max(int(r.top), 0)
  let x1 = min(int(r.right), canvas.width)
  let y1 = min(int(r.bottom), canvas.height)
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      if clipped:
        if not base.has or x < int(base.rect.left) or
            x >= int(base.rect.right) or y < int(base.rect.top) or
            y >= int(base.rect.bottom):
          continue
        let bpx = base.img.getPixel(x - int(base.rect.left),
          y - int(base.rect.top))
        if bpx.a == 0:
          continue
      # Dissolve is resolved here rather than in the blend function: the pixels
      # it drops behave as though the layer were not there at all.
      if dissolve and not dissolveKeeps(x, y, opacity):
        continue
      let spx = li.img.getPixel(x - int(r.left), y - int(r.top))
      var mv = if mask.present: mask.sampleAt(x, y) else: 255
      if blendIf.len > 0:
        var dp0 = canvas.getPixel(x, y)
        let ifCov = blendIfAt(blendIf, compositeGrayOf(dp0),
          compositeGrayOf(spx), compositeGrayOf(dp0))
        mv = mv * ifCov div 255
        if mv == 0:
          continue
      var dp = canvas.getPixel(x, y)
      compositeOver(dp, spx, mode, opacity, mv)
      canvas.setPixel(x, y, dp)

proc applyAdjustmentLayer*(doc: Document, index: int, canvas: var ImageBuf,
    groupOpacity: int, base: ClipBase) =
  ## Transform the canvas through one adjustment layer, in place.
  let layer = doc.layers()[index]
  let opacity = layer.opacity * groupOpacity div 255
  if opacity <= 0 or canvas.isEmpty():
    return
  let adjOpt = adjustmentOf(layer)
  if adjOpt.isNone or not isSupportedAdjustment(adjOpt.get()):
    return
  let adj = adjOpt.get()
  var mode = blendModeFromKey(layer.blendMode)
  if mode == bmPassThrough:
    mode = bmNormal
  let isCurves = adj.kind == akCurves
  let curvesT = if isCurves: curvesTablesFor(adj) else: default(CurvesTables)
  let isPhoto = adj.kind == akPhotoFilter
  var photoM: array[3, array[3, float64]]
  if isPhoto:
    photoM = photoMatrixFor(adj)
  let isGradient = adj.kind == akGradientMap
  var gradStops: seq[GradientStop] = @[]
  if isGradient:
    # Photoshop writes stops sorted; normalize file order so sampling is a
    # plain segment walk, like the reference model.
    for s in adj.gradStops:
      gradStops.add((float64(s.pos),
        [float64(s.rgb[0]), float64(s.rgb[1]), float64(s.rgb[2])]))
    gradStops.sort(proc(a, b: GradientStop): int = cmp(a.pos, b.pos))
  let isBalance = adj.kind == akColorBalance
  var balT: array[3, BalanceCurveNim]
  if isBalance:
    for ch in 0 ..< 3:
      balT[ch] = balanceCurveFor(adj.cbShadows, adj.cbMidtones,
        adj.cbHighlights, adj.cbPreserve, ch)
  let isHueSat = adj.kind == akHueSaturation
  let hueT = if isHueSat: hueSatTablesFor(adj)
    else: default(HueSatTables)
  let isModernBc = adj.kind == akBrightnessContrast and not adj.bcLegacy
  var modernT: seq[float64] = @[]
  if isModernBc:
    modernT = modernLutNim(float64(adj.brightness), float64(adj.contrast))
  let dissolve = mode == bmDissolve
  let mask = if layer.layerMask().isSome or layer.hasVectorMask:
               initMaskSampler(doc, index)
             else: MaskSampler()
  let defaultRanges = layer.blendingRanges.ranges()
  let blendIf = if defaultRanges.len == 0 or isDefaultBlendIf(defaultRanges):
                  @[] else: defaultRanges
  let clipped = layer.clipping != 0
  for y in 0 ..< canvas.height:
    for x in 0 ..< canvas.width:
      if clipped:
        if not base.has or x < int(base.rect.left) or
            x >= int(base.rect.right) or y < int(base.rect.top) or
            y >= int(base.rect.bottom):
          continue
        let bpx = base.img.getPixel(x - int(base.rect.left),
          y - int(base.rect.top))
        if bpx.a == 0:
          continue
      if dissolve and not dissolveKeeps(x, y, opacity):
        continue
      var dp = canvas.getPixel(x, y)
      if dp.a == 0:
        continue
      var mv = if mask.present: mask.sampleAt(x, y) else: 255
      if blendIf.len > 0:
        let ifCov = blendIfAt(blendIf, compositeGrayOf(dp),
          compositeGrayOf(dp), compositeGrayOf(dp))
        mv = mv * ifCov div 255
        if mv == 0:
          continue
      let (ar, ag, ab) =
        if isCurves:
          (curvesT.master[curvesT.ch[0][int(dp.r)]],
           curvesT.master[curvesT.ch[1][int(dp.g)]],
           curvesT.master[curvesT.ch[2][int(dp.b)]])
        elif isPhoto:
          photoPixel(photoM, adj.pfPreserve, int(dp.r), int(dp.g), int(dp.b))
        elif isGradient:
          var t = (0.3 * float64(dp.r) + 0.59 * float64(dp.g) +
            0.11 * float64(dp.b)) / 255.0
          if adj.gradReverse:
            t = 1.0 - t
          var o = gradientSampleNim(gradStops, t)
          if adj.gradDither:
            let d = bayer4Nim(x, y) / 255.0
            o = [o[0] + d, o[1] + d, o[2] + d]
          (clamp(int(round(o[0] * 255.0)), 0, 255),
            clamp(int(round(o[1] * 255.0)), 0, 255),
            clamp(int(round(o[2] * 255.0)), 0, 255))
        elif isBalance:
          (clamp(int(round(balanceEvalNim(balT[0], float64(dp.r) / 255.0) * 255.0)), 0, 255),
            clamp(int(round(balanceEvalNim(balT[1], float64(dp.g) / 255.0) * 255.0)), 0, 255),
            clamp(int(round(balanceEvalNim(balT[2], float64(dp.b) / 255.0) * 255.0)), 0, 255))
        elif isHueSat:
          let c = [float64(dp.r) / 255.0, float64(dp.g) / 255.0,
            float64(dp.b) / 255.0]
          var dh, ds, dl = 0.0
          if hueT.hasRanges:
            let h0 = rgbToHslNim(c).h
            dh = hueSatLutNim(hueT.dh, h0)
            ds = hueSatLutNim(hueT.ds, h0)
            dl = hueSatLutNim(hueT.dl, h0)
          let s = clamp(float64(adj.saturation) / 100.0 + ds, -1.0, 1.0)
          let li = clamp(float64(adj.lightness) / 100.0, -1.0, 1.0)
          var o = hueSatPixelNim(c, float64(adj.hue) + dh, s, li,
            adj.hueColorize)
          let l = clamp(dl, -1.0, 1.0)
          let tgt =
            if l > 0.0: max(o[0], max(o[1], o[2]))
            else: min(o[0], min(o[1], o[2]))
          o = [o[0] + (tgt - o[0]) * abs(l), o[1] + (tgt - o[1]) * abs(l),
            o[2] + (tgt - o[2]) * abs(l)]
          (clamp(int(round(o[0] * 255.0)), 0, 255),
            clamp(int(round(o[1] * 255.0)), 0, 255),
            clamp(int(round(o[2] * 255.0)), 0, 255))
        elif isModernBc:
          # Same interpolation the reference LUT path uses at whole levels.
          (clamp(int(round(hueSatLutNim(modernT, float64(dp.r) / 255.0) * 255.0)), 0, 255),
            clamp(int(round(hueSatLutNim(modernT, float64(dp.g) / 255.0) * 255.0)), 0, 255),
            clamp(int(round(hueSatLutNim(modernT, float64(dp.b) / 255.0) * 255.0)), 0, 255))
        else:
          adjustPixel(adj, int(dp.r), int(dp.g), int(dp.b))
      var src = Rgba(r: uint8(ar), g: uint8(ag), b: uint8(ab), a: 255)
      compositeOver(dp, src, mode, opacity, mv)
      canvas.setPixel(x, y, dp)

# --- layer effects: drop shadows ------------------------------------------------
#
# Exterior effects paint behind the layer, from the layer's masked alpha:
# shifted by the offset, dilated by the spread, blurred by the size, then
# blended in the shadow's own color, mode and opacity. The layer paints over
# the result, which knocks the shadow out beneath opaque pixels; an explicit
# knock-out cut handles the translucent remainder for Normal layers.
# Contour, noise and global-light substitution stay future work: the stored
# angle is already resolved at write time, so static files render correctly.

proc effectBlendModeFromKey*(key: string): BlendMode =
  ## Map an effect `Md` key to a blend mode. Effect keys differ in case
  ## from layer keys ("Mltp" vs "mul "); unknown keys fall back to Normal.
  case key
  of "Nrml", "normal": bmNormal
  of "Dslv", "dissolve": bmDissolve
  of "Drkn", "darken": bmDarken
  of "Mltp", "multiply": bmMultiply
  of "CBrn", "colorBurn": bmColorBurn
  of "linearBurn": bmLinearBurn
  of "darkerColor": bmDarkerColor
  of "Lghn", "lighten": bmLighten
  of "Scrn", "screen": bmScreen
  of "CDdg", "colorDodge": bmColorDodge
  of "linearDodge": bmLinearDodge
  of "lighterColor": bmLighterColor
  of "Ovrl", "overlay": bmOverlay
  of "SftL", "softLight": bmSoftLight
  of "HrdL", "hardLight": bmHardLight
  of "vividLight": bmVividLight
  of "linearLight": bmLinearLight
  of "pinLight": bmPinLight
  of "hardMix": bmHardMix
  of "Dfrn", "difference": bmDifference
  of "Xclu", "exclusion": bmExclusion
  of "blendSubtraction": bmSubtract
  of "blendDivide": bmDivide
  of "H   ", "hue": bmHue
  of "Strt", "saturation": bmSaturation
  of "Clr ", "color": bmColor
  of "Lmns", "luminosity": bmLuminosity
  else: bmNormal

proc boxWeightsNim(w: float64): seq[float64] =
  ## Normalized weights of a centered fractional-width box: tap `i` gets
  ## the overlap of `[i-1/2, i+1/2]` with `[-w/2, w/2]`.
  var ww = if w != w: 1.0 else: clamp(w, 1.0, 512.0)
  let half = ww / 2.0
  let r = max(int(ceil(half - 0.5)), 0)
  var sum = 0.0
  for i in -r .. r:
    let v = max(min(float64(i) + 0.5, half) - max(float64(i) - 0.5, -half),
      0.0)
    result.add(v)
    sum += v
  for k in 0 ..< result.len:
    result[k] /= sum

proc tentKernelNim*(w: float64): tuple[radius: int, taps: seq[float64]] =
  ## Two box passes make a tent: the kernel is the box convolved with
  ## itself. Width 1 is the identity (radius 0).
  let b = boxWeightsNim(w)
  var t = newSeq[float64](b.len * 2 - 1)
  for i, x in b:
    for j, y in b:
      t[i + j] += x * y
  ((t.len - 1) div 2, t)

proc blurPlaneNim*(plane: var seq[float64], w, h: int, size: float64) =
  ## Two separable box passes (a tent), zero outside the plane.
  let (radius, taps) = tentKernelNim(size)
  if radius == 0 or plane.len == 0: return
  var tmp = newSeq[float64](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var acc = 0.0
      for i, kv in taps:
        let xx = x + i - radius
        if xx >= 0 and xx < w: acc += plane[y * w + xx] * kv
      tmp[y * w + x] = acc
  for x in 0 ..< w:
    for y in 0 ..< h:
      var acc = 0.0
      for i, kv in taps:
        let yy = y + i - radius
        if yy >= 0 and yy < h: acc += tmp[yy * w + x] * kv
      plane[y * w + x] = acc

proc dilatePlaneNim*(plane: var seq[float64], w, h: int, radius: int) =
  ## Box max-filter dilation, separable row then column passes. The plane is
  ## zero past the effect's reach, so clamped edges match zero-fill.
  if radius <= 0 or plane.len == 0: return
  var tmp = newSeq[float64](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var m = 0.0
      for dx in -radius .. radius:
        m = max(m, plane[y * w + clamp(x + dx, 0, w - 1)])
      tmp[y * w + x] = m
  for x in 0 ..< w:
    for y in 0 ..< h:
      var m = 0.0
      for dy in -radius .. radius:
        m = max(m, tmp[clamp(y + dy, 0, h - 1) * w + x])
      plane[y * w + x] = m

proc shadowOffsetNim*(angleDeg, dist: float64): tuple[dx, dy: int] =
  ## Integer pixel offset of a distance at an angle in degrees.
  let a = angleDeg * PI / 180.0
  (int(round(-cos(a) * dist)), int(round(sin(a) * dist)))

proc applyDropShadows*(doc: Document, index: int, li: LayerImage,
    canvas: var ImageBuf, groupOpacity: int, base: ClipBase) =
  ## Paint enabled drop shadows behind one layer, bottom of the stack first.
  let layer = doc.layers()[index]
  let fx = effectsOf(layer)
  if fx.isNone or not fx.get().master: return
  let opacity = layer.opacity * groupOpacity div 255
  if opacity <= 0 or canvas.isEmpty(): return
  let liw = li.img.width
  let lih = li.img.height
  if liw <= 0 or lih <= 0: return
  let r = layer.rect
  let mask = if layer.layerMask().isSome or layer.hasVectorMask:
               initMaskSampler(doc, index)
             else: MaskSampler()
  let clipped = layer.clipping != 0
  let layerMode = blendModeFromKey(layer.blendMode)
  let effects = fx.get().effects
  for i in countdown(effects.high, 0):
    let e = effects[i]
    if e.kind != ekDropShadow or not e.common.enabled: continue
    let (dx, dy) = shadowOffsetNim(float64(e.angle), float64(e.distance))
    let spreadR = int(round(float64(e.size) * float64(e.spread)))
    let blurW = float64(e.size) * (1.0 - float64(e.spread))
    let (blurR, _) = tentKernelNim(blurW)
    let m = abs(dx) + abs(dy) + spreadR + blurR + 2
    let x0 = max(int(r.left) - m, 0)
    let y0 = max(int(r.top) - m, 0)
    let x1 = min(int(r.right) + m, canvas.width)
    let y1 = min(int(r.bottom) + m, canvas.height)
    if x1 <= x0 or y1 <= y0: continue
    let pw = x1 - x0
    let ph = y1 - y0
    var plane = newSeq[float64](pw * ph)
    for y in y0 ..< y1:
      for x in x0 ..< x1:
        let sx = x - dx
        let sy = y - dy
        if sx < int(r.left) or sx >= int(r.right) or sy < int(r.top) or
            sy >= int(r.bottom):
          continue
        let a = int(li.img.getPixel(sx - int(r.left), sy - int(r.top)).a)
        if a <= 0: continue
        var mv = 255
        if mask.present: mv = mask.sampleAt(sx, sy)
        if mv <= 0: continue
        plane[(y - y0) * pw + (x - x0)] =
          float64(a) * float64(mv) / (255.0 * 255.0)
    dilatePlaneNim(plane, pw, ph, spreadR)
    blurPlaneNim(plane, pw, ph, blurW)
    if e.knocksOut and layerMode in {bmNormal, bmDissolve, bmPassThrough}:
      # Fill is always opaque here, so a Normal layer knocks the shadow out
      # wholly beneath its shape; other modes blend with it, shadow and all.
      for y in y0 ..< y1:
        for x in x0 ..< x1:
          var s = 0.0
          if x >= int(r.left) and x < int(r.right) and y >= int(r.top) and
              y < int(r.bottom):
            let a = int(li.img.getPixel(x - int(r.left), y - int(r.top)).a)
            if a > 0:
              var mv = 255
              if mask.present: mv = mask.sampleAt(x, y)
              s = float64(a) * float64(mv) / (255.0 * 255.0)
          plane[(y - y0) * pw + (x - x0)] *= 1.0 - s
    let smode = effectBlendModeFromKey(e.common.blend)
    let dissolve = smode == bmDissolve
    let sr = uint8(clamp(int(round(float64(e.color[0]))), 0, 255))
    let sg = uint8(clamp(int(round(float64(e.color[1]))), 0, 255))
    let sb = uint8(clamp(int(round(float64(e.color[2]))), 0, 255))
    for y in y0 ..< y1:
      for x in x0 ..< x1:
        let cov = plane[(y - y0) * pw + (x - x0)]
        if cov <= 0.0: continue
        if clipped:
          if not base.has or x < int(base.rect.left) or
              x >= int(base.rect.right) or y < int(base.rect.top) or
              y >= int(base.rect.bottom):
            continue
          let bpx = base.img.getPixel(x - int(base.rect.left),
            y - int(base.rect.top))
          if bpx.a == 0: continue
        if dissolve and not dissolveKeeps(x, y, opacity): continue
        let op = clamp(int(round(cov * float64(e.common.opacity) *
          float64(opacity))), 0, 255)
        if op <= 0: continue
        var dp = canvas.getPixel(x, y)
        var src = Rgba(r: sr, g: sg, b: sb, a: 255)
        compositeOver(dp, src, smode, op, 255)
        canvas.setPixel(x, y, dp)

proc groupIsIsolated(l: LayerRecord): bool =
  ## Whether a group's children are composited as a unit rather than blended
  ## straight into the backdrop beneath the group.
  ##
  ## Two things force isolation, and missing either changes the render. A blend
  ## mode other than pass through obviously does. So does an explicit `iSO`
  ## block, which is the one a blend-key test alone misses: Photoshop writes
  ## `iSO` on a group whose blend mode is still `pass`, so "pass through"
  ## cannot be decided from the mode alone. Without this such a group leaked its
  ## children into the backdrop.
  if blendModeFromKey(l.blendMode) != bmPassThrough:
    return true
  let b = l.getBlock("iSO")
  if b.isSome:
    let d = b.get().parsed()
    if d.isSome and d.get().kind == bdIsolationOverride:
      return d.get().isolated
  false

proc renderSiblings(doc: Document, nodes: seq[LayerNode], canvas: var ImageBuf,
    groupOpacity: int) =
  ## File order is bottom-first, so one pass blends correctly. Tracks the last
  ## unclipped pixel layer as the clip base for following clipped layers.
  var base = ClipBase()
  for n in nodes:
    if n.layer.isDivider() or not n.layer.isVisible():
      continue
    if n.kind == lnGroup:
      let own = n.layer.opacity
      if not groupIsIsolated(n.layer):
        # Pass-through: the children blend straight into the backdrop, so the
        # group's opacity folds into each of them.
        renderSiblings(doc, n.children, canvas, groupOpacity * own div 255)
      else:
        # A blending group is isolated: render its children onto their own
        # canvas, then blend the result as a single layer. This costs a
        # full-canvas buffer, which is why pass-through is the default and the
        # common case.
        var iso = initImageBuf(canvas.width, canvas.height,
          Rgba(r: 0, g: 0, b: 0, a: 0))
        if not iso.isEmpty():
          renderSiblings(doc, n.children, iso, 255)
          compositeBuffer(canvas, iso, blendModeFromKey(n.layer.blendMode),
            own * groupOpacity div 255)
    else:
      let idx = layerIndexOf(doc, n.layer)
      if idx < 0:
        continue
      if n.layer.isAdjustmentLayer():
        applyAdjustmentLayer(doc, idx, canvas, groupOpacity, base)
        continue
      let li = doc.layerImage(idx)
      applyDropShadows(doc, idx, li, canvas, groupOpacity, base)
      blendLayerOnto(doc, idx, li, canvas, groupOpacity, base)
      if n.layer.clipping == 0 and not li.img.isEmpty():
        base = ClipBase(has: true, rect: n.layer.rect, img: li.img)

proc renderDocument*(doc: Document): ImageBuf =
  ## Render the layer stack to a canvas the size of the document, starting
  ## transparent. Invisible layers and group markers contribute nothing; group
  ## opacity folds into descendants, and a group with its own blend mode is
  ## composited as one layer.
  result = initImageBuf(doc.width, doc.height,
    Rgba(r: 0, g: 0, b: 0, a: 0))
  if result.isEmpty():
    return
  renderSiblings(doc, doc.layerTree(), result, 255)

proc renderToComposite*(doc: var Document) =
  ## Replace the stored flattened composite with a fresh render. Useful when
  ## the file has none or it cannot be trusted.
  doc.composite = renderDocument(doc)
  doc.hasComposite = not doc.composite.isEmpty()