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

import std/math
import std/options

import ./document
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
      let li = doc.layerImage(idx)
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