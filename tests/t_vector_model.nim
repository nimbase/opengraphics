import std/math
import unittest
import openparser/svg/types
import ../src/opengraphics/vector

proc close(a, b: float64): bool = abs(a - b) < 1e-9

test "xform concat composes in the right order":
  let t = translateXform(10, 0)
  let s = scaleXform(2, 2)
  # scale first, then translate: (1,1) -> (2,2) -> (12,2)
  let m = concatXform(t, s)
  let p = applyXform(m, vecPt(1, 1))
  check close(p.x, 12.0) and close(p.y, 2.0)

test "rotate is counter-clockwise in y-down space":
  let p = applyXform(rotateXform(90), vecPt(1, 0))
  check close(p.x, 0.0) and close(p.y, 1.0)

test "svg transform lists fold left to right":
  # translate(10) then scale(2): (1,1) -> (11,1) -> (22,2)
  let m = transformsToXform(@[
    SvgTransform(kind: trTranslate, values: @[10.0]),
    SvgTransform(kind: trScale, values: @[2.0]),
  ])
  let p = applyXform(m, vecPt(1, 1))
  check close(p.x, 22.0) and close(p.y, 2.0)

test "anchor classification":
  let corner = makeAnchor(vecPt(0, 0), vecPt(0, 0), vecPt(5, 0))
  check corner.kind == vakCorner
  let smooth = makeAnchor(vecPt(0, 0), vecPt(-3, 0), vecPt(4, 0))
  check smooth.kind == vakSmooth
  let kink = makeAnchor(vecPt(0, 0), vecPt(-3, 0), vecPt(0, 4))
  check kink.kind == vakCorner
  let oneSided = makeAnchor(vecPt(0, 0), vecPt(0, 0), vecPt(0, 4))
  check oneSided.kind == vakCorner

test "curveTo wires handles onto both anchors":
  var s = VecSubPath()
  moveTo(s, vecPt(0, 0))
  curveTo(s, vecPt(1, 0), vecPt(2, 0), vecPt(3, 0))
  check s.anchors.len == 2
  check s.anchors[0].hOut == vecPt(1, 0)
  check s.anchors[1].hIn == vecPt(2, 0)
  check segmentCount(s) == 1
  check segmentIsLine(s, 0) == false

test "segment of a polyline is a degenerate cubic":
  var s = VecSubPath()
  moveTo(s, vecPt(0, 0))
  lineTo(s, vecPt(4, 0))
  check segmentIsLine(s, 0)
  let c = segment(s, 0)
  check c.p0 == vecPt(0, 0) and c.p3 == vecPt(4, 0)

test "ellipse bounds match its radii":
  let b = subPathBounds(ellipseSubPath(10, 20, 5, 7))
  check close(b.x0, 5.0) and close(b.x1, 15.0)
  check close(b.y0, 13.0) and close(b.y1, 27.0)

test "closed subpaths count the closing segment":
  let s = rectSubPath(vecRect(0, 0, 10, 5))
  check s.closed and s.anchors.len == 4
  check segmentCount(s) == 4

test "transforms apply to anchors and handles":
  let s = transformSubPath(rectSubPath(vecRect(0, 0, 10, 10)),
    translateXform(5, 5))
  check s.anchors[0].p == vecPt(5, 5)
  check s.anchors[2].p == vecPt(15, 15)

test "warnings deduplicate":
  var doc = VecDocument()
  doc.warn("same")
  doc.warn("same")
  doc.warn("other")
  check doc.warnings == @["same", "other"]
