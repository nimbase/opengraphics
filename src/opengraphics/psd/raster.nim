## Rasterising a vector mask into an 8-bit coverage plane.
##
## A layer with a vector mask (`vmsk` / `vsms`) stores Bézier knots, not pixels.
## Until something turns those into coverage the layer renders its whole
## rectangle, which is wrong for every shape layer. This module is that step:
## knots to flattened polylines, polylines to a scanline coverage plane the same
## shape as a raster mask channel, so the compositor has one code path for both.
##
## Deliberately scoped to "correct shape, approximate edge". Coverage is exact
## horizontally and supersampled vertically, which is enough for a mask to look
## and composite correctly, but it will not match Photoshop's own anti-aliasing
## sample for sample. Nothing here claims otherwise.

import std/algorithm
import std/math

import ./path

type
  FPoint* = object
    ## A point in pixel coordinates, floats throughout so subdivision does not
    ## accumulate rounding.
    x*, y*: float64

  Edge = object
    ## One polygon edge, bucketed for the scanline sweep.
    x0*, y0*, x1*, y1*: float64

const
  DefaultTolerance* = 0.2
    ## Maximum chord deviation, in pixels, when subdividing a cubic. A quarter of
    ## a pixel keeps a curve from visibly faceting without generating so many
    ## segments that a large mask becomes slow.
  SubSamples* = 4
    ## Scanlines per pixel row. Horizontal coverage is computed analytically, so
    ## this only has to resolve the vertical direction.

proc flattenCubic(dst: var seq[FPoint], p0, p1, p2, p3: FPoint,
    tolerance: float64) =
  ## Append the polyline for one cubic Bezier.
  ##
  ## Subdivides on flatness measured against the chord, which is what actually
  ## bounds the error, rather than on segment count.
  # Distance of each control point from the chord p0->p3, doubled so the
  # comparison is against twice the tolerance.
  let dx = p3.x - p0.x
  let dy = p3.y - p0.y
  var d1 = abs((p1.x - p3.x) * dy - (p1.y - p3.y) * dx)
  var d2 = abs((p2.x - p3.x) * dy - (p2.y - p3.y) * dx)
  let dd = (d1 + d2) * (d1 + d2)
  if dd < tolerance * tolerance * 16.0 or
      (abs(dx) < 1e-9 and abs(dy) < 1e-9):
    dst.add(p3)
    return
  # Guard against a pathological curve recursing forever.
  if dst.len > 4096:
    dst.add(p3)
    return
  # de Casteljau split at the midpoint.
  let q0 = FPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
  let q1 = FPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
  let q2 = FPoint(x: (p2.x + p3.x) / 2, y: (p2.y + p3.y) / 2)
  let r0 = FPoint(x: (q0.x + q1.x) / 2, y: (q0.y + q1.y) / 2)
  let r1 = FPoint(x: (q1.x + q2.x) / 2, y: (q1.y + q2.y) / 2)
  let mid = FPoint(x: (r0.x + r1.x) / 2, y: (r0.y + r1.y) / 2)
  flattenCubic(dst, p0, q0, r0, mid, tolerance)
  flattenCubic(dst, mid, r1, q2, p3, tolerance)

proc flattenSubPath*(sp: SubPath, width, height: int,
    tolerance = DefaultTolerance): seq[FPoint] =
  ## One subpath as a closed polygon in pixel coordinates.
  ##
  ## Knot coordinates are stored as fractions of the document's width and
  ## height, so they are scaled here. An unlinked knot's control point is
  ## ignored: with no tangent to work from, Photoshop treats the segment as a
  ## straight line, which is what falling back to the anchor produces.
  if sp.knots.len < 2 or width <= 0 or height <= 0:
    return @[]
  let w = float64(width)
  let h = float64(height)
  result = @[FPoint(x: sp.knots[0].anchorH * w, y: sp.knots[0].anchorV * h)]

  proc control(k: Knot, outgoing: bool): FPoint =
    let ax = k.anchorH * w
    let ay = k.anchorV * h
    if k.linked:
      FPoint(x: (if outgoing: k.postH * w else: k.preH * w),
        y: (if outgoing: k.postV * h else: k.preV * h))
    else:
      FPoint(x: ax, y: ay)

  proc anchor(k: Knot): FPoint =
    FPoint(x: k.anchorH * w, y: k.anchorV * h)

  let n = sp.knots.len
  # A closed subpath emits n segments, the last wrapping from the final knot
  # back to the first. An open one emits n-1 and is closed implicitly, since a
  # fill has to be bounded either way.
  let segs = if sp.closed: n else: n - 1
  for i in 0 ..< segs:
    let a = sp.knots[i]
    let b = sp.knots[(i + 1) mod n]
    flattenCubic(result, anchor(a), control(a, true), control(b, false),
      anchor(b), tolerance)

proc spanRow(row: var seq[float64], x0, x1: float64, weight: float64,
    width: int) =
  ## Add `weight` coverage over the horizontal span `[x0, x1)`, with the partial
  ## pixels at either end weighted by how much of them the span covers.
  let a = max(x0, 0.0)
  let b = min(x1, float64(width))
  if b <= a:
    return
  var first = int(floor(a))
  var last = int(ceil(b)) - 1
  if last < first:
    last = first
  if first >= width:
    return
  if last >= width:
    last = width - 1
  if first < 0:
    first = 0
  for x in first .. last:
    let l = max(a, float64(x))
    let r = min(b, float64(x + 1))
    if r > l:
      row[x] += (r - l) * weight

proc combine(dst: var float64, src: float64, op: int) {.inline.} =
  ## Apply one subpath's coverage to the accumulated coverage.
  case op
  of PathOpSubtract:
    dst = max(dst - src, 0.0)
  of PathOpIntersect:
    dst = min(dst, src)
  of PathOpExclude:
    # Exclusive-or: overlap cancels.
    dst = dst + src - 2.0 * dst * src
  else:
    dst = min(dst + src, 1.0)

proc rasterize*(subpaths: seq[SubPath], width, height: int,
    tolerance = DefaultTolerance): string =
  ## An `width * height` plane of coverage, one byte per pixel.
  ##
  ## Subpaths are applied in order and combined with each one's `operation`, so
  ## a subtract or intersect behaves the way the path was authored rather than
  ## every subpath simply adding.
  if width <= 0 or height <= 0:
    return ""
  let sub = float64(SubSamples)
  let weight = 1.0 / sub
  var acc = newSeq[float64](width * height)
  var xs: seq[float64] = @[]

  for sp in subpaths:
    let poly = flattenSubPath(sp, width, height, tolerance)
    if poly.len < 3:
      continue
    # Bucket edges by the pixel row they start in, so each row only considers
    # edges that can cross it. Without this a large mask costs rows x edges.
    var edges: seq[Edge] = @[]
    for i in 0 ..< poly.len:
      let a = poly[i]
      let b = poly[(i + 1) mod poly.len]
      if a.y == b.y:
        continue # horizontal edges never contribute a crossing
      edges.add(Edge(x0: a.x, y0: min(a.y, b.y), x1: b.x, y1: max(a.y, b.y)))
    if edges.len == 0:
      continue
    edges.sort(proc (a, b: Edge): int = cmp(a.y0, b.y0))

    var active: seq[int] = @[]
    var next = 0
    for y in 0 ..< height:
      let rowTop = float64(y)
      let rowBottom = rowTop + 1.0
      while next < edges.len and edges[next].y0 < rowBottom:
        active.add(next)
        inc next
      # Retire edges that finished above this row.
      var keep: seq[int] = @[]
      for e in active:
        if edges[e].y1 > rowTop:
          keep.add(e)
      active = keep

      # A row this subpath does not reach still has to be *combined*, not
      # skipped. Intersect and subtract are defined against the whole plane, so
      # a row the subpath lies outside of contributes zero coverage: leaving it
      # untouched would keep whatever an earlier subpath accumulated there. That
      # put an intersection's result in the wrong rows entirely.
      if active.len == 0:
        let base = y * width
        for x in 0 ..< width:
          combine(acc[base + x], 0.0, sp.operation)
        continue

      var row = newSeq[float64](width)
      for s in 0 ..< SubSamples:
        let sy = rowTop + (float64(s) + 0.5) / sub
        xs.setLen(0)
        for e in active:
          let ed = edges[e]
          if ed.y0 <= sy and sy < ed.y1:
            let t = (sy - ed.y0) / (ed.y1 - ed.y0)
            xs.add(ed.x0 + t * (ed.x1 - ed.x0))
        if xs.len < 2:
          continue
        xs.sort()
        # Even-odd within one subpath; the `operation` field is what combines
        # separate subpaths with each other.
        var i = 0
        while i + 1 < xs.len:
          spanRow(row, xs[i], xs[i + 1], weight, width)
          i += 2
      let base = y * width
      for x in 0 ..< width:
        combine(acc[base + x], min(row[x], 1.0), sp.operation)

  result = newString(width * height)
  for i in 0 ..< acc.len:
    let v = clamp(acc[i], 0.0, 1.0)
    # Round rather than truncate: a mask that is fully covered must come out
    # 255, and truncation would cap a large flat region at 254.
    result[i] = char(int(v * 255.0 + 0.5))

proc rasterizeBlock*(b: VectorMaskBlock, width, height: int,
    tolerance = DefaultTolerance): string =
  ## Rasterise a parsed vector mask block. Honours `VectorFlagDisabled`, which
  ## asks for the mask to be ignored entirely.
  if (b.flags and VectorFlagDisabled) != 0:
    return ""
  rasterize(b.path.subpaths(), width, height, tolerance)
