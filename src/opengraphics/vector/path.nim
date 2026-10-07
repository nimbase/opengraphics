## Path construction and evaluation for the vector model.
##
## Anchors carry absolute handle positions, like every Illustrator-style
## tool thinks about paths: a handle equal to its anchor means no handle.
## Segments evaluate as cubics, with straight lines as degenerate cubics,
## so flattening and hit-testing downstream need only one segment type.

import std/math
import ./types

export types

proc cornerAnchor*(p: VecPt): VecAnchor =
  VecAnchor(p: p, hIn: p, hOut: p, kind: vakCorner)

proc smoothAnchor*(p, outHandle: VecPt): VecAnchor =
  ## A smooth anchor with a symmetric out handle; the in handle mirrors it.
  VecAnchor(p: p, hIn: vecPt(2*p.x - outHandle.x, 2*p.y - outHandle.y),
    hOut: outHandle, kind: vakSmooth)

proc classifyAnchor*(p, hIn, hOut: VecPt): VecAnchorKind =
  ## Corner unless both handles exist, are non-degenerate, and sit on
  ## opposite sides of a shared line through `p`.
  let a = vecPt(hIn.x - p.x, hIn.y - p.y)
  let b = vecPt(hOut.x - p.x, hOut.y - p.y)
  let la = sqrt(a.x*a.x + a.y*a.y)
  let lb = sqrt(b.x*b.x + b.y*b.y)
  if la <= VecEps or lb <= VecEps:
    return vakCorner
  let cross = abs(a.x*b.y - a.y*b.x) / (la * lb)
  let dot = (a.x*b.x + a.y*b.y) / (la * lb)
  if cross <= 1e-6 and dot < 0.0: vakSmooth else: vakCorner

proc makeAnchor*(p, hIn, hOut: VecPt): VecAnchor =
  VecAnchor(p: p, hIn: hIn, hOut: hOut,
    kind: classifyAnchor(p, hIn, hOut))

proc hasIn*(a: VecAnchor): bool =
  abs(a.hIn.x - a.p.x) > VecEps or abs(a.hIn.y - a.p.y) > VecEps

proc hasOut*(a: VecAnchor): bool =
  abs(a.hOut.x - a.p.x) > VecEps or abs(a.hOut.y - a.p.y) > VecEps

proc segmentCount*(s: VecSubPath): int =
  let n = s.anchors.len
  if n < 2: 0
  elif s.closed: n
  else: n - 1

proc segment*(s: VecSubPath, i: int): VecCubic =
  ## Segment `i` as an explicit cubic. Lines are cubics whose control
  ## points sit on their endpoints.
  let n = s.anchors.len
  let a = s.anchors[i mod n]
  let b = s.anchors[(i + 1) mod n]
  VecCubic(p0: a.p, p1: a.hOut, p2: b.hIn, p3: b.p)

proc segmentIsLine*(s: VecSubPath, i: int): bool =
  let n = s.anchors.len
  let a = s.anchors[i mod n]
  let b = s.anchors[(i + 1) mod n]
  not a.hasOut() and not b.hasIn()

proc transformAnchor*(a: VecAnchor, m: VecXform): VecAnchor =
  VecAnchor(p: applyXform(m, a.p), hIn: applyXform(m, a.hIn),
    hOut: applyXform(m, a.hOut), kind: a.kind)

proc transformSubPath*(s: VecSubPath, m: VecXform): VecSubPath =
  result = VecSubPath(closed: s.closed)
  for a in s.anchors:
    result.anchors.add(transformAnchor(a, m))

proc transformPath*(p: VecPath, m: VecXform): VecPath =
  result = VecPath(fillRule: p.fillRule)
  for s in p.subs:
    result.subs.add(transformSubPath(s, m))

proc moveTo*(s: var VecSubPath, p: VecPt) =
  s.anchors.add(cornerAnchor(p))

proc lineTo*(s: var VecSubPath, p: VecPt) =
  s.anchors.add(cornerAnchor(p))

proc curveTo*(s: var VecSubPath, c1, c2, p: VecPt) =
  ## Append a cubic ending at `p`. The previous anchor's out handle
  ## becomes `c1`; the new anchor's in handle becomes `c2`.
  if s.anchors.len == 0:
    s.anchors.add(cornerAnchor(c1))
  s.anchors[^1].hOut = c1
  s.anchors[^1].kind = classifyAnchor(
    s.anchors[^1].p, s.anchors[^1].hIn, c1)
  s.anchors.add(VecAnchor(p: p, hIn: c2, hOut: p,
    kind: classifyAnchor(p, c2, p)))

proc rectSubPath*(r: VecRect): VecSubPath =
  ## A closed rectangle as four corner anchors, counter-clockwise in
  ## y-down space.
  VecSubPath(closed: true, anchors: @[
    cornerAnchor(vecPt(r.x0, r.y0)),
    cornerAnchor(vecPt(r.x1, r.y0)),
    cornerAnchor(vecPt(r.x1, r.y1)),
    cornerAnchor(vecPt(r.x0, r.y1)),
  ])

const circleKappa* = 0.5522847498
  ## Bezier approximation constant for circle and ellipse quadrants.

proc ellipseSubPath*(cx, cy, rx, ry: float64): VecSubPath =
  ## An ellipse as four smooth anchors. Degenerate radii collapse to
  ## corner anchors rather than producing NaN handles.
  if rx <= 0.0 or ry <= 0.0:
    return VecSubPath(closed: true, anchors: @[
      cornerAnchor(vecPt(cx, cy))])
  let kx = circleKappa * rx
  let ky = circleKappa * ry
  VecSubPath(closed: true, anchors: @[
    VecAnchor(p: vecPt(cx + rx, cy), hIn: vecPt(cx + rx, cy - ky),
      hOut: vecPt(cx + rx, cy + ky), kind: vakSmooth),
    VecAnchor(p: vecPt(cx, cy + ry), hIn: vecPt(cx + kx, cy + ry),
      hOut: vecPt(cx - kx, cy + ry), kind: vakSmooth),
    VecAnchor(p: vecPt(cx - rx, cy), hIn: vecPt(cx - rx, cy + ky),
      hOut: vecPt(cx - rx, cy - ky), kind: vakSmooth),
    VecAnchor(p: vecPt(cx, cy - ry), hIn: vecPt(cx - kx, cy - ry),
      hOut: vecPt(cx + kx, cy - ry), kind: vakSmooth),
  ])

proc subPathBounds*(s: VecSubPath): VecRect =
  ## Conservative bounds over anchors and handles.
  if s.anchors.len == 0:
    return vecRect(0, 0, 0, 0)
  var r = vecRect(s.anchors[0].p.x, s.anchors[0].p.y,
    s.anchors[0].p.x, s.anchors[0].p.y)
  proc grow(p: VecPt) =
    r = vecRect(min(r.x0, p.x), min(r.y0, p.y),
      max(r.x1, p.x), max(r.y1, p.y))
  for a in s.anchors:
    grow(a.p)
    grow(a.hIn)
    grow(a.hOut)
  r

proc pathBounds*(p: VecPath): VecRect =
  if p.subs.len == 0:
    return vecRect(0, 0, 0, 0)
  var r = subPathBounds(p.subs[0])
  for s in p.subs[1 .. ^1]:
    let b = subPathBounds(s)
    r = vecRect(min(r.x0, b.x0), min(r.y0, b.y0),
      max(r.x1, b.x1), max(r.y1, b.y1))
  r
