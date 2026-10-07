## PDF content streams to vector artwork.
##
## Folds the resource-aware `WalkedOp` sequences from opendocs into
## `VecDocument`: path construction and painting, solid paints, axial and
## radial shadings, clipping paths, placed-image references, and text
## placeholders. Each page becomes one artboard and one layer.
##
## Two coordinate facts matter. PDF user space is y-up; the vector model
## is y-down, so every painted path is transformed by the op's CTM
## composed with a page-height flip, at paint time. And colors, line
## parameters, and the current path are per-graphics-state: this walker
## keeps its own fold state because `WalkedOp` carries the CTM and
## resources but not the paint state.
##
## Honest limits, all warned per document: text runs carry decoded
## strings, origins, size and font, but glyph-level layout (shaping,
## render modes) is not modeled; images keep their resource name and
## placement, not their pixels; shading functions beyond exponential
## are sampled; tiling patterns keep their name, not their tile; `gs`
## graphics parameters are not applied.

import std/math
import std/options
import std/tables
import opendocs/pdf/cos
import opendocs/pdf/docmodel
import opendocs/pdf/gstate
import opendocs/pdf/text
import opendocs/pdf/types
import ../vector
import ./pdfcompat
import ./shape
import ./types

export vector

type
  ClipEntry = object
    depth*: int
    path*: VecPath
    rule*: VecFillRule

  SavedPaint = object
    ## Nonstroking and stroking paint state saved across `q`/`Q`,
    ## mirroring the PDF graphics state my fold would otherwise leak.
    fill*: VecPaint
    stroke*: VecStroke
    hasStroke*: bool
    fillSpace*: VecColorSpace
    strokeSpace*: VecColorSpace
    fillCSName*: string
    strokeCSName*: string

  FoldState = object
    subs*: seq[VecSubPath] ## finished subpaths of the current path
    open*: VecSubPath      ## subpath under construction
    hasOpen*: bool
    pendingClip*: bool
    pendingRule*: VecFillRule
    fill*: VecPaint
    stroke*: VecStroke
    hasStroke*: bool
    fillSpace*: VecColorSpace
    strokeSpace*: VecColorSpace
    fillCSName*: string
    strokeCSName*: string
    saved*: seq[SavedPaint]
    clips*: seq[ClipEntry]
    depth*: int
    fontBytes*: Table[string, string]
      ## Embedded programs by "depth/fontName", resolved once per font.
    fonts*: Table[string, ShapedFont]
      ## Open faces by the same key; closed when the page fold ends.
      ## Entries are pointer owners: never close a copy, only the table.
    deadFonts*: Table[string, bool]
      ## Fonts already reported unshapable, so each warns once.

proc flipFor*(pageH: float64): VecXform =
  ## PDF y-up to model y-down for a page of height `pageH`.
  [1.0, 0.0, 0.0, -1.0, 0.0, pageH]

proc deviceXform*(ctm: VecXform, pageH: float64): VecXform =
  ## User space to model space: flip after the op's CTM.
  concatXform(flipFor(pageH), ctm)

proc num(op: ContentOp, i: int): float64 =
  if i < op.operands.len:
    case op.operands[i].kind
    of coInt: float64(op.operands[i].ival)
    of coFloat: op.operands[i].fval
    else: raise newException(AiError,
      "operator " & op.name & " needs numbers")
  else:
    raise newException(AiError,
      "operator " & op.name & " needs more operands")

proc nameOp(op: ContentOp, i: int): string =
  if i < op.operands.len and op.operands[i].kind == coName:
    op.operands[i].name
  else:
    raise newException(AiError,
      "operator " & op.name & " needs a name")

proc takePath(st: var FoldState): VecPath =
  ## The finished current path, consuming it.
  result = VecPath(subs: st.subs, fillRule: vfrNonZero)
  if st.hasOpen and st.open.anchors.len > 0:
    result.subs.add(st.open)
  st.subs = @[]
  st.open = VecSubPath()
  st.hasOpen = false

proc snapshotPath(st: FoldState): VecPath =
  result = VecPath(subs: st.subs, fillRule: vfrNonZero)
  if st.hasOpen and st.open.anchors.len > 0:
    result.subs.add(st.open)

proc clearPath(st: var FoldState) =
  st.subs = @[]
  st.open = VecSubPath()
  st.hasOpen = false

proc ensureOpen(st: var FoldState, p: VecPt) =
  if not st.hasOpen:
    st.open = VecSubPath()
    moveTo(st.open, p)
    st.hasOpen = true

proc closeOpen(st: var FoldState) =
  if st.hasOpen:
    st.open.closed = true
    st.subs.add(st.open)
    st.open = VecSubPath()
    st.hasOpen = false

proc activateClip(st: var FoldState, rule: VecFillRule, ctm: VecXform,
    pageH: float64) =
  ## The `W`/`W*` path becomes an active clip at the current save depth.
  let m = deviceXform(ctm, pageH)
  st.clips.add(ClipEntry(depth: st.depth,
    path: transformPath(snapshotPath(st), m), rule: rule))
  clearPath(st)

proc dropClipsTo(st: var FoldState, depth: int) =
  var kept: seq[ClipEntry] = @[]
  for c in st.clips:
    if c.depth <= depth: kept.add(c)
  st.clips = kept

proc wrapClips(node: VecNode, st: FoldState,
    opacity: float64): VecNode =
  ## Nest `node` inside the active clip groups, innermost last.
  result = node
  for i in countdown(st.clips.len - 1, 0):
    let c = st.clips[i]
    result = VecNode(kind: vnkClip, name: "", opacity: opacity,
      xform: identityXform(), clip: c.path, clipRule: c.rule,
      clipped: @[result])

proc paintColorSpace(cs: CosObj): tuple[space: VecColorSpace, ok: bool] =
  if cs.kind != coName:
    return (vcsRGB, false)
  case cs.name
  of "DeviceGray", "G": (vcsGray, true)
  of "DeviceRGB", "RGB": (vcsRGB, true)
  of "DeviceCMYK", "CMYK": (vcsCMYK, true)
  else: (vcsRGB, false)

proc colorOperands(op: ContentOp, n: int,
    space: VecColorSpace): VecColor =
  case space
  of vcsGray: grayColor(num(op, 0))
  of vcsRGB: rgbColor(num(op, 0), num(op, 1), num(op, 2))
  of vcsCMYK: cmykColor(num(op, 0), num(op, 1), num(op, 2), num(op, 3))

proc shadingColor(cs: CosObj, vals: seq[float64]): VecColor =
  ## A shading sample value to a color. Only device spaces map;
  ## anything else is the caller's warning, not a guess.
  let (space, ok) = paintColorSpace(cs)
  if not ok:
    raise newException(AiError, "unsupported shading color space")
  case space
  of vcsGray: grayColor(vals[0])
  of vcsRGB: rgbColor(vals[0], vals[1], vals[2])
  of vcsCMYK: cmykColor(vals[0], vals[1], vals[2], vals[3])

proc sampleFunction(fn: CosObj, t: float64,
    doc: var VecDocument): seq[float64] =
  ## A shading function at `t` in 0..1. Type 2 exponentials are exact;
  ## stitching and sampled functions are sampled with a warning.
  let typ = fn.dictGet("FunctionType")
  if typ.kind == coInt and typ.ival == 2:
    let c0 = fn.dictGet("C0")
    let c1 = fn.dictGet("C1")
    let n = fn.dictGet("N")
    let nv = if n.kind in {coInt, coFloat}: (if n.kind == coInt:
      float64(n.ival) else: n.fval) else: 1.0
    proc chan(i: int): float64 =
      let a = if c0.kind == coArray and i < c0.items.len:
        (if c0.items[i].kind == coInt: float64(c0.items[i].ival)
         elif c0.items[i].kind == coFloat: c0.items[i].fval else: 0.0)
        else: 0.0
      let b = if c1.kind == coArray and i < c1.items.len:
        (if c1.items[i].kind == coInt: float64(c1.items[i].ival)
         elif c1.items[i].kind == coFloat: c1.items[i].fval else: 1.0)
        else: 1.0
      a + pow(t, nv) * (b - a)
    let nOut = if c1.kind == coArray: c1.items.len
      elif c0.kind == coArray: c0.items.len else: 1
    for i in 0 ..< max(nOut, 1): result.add(chan(i))
    return
  doc.warn("shading function type " &
    (if typ.kind == coInt: $typ.ival else: "?") &
    " is sampled, not evaluated exactly")
  result = @[t]

proc shadingGradient(d: var PdfDoc, sh: CosObj,
    doc: var VecDocument): VecGradient =
  ## A PDF shading dictionary to a gradient in shading space.
  let st = sh.dictGet("ShadingType")
  if st.kind != coInt or (st.ival != 2 and st.ival != 3):
    raise newException(AiError,
      "only axial and radial shadings map to gradients")
  var coords = sh.dictGet("Coords")
  if coords.kind == coRef:
    coords = d.resolve(coords)
  if coords.kind != coArray or coords.items.len < 4:
    raise newException(AiError, "shading has no usable Coords")
  proc cn(i: int): float64 =
    if coords.items[i].kind == coInt: float64(coords.items[i].ival)
    elif coords.items[i].kind == coFloat: coords.items[i].fval
    else: raise newException(AiError, "bad shading Coords")
  let cs = sh.dictGet("ColorSpace")
  var fn = sh.dictGet("Function")
  if fn.kind == coRef:
    fn = d.resolve(fn)
  if fn.kind == coNull:
    raise newException(AiError, "shading has no Function")
  var stops: seq[VecGradientStop] = @[]
  for i in 0 .. 8:
    let t = float64(i) / 8.0
    try:
      stops.add(VecGradientStop(offset: t,
        color: shadingColor(cs, sampleFunction(fn, t, doc))))
    except AiError as e:
      raise newException(AiError,
        "shading color failed: " & e.msg)
  let extend = sh.dictGet("Extend")
  if extend.kind == coArray and extend.items.len == 2:
    doc.warn("shading Extend is not modeled; the gradient pads")
  if st.ival == 2:
    VecGradient(kind: vgkLinear, stops: stops,
      xform: identityXform(), objectBoundingBox: false, spread: vspPad,
      x0: cn(0), y0: cn(1), x1: cn(2), y1: cn(3))
  else:
    if coords.items.len < 6:
      raise newException(AiError, "radial shading needs 6 Coords")
    if cn(2) > 1e-9:
      doc.warn("radial shading with a non-point inner circle " &
        "keeps only its center as the focal point")
    VecGradient(kind: vgkRadial, stops: stops,
      xform: identityXform(), objectBoundingBox: false, spread: vspPad,
      cx: cn(3), cy: cn(4), r: cn(5), fx: cn(0), fy: cn(1))

proc savePaint(st: var FoldState) =
  st.saved.add(SavedPaint(fill: st.fill, stroke: st.stroke,
    hasStroke: st.hasStroke, fillSpace: st.fillSpace,
    strokeSpace: st.strokeSpace, fillCSName: st.fillCSName,
    strokeCSName: st.strokeCSName))

proc restorePaint(st: var FoldState) =
  if st.saved.len == 0: return
  let s = st.saved[^1]
  st.saved.setLen(st.saved.len - 1)
  st.fill = s.fill
  st.stroke = s.stroke
  st.hasStroke = s.hasStroke
  st.fillSpace = s.fillSpace
  st.strokeSpace = s.strokeSpace
  st.fillCSName = s.fillCSName
  st.strokeCSName = s.strokeCSName

proc fontDictFor(d: var PdfDoc, res: CosObj,
    name: string): CosObj =
  ## The font dictionary for `name` in resource frame `res`, mirroring
  ## the lookup inside opendocs `decoderFor` so shaping sees the same
  ## font the decoder saw — including a form's shadowed `/F1`.
  var fonts = res.dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  if fonts.kind != coDict:
    return CosObj(kind: coNull)
  var r = fonts.dictGet(name)
  if r.kind == coRef:
    r = d.resolve(r)
  r

proc fontKeyFor(depth: int, name: string): string =
  $depth & "/" & name

proc shapeRunFor(d: var PdfDoc, wo: WalkedOp, fontName: string,
    run: TextRun, st: var FoldState,
    doc: var VecDocument): tuple[glyphs: seq[VecGlyph],
      outline: Option[VecPath]] =
  ## Shape one run through its frame's embedded program. Missing or
  ## broken programs warn once per font and leave the run unshaped;
  ## origins never depend on shaping, so they stay `extractText`-exact.
  let key = fontKeyFor(wo.depth, fontName)
  if key in st.deadFonts:
    return (@[], none(VecPath))
  if key notin st.fontBytes:
    try:
      let fd = fontDictFor(d, wo.resources, fontName)
      if fd.kind == coNull:
        raise newException(ShapeError,
          "font /" & fontName & " missing from /Resources")
      st.fontBytes[key] = embeddedFontBytes(fd, d)
    except CatchableError as e:
      doc.warn("font '" & fontName & "' cannot shape runs (" &
        e.msg & "); Widths-based advances kept, no outlines")
      st.deadFonts[key] = true
      return (@[], none(VecPath))
  if key notin st.fonts:
    try:
      st.fonts[key] = openShapedFont(st.fontBytes[key])
    except CatchableError as e:
      doc.warn("font '" & fontName & "' cannot shape runs (" &
        e.msg & "); Widths-based advances kept, no outlines")
      st.deadFonts[key] = true
      return (@[], none(VecPath))
  var shaped = ShapedText()
  shapeInto(st.fonts[key], run.text, shaped)
  (toVecGlyphs(shaped, run.size),
    bakeOutline(st.fonts[key], shaped.glyphs, run.size))

proc emitTextRun(d: var PdfDoc, wo: WalkedOp, run: TextRun,
    st: var FoldState, pageH: float64, nodes: var seq[VecNode],
    doc: var VecDocument) =
  ## An extracted run to a text node: decoded string, origin flipped to
  ## model space, size, font, active fill, plus shaped glyphs and a
  ## baked outline when the font is embedded.
  let (glyphs, outline) = shapeRunFor(d, wo, run.fontName, run, st, doc)
  doc.warn("text runs carry decoded strings, origins, size, font, and " &
    "HarfBuzz-shaped glyphs plus outlines when the font is embedded; " &
    "render modes are not modeled")
  nodes.add(wrapClips(VecNode(kind: vnkText, name: "", opacity: 1.0,
    xform: translateXform(run.x, pageH - run.y), text: run.text,
    fontName: run.fontName, fontSize: run.size, textFill: st.fill,
    glyphs: glyphs, outline: outline), st, 1.0))

proc showRun(d: var PdfDoc, wo: WalkedOp, tgs: var GState,
    decoders: var Table[string, FontDecoder], s: string, st: var FoldState,
    pageH: float64, nodes: var seq[VecNode], doc: var VecDocument) =
  ## Decode one shown string through the frame-aware decoder and emit
  ## its run, dropping it exactly when `extractText` would (outside the
  ## enclosing form's /BBox). Text-matrix advances happen inside, so
  ## later origins stay correct.
  let run = d.showTextRun(wo, tgs, decoders, s)
  if run.isSome:
    emitTextRun(d, wo, run.get(), st, pageH, nodes, doc)

proc emitPaint(st: var FoldState, strokeIt: bool,
    rule: VecFillRule, wo: WalkedOp, pageH: float64,
    nodes: var seq[VecNode], doc: var VecDocument) =
  if st.pendingClip:
    activateClip(st, st.pendingRule, wo.ctm, pageH)
    st.pendingClip = false
  var p = takePath(st)
  if p.subs.len == 0: return
  p = transformPath(p, deviceXform(wo.ctm, pageH))
  p.fillRule = rule
  var n = newPathNode(p, st.fill)
  if strokeIt and st.hasStroke:
    n.hasStroke = true
    n.stroke = st.stroke
  elif strokeIt:
    n.hasStroke = true
  nodes.add(wrapClips(n, st, 1.0))

proc lookupShading(d: var PdfDoc, res: CosObj,
    name: string): CosObj =
  let cat = d.resolve(res.dictGet("Shading"))
  if cat.kind != coDict: return CosObj(kind: coNull)
  d.resolve(cat.dictGet(name))

proc patternPaint(d: var PdfDoc, res: CosObj, name: string,
    doc: var VecDocument): VecPaint =
  ## A `/Pattern` paint name to a paint. Shading patterns (used for
  ## gradients) resolve to their gradient; tiling patterns keep only
  ## their name since tiles are not extracted.
  let cat = d.resolve(res.dictGet("Pattern"))
  if cat.kind == coDict:
    let pat = d.resolve(cat.dictGet(name))
    if pat.kind == coDict:
      let pt = pat.dictGet("PatternType")
      if pt.kind == coInt and pt.ival == 2:
        var sh = pat.dictGet("Shading")
        if sh.kind == coRef:
          sh = d.resolve(sh)
        if sh.kind == coDict:
          let grad = shadingGradient(d, sh, doc)
          if grad.kind == vgkLinear:
            return VecPaint(kind: vpkLinear, gradient: grad)
          return VecPaint(kind: vpkRadial, gradient: grad)
  doc.warn("pattern '" & name &
    "' is not a readable shading pattern; kept as a name reference")
  VecPaint(kind: vpkPattern, patternName: name,
    patternXform: identityXform())

proc foldPage*(d: var PdfDoc, pageIdx: int, pageH: float64,
    doc: var VecDocument): seq[VecNode] =
  ## One page's walked operators to artwork nodes in model space.
  ## Text state replays through a real opendocs graphics state so font
  ## selection, matrices, and advances match `extractText` exactly;
  ## paint and clipping stay in the fold state below.
  var st = FoldState(fill: solidPaint(rgbColor(0, 0, 0)),
    stroke: defaultStroke(),
    fillSpace: vcsRGB, strokeSpace: vcsRGB)
  var tgs = initGState()
  var decoders = initTable[string, FontDecoder]()
  var nodes: seq[VecNode] = @[]
  var warnedOps = initTable[string, bool]()
  template warnOp(opname, msg: string) =
    if opname notin warnedOps:
      warnedOps[opname] = true
      doc.warn(msg)
  let ops = d.walkNested(pageIdx)
  for wo in ops:
    let op = wo.op
    if op.name == "Tj":
      if op.operands.len != 1 or op.operands[0].kind != coStr:
        raise newException(AiError, "Tj needs one string operand")
      showRun(d, wo, tgs, decoders, op.operands[0].sval, st,
        pageH, nodes, doc)
      continue
    if op.name == "TJ":
      if op.operands.len != 1 or op.operands[0].kind != coArray:
        raise newException(AiError, "TJ needs one array operand")
      for item in op.operands[0].items:
        if item.kind == coStr:
          showRun(d, wo, tgs, decoders, item.sval, st,
            pageH, nodes, doc)
        else:
          let th = tgs.text.scale / 100.0
          let t: array[6, float64] = [1.0, 0.0, 0.0, 1.0,
            -item.asFloat() * tgs.text.fontSize * th / 1000.0, 0.0]
          tgs.textMatrix = concatXform(t, tgs.textMatrix)
      continue
    if op.name == "'":
      if op.operands.len != 1 or op.operands[0].kind != coStr:
        raise newException(AiError, "' needs one string operand")
      tgs.applyOp(ContentOp(name: "T*"))
      showRun(d, wo, tgs, decoders, op.operands[0].sval, st,
        pageH, nodes, doc)
      continue
    if op.name == "\"":
      if op.operands.len != 3 or op.operands[2].kind != coStr:
        raise newException(AiError,
          "\" needs word/char spacing plus a string")
      tgs.text.wordSpace = op.operands[0].asFloat()
      tgs.text.charSpace = op.operands[1].asFloat()
      tgs.applyOp(ContentOp(name: "T*"))
      showRun(d, wo, tgs, decoders, op.operands[2].sval, st,
        pageH, nodes, doc)
      continue
    tgs.applyOp(op)
    case op.name
    of "q":
      inc st.depth
      savePaint(st)
    of "Q":
      st.depth = max(0, st.depth - 1)
      dropClipsTo(st, st.depth)
      restorePaint(st)
    of "m":
      if st.hasOpen:
        st.subs.add(st.open)
        st.open = VecSubPath()
        st.hasOpen = false
      let p = vecPt(num(op, 0), num(op, 1))
      st.open = VecSubPath()
      moveTo(st.open, p)
      st.hasOpen = true
    of "l":
      ensureOpen(st, vecPt(num(op, 0), num(op, 1)))
      lineTo(st.open, vecPt(num(op, 0), num(op, 1)))
    of "c":
      ensureOpen(st, vecPt(num(op, 0), num(op, 1)))
      curveTo(st.open, vecPt(num(op, 0), num(op, 1)),
        vecPt(num(op, 2), num(op, 3)), vecPt(num(op, 4), num(op, 5)))
    of "v":
      let p = vecPt(num(op, 0), num(op, 1))
      ensureOpen(st, p)
      let cur = st.open.anchors[^1].p
      curveTo(st.open, cur, vecPt(num(op, 0), num(op, 1)),
        vecPt(num(op, 2), num(op, 3)))
    of "y":
      ensureOpen(st, vecPt(num(op, 0), num(op, 1)))
      curveTo(st.open, vecPt(num(op, 0), num(op, 1)),
        vecPt(num(op, 2), num(op, 3)), vecPt(num(op, 2), num(op, 3)))
    of "h":
      closeOpen(st)
    of "re":
      let (x, y, w, h) = (num(op, 0), num(op, 1), num(op, 2), num(op, 3))
      st.subs.add(rectSubPath(vecRect(x, y, x + w, y + h)))
    of "n":
      if st.pendingClip:
        activateClip(st, st.pendingRule, wo.ctm, pageH)
        st.pendingClip = false
      clearPath(st)
    of "S", "s":
      if op.name == "s": closeOpen(st)
      emitPaint(st, true, vfrNonZero, wo, pageH, nodes, doc)
    of "f", "F":
      emitPaint(st, false, vfrNonZero, wo, pageH, nodes, doc)
    of "f*":
      emitPaint(st, false, vfrEvenOdd, wo, pageH, nodes, doc)
    of "B", "B*":
      emitPaint(st, true,
        if op.name == "B*": vfrEvenOdd else: vfrNonZero,
        wo, pageH, nodes, doc)
    of "b", "b*":
      closeOpen(st)
      emitPaint(st, true,
        if op.name == "b*": vfrEvenOdd else: vfrNonZero,
        wo, pageH, nodes, doc)
    of "W":
      st.pendingClip = true
      st.pendingRule = vfrNonZero
    of "W*":
      st.pendingClip = true
      st.pendingRule = vfrEvenOdd
    of "g":
      st.fill = solidPaint(grayColor(num(op, 0)))
    of "G":
      st.stroke.paint = solidPaint(grayColor(num(op, 0)))
      st.hasStroke = true
    of "rg":
      st.fill = solidPaint(rgbColor(num(op, 0), num(op, 1), num(op, 2)))
    of "RG":
      st.stroke.paint = solidPaint(
        rgbColor(num(op, 0), num(op, 1), num(op, 2)))
      st.hasStroke = true
    of "k":
      st.fill = solidPaint(cmykColor(num(op, 0), num(op, 1),
        num(op, 2), num(op, 3)))
    of "K":
      st.stroke.paint = solidPaint(cmykColor(num(op, 0), num(op, 1),
        num(op, 2), num(op, 3)))
      st.hasStroke = true
    of "cs", "CS":
      if op.operands.len < 1 or op.operands[0].kind != coName:
        raise newException(AiError,
          "operator " & op.name & " needs a color space name")
      if op.name == "cs": st.fillCSName = op.operands[0].name
      else: st.strokeCSName = op.operands[0].name
      let (space, ok) = paintColorSpace(op.operands[0])
      if not ok:
        warnOp(op.name, "color space '" &
          (if op.operands[0].kind == coName: op.operands[0].name else: "?") &
          "' is not mapped; paint state unchanged")
      elif op.name == "cs": st.fillSpace = space
      else: st.strokeSpace = space
    of "sc", "SC":
      let space = if op.name == "sc": st.fillSpace else: st.strokeSpace
      let want = case space
        of vcsGray: 1
        of vcsRGB: 3
        of vcsCMYK: 4
      if op.operands.len == want:
        let c = colorOperands(op, 0, space)
        if op.name == "sc": st.fill = solidPaint(c)
        else:
          st.stroke.paint = solidPaint(c)
          st.hasStroke = true
      else:
        warnOp(op.name, "sc/SC operand count does not match the " &
          "current color space; paint state unchanged")
    of "scn", "SCN":
      let csName = if op.name == "scn": st.fillCSName else: st.strokeCSName
      if op.operands.len >= 1 and op.operands[^1].kind == coName and
          csName == "Pattern":
        let paint = patternPaint(d, wo.resources, op.operands[^1].name,
          doc)
        if op.name == "scn": st.fill = paint
        else:
          st.stroke.paint = paint
          st.hasStroke = true
      elif op.operands.len >= 1 and op.operands[^1].kind == coName:
        doc.warn("pattern color space keeps the pattern name '" &
          op.operands[^1].name & "', not its tile")
        let paint = VecPaint(kind: vpkPattern,
          patternName: op.operands[^1].name,
          patternXform: identityXform())
        if op.name == "scn": st.fill = paint
        else:
          st.stroke.paint = paint
          st.hasStroke = true
      else:
        warnOp(op.name, "scn/SCN without a resolvable paint is not mapped")
    of "w":
      st.stroke.width = num(op, 0)
      st.hasStroke = true
    of "J":
      st.stroke.cap = case int(num(op, 0))
        of 1: vlcRound
        of 2: vlcSquare
        else: vlcButt
      st.hasStroke = true
    of "j":
      st.stroke.join = case int(num(op, 0))
        of 1: vljRound
        of 2: vljBevel
        else: vljMiter
      st.hasStroke = true
    of "M":
      st.stroke.miterLimit = num(op, 0)
    of "d":
      st.stroke.dash = @[]
      if op.operands.len >= 1 and op.operands[0].kind == coArray:
        for item in op.operands[0].items:
          if item.kind == coInt: st.stroke.dash.add(float64(item.ival))
          elif item.kind == coFloat: st.stroke.dash.add(item.fval)
      if op.operands.len >= 2:
        st.stroke.dashOffset = num(op, 1)
      st.hasStroke = true
    of "gs":
      warnOp(op.name, "ExtGState parameters (transparency, transfer) " &
        "are not applied")
    of "Do":
      let xo = d.lookupXObject(wo.resources, nameOp(op, 0))
      if xo.kind == coNull:
        raise newException(AiError,
          "XObject /" & nameOp(op, 0) & " missing from /Resources")
      let sub = xo.dictGet("Subtype")
      if sub.kind == coName and sub.name == "Image":
        let m = deviceXform(wo.ctm, pageH)
        let r = vecRect(0, 0, 1, 1)
        let corners = [applyXform(m, vecPt(r.x0, r.y0)),
          applyXform(m, vecPt(r.x1, r.y0)),
          applyXform(m, vecPt(r.x1, r.y1)),
          applyXform(m, vecPt(r.x0, r.y1))]
        var box = vecRect(corners[0].x, corners[0].y,
          corners[0].x, corners[0].y)
        for c in corners[1 .. ^1]:
          box = vecRect(min(box.x0, c.x), min(box.y0, c.y),
            max(box.x1, c.x), max(box.y1, c.y))
        doc.warn("image '" & nameOp(op, 0) &
          "' keeps its name and placement, not its pixels")
        nodes.add(wrapClips(VecNode(kind: vnkImage, name: nameOp(op, 0),
          opacity: 1.0, xform: identityXform(),
          imageKey: nameOp(op, 0), imageRect: box), st, 1.0))
      else:
        warnOp(op.name, "non-image XObject '" & nameOp(op, 0) &
          "' is not interpreted")
    of "sh":
      let sh = lookupShading(d, wo.resources, nameOp(op, 0))
      if sh.kind == coNull:
        raise newException(AiError,
          "shading /" & nameOp(op, 0) & " missing from /Resources")
      var grad = shadingGradient(d, sh, doc)
      grad.xform = deviceXform(wo.ctm, pageH)
      let paint = if grad.kind == vgkLinear:
          VecPaint(kind: vpkLinear, gradient: grad)
        else:
          VecPaint(kind: vpkRadial, gradient: grad)
      let box = vecRect(0, 0, 1, 1)
      nodes.add(wrapClips(VecNode(kind: vnkPath, name: "",
        opacity: 1.0, xform: identityXform(),
        path: VecPath(subs: @[rectSubPath(box)]), fill: paint,
        stroke: defaultStroke(), hasStroke: false), st, 1.0))
      doc.warn("shading '" & nameOp(op, 0) &
        "' paints its whole artboard box, not its true extent")
    of "BMC", "BDC", "EMC", "BX", "EX", "MP", "DP", "cm":
      discard
    else:
      warnOp(op.name, "operator '" & op.name &
        "' is not mapped to vector artwork; skipped")
  for _, sf in st.fonts.mpairs:
    close(sf)
  nodes

proc readAiVectors*(data: string): VecDocument =
  ## A PDF-compatible `.ai` file to vector artwork, one artboard and one
  ## layer per page. Failures raise `AiError`, including for pages whose
  ## content operators cannot map.
  result = VecDocument()
  var d = openPdfDoc(data)
  let boxes = d.pageBoxes()
  for i in 0 ..< boxes.len:
    result.artboards.add(VecArtboard(name: "Artboard " & $(i + 1),
      rect: vecRect(0, 0, boxes[i].width, boxes[i].height)))
    var layer = VecLayer(name: "Page " & $(i + 1), visible: true,
      locked: false)
    try:
      layer.children = foldPage(d, i, boxes[i].height, result)
    except AiError as e:
      raise newException(AiError,
        "page " & $(i + 1) & " vector extraction failed: " & e.msg)
    except PdfError as e:
      raise newException(AiError,
        "page " & $(i + 1) & " vector extraction failed: " & e.msg)
    result.layers.add(layer)
