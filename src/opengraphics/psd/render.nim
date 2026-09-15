## Layer-stack renderer: composite the layer stack into an ImageBuf
## without relying on the stored flattened composite.
##
## Behavior reference (clean-room reimplementation, no copied code):
## libpsd src/blend.c psd_layer_blend for stacking order, opacity and
## mask handling; per-channel blend math follows the standard
## W3C Compositing and Blending Level 1 definitions with integer
## arithmetic. Deliberate v1 simplifications, all documented below:
## - Unknown / HSL (hue, sat, color, luminosity) / dissolve modes fall
##   back to normal. Groups render pass-through (divider blend ignored).
## - Clipped layers paint only where the base layer below has content
##   (canvas-shape approximation of clipping groups).
## - Mask `invert` IS applied (libpsd parses but ignores it); mask
##   coordinates are used as stored, like libpsd (no `relative` shift).

import ./types
import ./pixels
import ./layers
import ./document

type
  BlendMode* {.pure.} = enum
    Normal = 0
    Darken
    Multiply
    ColorBurn
    LinearBurn
    Lighten
    Screen
    ColorDodge
    LinearDodge
    Overlay
    SoftLight
    HardLight
    VividLight
    LinearLight
    PinLight
    HardMix
    Difference
    Exclusion
    Subtract
    Divide

proc blendModeFromKey*(key: string): BlendMode =
  ## Map a 4-char Photoshop blend key to a mode. Anything unlisted
  ## (dissolve, hue/sat/color/luminosity, pass-through, future keys)
  ## falls back to Normal.
  case key
  of "norm": Normal
  of "dark": Darken
  of "mul ": Multiply
  of "idiv": ColorBurn
  of "lbrn": LinearBurn
  of "lite": Lighten
  of "scrn": Screen
  of "div ": ColorDodge
  of "lddg": LinearDodge
  of "over": Overlay
  of "sLit": SoftLight
  of "hLit": HardLight
  of "vLit": VividLight
  of "lLit": LinearLight
  of "pLit": PinLight
  of "hMix": HardMix
  of "diff": Difference
  of "smud": Exclusion
  of "fsub": Subtract
  of "fdiv": Divide
  else: Normal

proc blendChannel*(mode: BlendMode, src, dst: int): int =
  ## Blend one channel (src = layer, dst = canvas), 0..255 in and out.
  ## Pure, so unit tests can pin every formula.
  case mode
  of Normal: src
  of Darken: min(src, dst)
  of Multiply: src * dst div 255
  of ColorBurn:
    if src == 0: 0
    else: max(0, 255 - (255 - dst) * 255 div src)
  of LinearBurn: max(0, src + dst - 255)
  of Lighten: max(src, dst)
  of Screen: 255 - (255 - src) * (255 - dst) div 255
  of ColorDodge:
    if src == 255: 255
    else: min(255, dst * 255 div (255 - src))
  of LinearDodge: min(255, src + dst)
  of Overlay:
    if dst < 128: 2 * src * dst div 255
    else: 255 - 2 * (255 - src) * (255 - dst) div 255
  of SoftLight:
    let c1 = src * dst div 255
    let c2 = 255 - (255 - src) * (255 - dst) div 255
    (255 - dst) * c1 div 255 + dst * c2 div 255
  of HardLight:
    if src < 128: 2 * src * dst div 255
    else: 255 - 2 * (255 - src) * (255 - dst) div 255
  of VividLight:
    if src < 128:
      if src == 0: 0
      else: max(0, 255 - (255 - dst) * 255 div (2 * src))
    else:
      if src == 255: 255
      else: min(255, dst * 255 div (2 * (255 - src)))
  of LinearLight: min(255, max(0, dst + 2 * src - 255))
  of PinLight:
    if src >= 128: max(dst, 2 * (src - 128))
    else: min(dst, 2 * src)
  of HardMix:
    if src + dst <= 255: 0 else: 255
  of Difference: abs(dst - src)
  of Exclusion: dst + src - 2 * dst * src div 255
  of Subtract: max(0, dst - src)
  of Divide:
    if src == 0: 255
    else: min(255, dst * 255 div src)

proc maskValueAt(l: Layer, x, y: int): int =
  ## Mask contribution 0..255 at canvas coords. The -2 channel is
  ## sampled inside the mask rect; outside it the default color fills
  ## in. A present mask without decoded pixels (skip mode) also falls
  ## back to the default color.
  let m = l.mask
  var v =
    if x >= m.left and x < m.right and y >= m.top and y < m.bottom:
      let md = l.maskData()
      if md.len == m.maskWidth() * m.maskHeight() and
          m.maskWidth() > 0 and m.maskHeight() > 0:
        int(md[(y - int(m.top)) * m.maskWidth() + (x - int(m.left))])
      else:
        int(m.defaultColor)
    else:
      int(m.defaultColor)
  if m.invert:
    v = 255 - v
  v

proc compositeOver(dst: var Rgba, src: Rgba, mode: BlendMode,
    opacity, maskValue: int) =
  ## Source-over blend of one layer pixel onto the canvas.
  var sa = int(src.a) * opacity div 255
  if maskValue < 255:
    sa = sa * maskValue div 255
  if sa <= 0:
    return
  if dst.a == 0:
    # Nothing below: keep the source color with its alpha,
    # mirroring libpsd (no blending against black).
    dst = Rgba(r: src.r, g: src.g, b: src.b, a: uint8(sa))
    return
  var mix = sa
  if dst.a != 255:
    mix = sa * 255 div (sa + (255 - sa) * int(dst.a) div 255)
    dst.a = uint8(int(dst.a) + (255 - int(dst.a)) * sa div 255)
  dst.r = uint8(int(dst.r) + (blendChannel(mode, int(src.r), int(dst.r)) -
    int(dst.r)) * mix div 255)
  dst.g = uint8(int(dst.g) + (blendChannel(mode, int(src.g), int(dst.g)) -
    int(dst.g)) * mix div 255)
  dst.b = uint8(int(dst.b) + (blendChannel(mode, int(src.b), int(dst.b)) -
    int(dst.b)) * mix div 255)

type
  ClipBase = object
    has: bool
    left, top, right, bottom: int32
    img: ImageBuf

proc blendLayerOnto(l: Layer, img: ImageBuf, canvas: var ImageBuf,
    groupOpacity: int, base: ClipBase) =
  ## Composite one pixel layer over the canvas region it covers.
  ## `groupOpacity` folds ancestor folder opacity in (libpsd multiplies
  ## group opacity into each child). Clipped layers (clipping != 0)
  ## only paint where `base` has content.
  if img.isEmpty():
    return
  let opacity = int(l.opacity) * groupOpacity div 255
  if opacity <= 0:
    return
  let mode = blendModeFromKey(l.blendKey)
  let useMask = l.maskEnabled()
  let clipped = l.clipping != 0
  let x0 = max(int(l.left), 0)
  let y0 = max(int(l.top), 0)
  let x1 = min(int(l.right), canvas.width)
  let y1 = min(int(l.bottom), canvas.height)
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      if clipped:
        if not base.has or x < base.left or x >= base.right or
            y < base.top or y >= base.bottom:
          continue
        let bpx = base.img.getPixel(x - int(base.left), y - int(base.top))
        if bpx.a == 0:
          continue
      let spx = img.getPixel(x - int(l.left), y - int(l.top))
      let mv = if useMask: maskValueAt(l, x, y) else: 255
      var dp = canvas.getPixel(x, y)
      compositeOver(dp, spx, mode, opacity, mv)
      canvas.setPixel(x, y, dp)

proc renderSiblings(nodes: seq[LayerNode], canvas: var ImageBuf,
    groupOpacity: int) =
  ## File order is bottom-first, so a single pass blends correctly.
  ## Tracks the last unclipped pixel layer as the clip base for
  ## following clipped (`clipping != 0`) layers.
  var base = ClipBase()
  for n in nodes:
    if not n.layer.isVisible():
      continue
    if n.isGroup:
      let go = groupOpacity * int(n.layer.opacity) div 255
      renderSiblings(n.children, canvas, go)
    else:
      if n.layer.kind != Pixel:
        continue
      let img = n.layer.layerPixelsToImage()
      blendLayerOnto(n.layer, img, canvas, groupOpacity, base)
      if n.layer.clipping == 0 and not img.isEmpty():
        base = ClipBase(has: true, left: n.layer.left, top: n.layer.top,
          right: n.layer.right, bottom: n.layer.bottom, img: img)

proc renderDocument*(doc: Document): ImageBuf =
  ## Render the layer stack to a canvas the size of the document.
  ## Starts transparent; invisible layers, folders/dividers and empty
  ## layers contribute nothing. Group opacity folds into descendants.
  result = initImageBuf(doc.width, doc.height,
    Rgba(r: 0, g: 0, b: 0, a: 0))
  if result.isEmpty():
    return
  renderSiblings(doc.layerTree(), result, 255)

proc renderToComposite*(doc: var Document) =
  ## Replace the stored flattened composite with a fresh render.
  ## Useful when the file has no composite or it is untrusted.
  doc.composite = renderDocument(doc)
  doc.hasComposite = not doc.composite.isEmpty()
  doc.compositeCompression = Raw
