## Shared vector artwork model.
##
## One programmatic representation for vector content read from `.ai`
## (PDF-compatible content streams), legacy EPS containers, and SVG.
## Coordinates are document points with y pointing down, matching SVG user
## units and the reference geometry kernel. PDF's y-up space is converted
## once at the import/export boundary, never inside this model.
##
## The model is deliberately narrower than a full illustration app: paths,
## paints, strokes, groups, layers, artboards, placed-image references,
## and text placeholders. Anything richer (live effects, brushes, meshes,
## filters) is out of scope and must surface as a warning at the bridge
## that encounters it, never as silent data loss.

import std/math
import std/options
import std/strutils

export options

type
  VecPt* = object
    ## A point in document space, y down.
    x*, y*: float64

  VecRect* = object
    ## An axis-aligned rectangle, normalized so x0 <= x1 and y0 <= y1.
    x0*, y0*, x1*, y1*: float64

  VecXform* = array[6, float64]
    ## A 2D affine transform `[a b c d e f]`:
    ## x' = a*x + c*y + e, y' = b*x + d*y + f.
    ## Same layout as PDF `cm` and SVG `matrix()`.

  VecFillRule* = enum
    vfrNonZero, vfrEvenOdd

  VecAnchorKind* = enum
    vakCorner, vakSmooth

  VecAnchor* = object
    ## One anchor with absolute handle positions. A handle equal to `p`
    ## means "no handle".
    p*, hIn*, hOut*: VecPt
    kind*: VecAnchorKind

  VecSubPath* = object
    anchors*: seq[VecAnchor]
    closed*: bool

  VecPath* = object
    subs*: seq[VecSubPath]
    fillRule*: VecFillRule

  VecCubic* = object
    ## One flattened segment: all four points explicit.
    p0*, p1*, p2*, p3*: VecPt

  VecColorSpace* = enum
    vcsRGB, vcsGray, vcsCMYK

  VecColor* = object
    ## Color components are all 0..1, alpha included.
    case space*: VecColorSpace
    of vcsRGB: r*, g*, b*: float64
    of vcsGray: gray*: float64
    of vcsCMYK: c*, m*, y*, k*: float64
    alpha*: float64

  VecGradientKind* = enum
    vgkLinear, vgkRadial

  VecGradientStop* = object
    offset*: float64 ## 0..1 along the gradient
    color*: VecColor

  VecSpread* = enum
    vspPad, vspReflect, vspRepeat

  VecGradient* = object
    kind*: VecGradientKind
    stops*: seq[VecGradientStop]
    xform*: VecXform ## gradient space to user space
    objectBoundingBox*: bool ## true when stops were authored in bbox space
    spread*: VecSpread
    ## Linear: (x0,y0) to (x1,y1). Radial: center (cx,cy), radius r,
    ## focal (fx,fy).
    x0*, y0*, x1*, y1*: float64
    cx*, cy*, r*, fx*, fy*: float64

  VecPaintKind* = enum
    vpkNone, vpkSolid, vpkLinear, vpkRadial, vpkPattern

  VecPaint* = object
    case kind*: VecPaintKind
    of vpkNone: discard
    of vpkSolid: solid*: VecColor
    of vpkLinear, vpkRadial: gradient*: VecGradient
    of vpkPattern:
      patternName*: string
      patternXform*: VecXform

  VecLineCap* = enum
    vlcButt, vlcRound, vlcSquare

  VecLineJoin* = enum
    vljMiter, vljRound, vljBevel

  VecStroke* = object
    paint*: VecPaint
    width*: float64
    cap*: VecLineCap
    join*: VecLineJoin
    miterLimit*: float64
    dash*: seq[float64]
    dashOffset*: float64

  VecNodeKind* = enum
    vnkGroup, vnkPath, vnkImage, vnkText, vnkClip

  VecNode* = ref object
    ## A single artwork object. `xform` places the node in its parent's
    ## space; `opacity` multiplies everything the node paints.
    name*: string
    opacity*: float64
    xform*: VecXform
    case kind*: VecNodeKind
    of vnkGroup:
      children*: seq[VecNode]
    of vnkPath:
      path*: VecPath
      fill*: VecPaint
      stroke*: VecStroke
      hasStroke*: bool
    of vnkImage:
      imageKey*: string ## href, blob key, or blob name
      imageRect*: VecRect ## placement rect in node space
    of vnkText:
      text*: string
      fontName*: string
      fontSize*: float64
      textFill*: VecPaint
    of vnkClip:
      clip*: VecPath
      clipRule*: VecFillRule
      clipped*: seq[VecNode]

  VecLayer* = object
    name*: string
    visible*: bool
    locked*: bool
    children*: seq[VecNode]

  VecArtboard* = object
    name*: string
    rect*: VecRect

  VecDocument* = object
    artboards*: seq[VecArtboard]
    layers*: seq[VecLayer]
    warnings*: seq[string] ## everything approximated or left out

  VecLimits* = object
    maxNodes*: int
    maxAnchors*: int
    maxGradientStops*: int

const
  VecEps* = 1e-9
    ## Geometric tolerance for handle and collinearity tests.

proc defaultVecLimits*(): VecLimits =
  VecLimits(maxNodes: 100000, maxAnchors: 1000000, maxGradientStops: 256)

proc vecPt*(x, y: float64): VecPt = VecPt(x: x, y: y)

proc vecRect*(x0, y0, x1, y1: float64): VecRect =
  VecRect(x0: min(x0, x1), y0: min(y0, y1),
    x1: max(x0, x1), y1: max(y0, y1))

proc rectWidth*(r: VecRect): float64 = r.x1 - r.x0
proc rectHeight*(r: VecRect): float64 = r.y1 - r.y0

proc identityXform*(): VecXform = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]

proc translateXform*(tx, ty: float64): VecXform =
  [1.0, 0.0, 0.0, 1.0, tx, ty]

proc scaleXform*(sx, sy: float64): VecXform =
  [sx, 0.0, 0.0, sy, 0.0, 0.0]

proc rotateXform*(degrees: float64): VecXform =
  ## Counter-clockwise in y-down space, matching SVG `rotate()`.
  let a = degrees * PI / 180.0
  [cos(a), sin(a), -sin(a), cos(a), 0.0, 0.0]

proc concatXform*(m1, m2: VecXform): VecXform =
  ## The transform that applies `m2` first, then `m1`.
  [m1[0]*m2[0] + m1[2]*m2[1],
   m1[1]*m2[0] + m1[3]*m2[1],
   m1[0]*m2[2] + m1[2]*m2[3],
   m1[1]*m2[2] + m1[3]*m2[3],
   m1[0]*m2[4] + m1[2]*m2[5] + m1[4],
   m1[1]*m2[4] + m1[3]*m2[5] + m1[5]]

proc applyXform*(m: VecXform, p: VecPt): VecPt =
  vecPt(m[0]*p.x + m[2]*p.y + m[4], m[1]*p.x + m[3]*p.y + m[5])

proc isIdentity*(m: VecXform): bool =
  const id = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
  for i in 0 .. 5:
    if abs(m[i] - id[i]) > VecEps: return false
  true

proc rgbColor*(r, g, b: float64, alpha = 1.0): VecColor =
  VecColor(space: vcsRGB, r: r, g: g, b: b, alpha: alpha)

proc grayColor*(v: float64, alpha = 1.0): VecColor =
  VecColor(space: vcsGray, gray: v, alpha: alpha)

proc cmykColor*(c, m, y, k: float64, alpha = 1.0): VecColor =
  VecColor(space: vcsCMYK, c: c, m: m, y: y, k: k, alpha: alpha)

proc solidPaint*(c: VecColor): VecPaint =
  VecPaint(kind: vpkSolid, solid: c)

proc noPaint*(): VecPaint = VecPaint(kind: vpkNone)

proc defaultStroke*(): VecStroke =
  VecStroke(paint: solidPaint(rgbColor(0, 0, 0)), width: 1.0,
    cap: vlcButt, join: vljMiter, miterLimit: 4.0,
    dash: @[], dashOffset: 0.0)

proc newGroup*(name = "", opacity = 1.0,
    xform = identityXform()): VecNode =
  VecNode(kind: vnkGroup, name: name, opacity: opacity, xform: xform,
    children: @[])

proc newPathNode*(path: VecPath, fill = noPaint(),
    name = "", opacity = 1.0, xform = identityXform()): VecNode =
  VecNode(kind: vnkPath, name: name, opacity: opacity, xform: xform,
    path: path, fill: fill, stroke: defaultStroke(), hasStroke: false)

proc warn*(doc: var VecDocument, msg: string) =
  ## Record an approximation. De-duplicated so repeated constructs do
  ## not flood the report.
  if msg notin doc.warnings:
    doc.warnings.add(msg)

proc fmtNum*(v: float64, decimals = 3): string =
  ## Compact number formatting for generated SVG: at most `decimals`
  ## places, no trailing zeros, no negative zero.
  if v != v or v == Inf or v == -Inf: return "0"
  var s = formatFloat(v, ffDecimal, decimals)
  while s.contains('.') and s[^1] == '0':
    s.setLen(s.len - 1)
  if s.len > 0 and s[^1] == '.':
    s.setLen(s.len - 1)
  if s == "-0": "0" else: s
