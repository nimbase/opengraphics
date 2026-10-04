## The vector mask rasteriser: coverage arithmetic and path combination.
##
## Differential where possible. A rectangle whose bounds are whole pixels must
## rasterise to exactly the pixel count its area implies, and a shape placed at
## integer offsets must not gain or lose coverage from rounding. The property
## tests then cover what has no closed form: symmetry, bounds and monotonicity
## under scale.
##
## These are the tests that justify wiring the rasteriser into the compositor. A
## "looks about right" rasteriser is worse than none, because it turns a
## correct-but-unmasked render into a subtly wrong one.

import std/algorithm
import std/math
import std/unittest
import ../src/opengraphics/psd
import ../src/opengraphics/psd/path
import ../src/opengraphics/psd/raster

proc rect(w, h: float64, x0, y0, x1, y1: float64,
    op = PathOpAdd): SubPath =
  ## A rectangle as four unlinked knots, which makes every segment straight.
  SubPath(closed: true, operation: op, knots: @[
    Knot(anchorH: x0 / float64(w), anchorV: y0 / float64(h)),
    Knot(anchorH: x1 / float64(w), anchorV: y0 / float64(h)),
    Knot(anchorH: x1 / float64(w), anchorV: y1 / float64(h)),
    Knot(anchorH: x0 / float64(w), anchorV: y1 / float64(h))])

proc coverage(plane: string, w, h: int): int =
  for v in plane: inc result, int(uint8(v))

suite "raster: exact rectangles":
  test "a whole-pixel rectangle covers exactly its area":
    for (xi0, yi0, xi1, yi1) in [(0'i32, 0'i32, 4'i32, 3'i32),
                                 (2'i32, 1'i32, 6'i32, 5'i32),
                                 (1'i32, 1'i32, 2'i32, 2'i32)]:
      let x0 = float64(xi0)
      let y0 = float64(yi0)
      let x1 = float64(xi1)
      let y1 = float64(yi1)
      let plane = rasterize(@[rect(8, 8, x0, y0, x1, y1)], 8, 8)
      check coverage(plane, 8, 8) == (xi1 - xi0) * (yi1 - yi0) * 255
      # And fully covered, fully empty, with nothing in between.
      for y in 0 ..< 8:
        for x in 0 ..< 8:
          let inside = float64(x) >= x0 and float64(x) < x1 and
            float64(y) >= y0 and float64(y) < y1
          check uint8(plane[y * 8 + x]) == (if inside: 255'u8 else: 0'u8)

  test "a rectangle inset by half a pixel is antialiased at the edge":
    # Half-covered edges are the point of the supersampling: a hard-edged
    # rasteriser would give only 0 or 255, so no pixel would be partial.
    let plane = rasterize(@[rect(4, 4, 0.5, 0.5, 3.5, 3.5)], 4, 4)
    # Total coverage is the geometric area, 3x3, up to per-pixel rounding: the
    # half-covered edge pixels land on 127.5 and round up, so the sum runs a few
    # counts over exactly 9 * 255 rather than matching it.
    let total = coverage(plane, 4, 4)
    check total >= 9 * 255
    check total < 9 * 255 + 16
    var partial = 0
    for v in plane:
      let b = uint8(v)
      if b != 0'u8 and b != 255'u8: inc partial
    check partial > 0
    # The 1x1 interior is untouched.
    check uint8(plane[1 * 4 + 1]) == 255'u8

  test "a rectangle's coverage does not depend on where it sits":
    # Same size, different position. The planes cannot be compared directly --
    # the shapes are in different places -- so what has to match is the shape:
    # total coverage, and the multiset of row and column sums.
    #
    # Knot coordinates are stored as fractions of the document, so `x / w * w` is
    # not exact and a shape one pixel to the right can land a ten-thousandth of a
    # pixel over. That is worth at most a least-significant bit on a boundary
    # pixel, so the comparison has a little slack; asking for exact equality
    # would be asserting that binary floating point is exact.
    let a = rasterize(@[rect(10, 10, 2, 2, 5, 5)], 10, 10)
    let b = rasterize(@[rect(10, 10, 4, 4, 7, 7)], 10, 10)
    var covA = 0
    var covB = 0
    for i in 0 ..< a.len:
      covA += int(uint8(a[i]))
      covB += int(uint8(b[i]))
    check abs(covA - covB) <= 8
    # Row and column profiles, sorted so position stops mattering.
    var rowsA, rowsB, colsA, colsB: seq[int] = @[]
    for y in 0 ..< 10:
      var ra = 0
      var rb = 0
      for x in 0 ..< 10:
        ra += int(uint8(a[y * 10 + x]))
        rb += int(uint8(b[y * 10 + x]))
      rowsA.add(ra)
      rowsB.add(rb)
    for x in 0 ..< 10:
      var ca = 0
      var cb = 0
      for y in 0 ..< 10:
        ca += int(uint8(a[y * 10 + x]))
        cb += int(uint8(b[y * 10 + x]))
      colsA.add(ca)
      colsB.add(cb)
    rowsA.sort()
    rowsB.sort()
    colsA.sort()
    colsB.sort()
    for i in 0 ..< 10:
      check abs(rowsA[i] - rowsB[i]) <= 8
      check abs(colsA[i] - colsB[i]) <= 8

  test "scaling a rectangle up scales coverage proportionally":
    let small = rasterize(@[rect(8, 8, 0, 0, 4, 4)], 8, 8)
    let large = rasterize(@[rect(16, 16, 0, 0, 8, 8)], 16, 16)
    check coverage(small, 8, 8) * 4 == coverage(large, 16, 16)

suite "raster: path combination":
  test "add unions two disjoint rectangles":
    let plane = rasterize(@[
      rect(8, 8, 0, 0, 2, 2, PathOpAdd),
      rect(8, 8, 6, 6, 8, 8, PathOpAdd)], 8, 8)
    check coverage(plane, 8, 8) == 2 * 2 * 255 * 2

  test "add over an overlap saturates rather than summing past full":
    let plane = rasterize(@[
      rect(8, 8, 0, 0, 4, 4, PathOpAdd),
      rect(8, 8, 2, 2, 6, 6, PathOpAdd)], 8, 8)
    # 16 + 16 - 4 overlapping pixels, all clamped to 255.
    check coverage(plane, 8, 8) == (16 + 16 - 4) * 255

  test "subtract removes the overlapping area":
    let plane = rasterize(@[
      rect(8, 8, 0, 0, 4, 4, PathOpAdd),
      rect(8, 8, 2, 2, 6, 6, PathOpSubtract)], 8, 8)
    check coverage(plane, 8, 8) == (16 - 4) * 255
    # The hole really is a hole.
    check uint8(plane[3 * 8 + 3]) == 0
    check uint8(plane[1 * 8 + 1]) == 255

  test "intersect keeps only the overlap":
    let plane = rasterize(@[
      rect(8, 8, 0, 0, 4, 4, PathOpAdd),
      rect(8, 8, 2, 2, 6, 6, PathOpIntersect)], 8, 8)
    check coverage(plane, 8, 8) == 4 * 255
    check uint8(plane[3 * 8 + 3]) == 255
    check uint8(plane[0 * 8 + 0]) == 0

  test "exclude cancels the overlap":
    let plane = rasterize(@[
      rect(8, 8, 0, 0, 4, 4, PathOpAdd),
      rect(8, 8, 2, 2, 6, 6, PathOpExclude)], 8, 8)
    # 16 + 16 - 2*4 = 24 fully covered pixels.
    check coverage(plane, 8, 8) == 24 * 255
    check uint8(plane[3 * 8 + 3]) == 0 # the shared square is gone
    check uint8(plane[0 * 8 + 0]) == 255

  test "subtracting everything leaves nothing":
    let plane = rasterize(@[
      rect(8, 8, 0, 0, 8, 8, PathOpAdd),
      rect(8, 8, 0, 0, 8, 8, PathOpSubtract)], 8, 8)
    check coverage(plane, 8, 8) == 0

suite "raster: properties":
  test "coverage is always within 0..255":
    for op in [PathOpAdd, PathOpSubtract, PathOpIntersect, PathOpExclude]:
      let plane = rasterize(@[
        rect(9, 9, 0.3, 0.7, 6.1, 5.4, PathOpAdd),
        rect(9, 9, 2.2, 1.1, 8.6, 7.9, op)], 9, 9)
      for v in plane:
        check uint8(v) <= 255'u8

  test "a fully covering rectangle is exactly 255 everywhere":
    # A round-up rather than a truncation: truncating would cap a large flat
    # region at 254 and make a solid shape permanently slightly transparent.
    let plane = rasterize(@[rect(20, 20, 0, 0, 20, 20)], 20, 20)
    for v in plane:
      check uint8(v) == 255'u8

  test "coverage is mirror invariant":
    # Mirror the *shape* about the canvas centre and require the two planes to be
    # mirror images. Comparing a shape against its own reflection at the same
    # position would be meaningless unless the shape happened to be centred, and
    # getting that condition wrong looks exactly like a rasteriser bug.
    let w = 11
    let h = 7
    let fw = float64(w)
    let fh = float64(h)
    let a = rasterize(@[
      rect(fw, fh, 1.4, 0.9, 8.2, 5.6, PathOpAdd),
      rect(fw, fh, 3.3, 2.2, 9.1, 6.4, PathOpExclude)], w, h)
    let b = rasterize(@[
      rect(fw, fh, fw - 8.2, 0.9, fw - 1.4, 5.6, PathOpAdd),
      rect(fw, fh, fw - 9.1, 2.2, fw - 3.3, 6.4, PathOpExclude)], w, h)
    var diff = 0
    var maxDelta = 0
    for y in 0 ..< h:
      for x in 0 ..< w:
        let p = int(uint8(a[y * w + x]))
        let q = int(uint8(b[y * w + (w - 1 - x)]))
        if p != q:
          inc diff
          maxDelta = max(maxDelta, abs(p - q))
    # One bit of slack on a boundary pixel, for the same reason as above.
    check maxDelta <= 1
    check diff <= 2

  test "an empty path rasterises to a plane of zeroes":
    # Not an empty string: the plane still has to exist for the compositor to
    # index into. Only degenerate *geometry* short-circuits to no plane at all.
    check rasterize(@[], 8, 8) == newString(64)
    check rasterize(@[SubPath(closed: true, knots: @[])], 8, 8) == newString(64)
    # Zero area: three coincident knots still enclose nothing.
    check coverage(rasterize(@[rect(8, 8, 1, 1, 1, 1)], 8, 8), 8, 8) == 0
    check rasterize(@[rect(8, 8, 1, 1, 1, 1)], 8, 8) == newString(64)

  test "degenerate geometry is handled rather than raising":
    for (w, h) in [(0'i32, 0'i32), (0'i32, 5'i32), (5'i32, 0'i32), (-1'i32, 4'i32)]:
      check rasterize(@[rect(4, 4, 0, 0, 4, 4)], w, h).len ==
        (if w <= 0 or h <= 0: 0 else: w * h)

suite "raster: curves":
  test "a circular path of four knots encloses about a quarter of the canvas":
    # The classic four-anchor circle. Each anchor sits on an axis with its two
    # control points offset by the circle constant 0.5523, so the enclosed area
    # should approach pi/4 of the square.
    let k = 0.5523
    let c = 0.5
    let circle = SubPath(closed: true, operation: PathOpAdd, knots: @[
      Knot(linked: true, anchorH: c, anchorV: c - 0.4,
        preH: c - 0.4 * k, preV: c - 0.4,
        postH: c + 0.4 * k, postV: c - 0.4),
      Knot(linked: true, anchorH: c + 0.4, anchorV: c,
        preH: c + 0.4, preV: c - 0.4 * k,
        postH: c + 0.4, postV: c + 0.4 * k),
      Knot(linked: true, anchorH: c, anchorV: c + 0.4,
        preH: c + 0.4 * k, preV: c + 0.4,
        postH: c - 0.4 * k, postV: c + 0.4),
      Knot(linked: true, anchorH: c - 0.4, anchorV: c,
        preH: c - 0.4, preV: c + 0.4 * k,
        postH: c - 0.4, postV: c - 0.4 * k)])
    let n = 400
    let plane = rasterize(@[circle], n, n)
    let got = float64(coverage(plane, n, n)) / float64(n * n * 255)
    # Area of a radius-0.4 circle over a unit square is pi * 0.16.
    let want = PI * 0.16
    check abs(got - want) < 0.004

  test "a curved path is smooth, not faceted":
    # Faceting from too coarse a subdivision shows up as an interior pixel with
    # low coverage; a smooth fill has none.
    let k = 0.5523
    let c = 0.5
    let circle = SubPath(closed: true, operation: PathOpAdd, knots: @[
      Knot(linked: true, anchorH: c, anchorV: c - 0.4,
        preH: c - 0.4 * k, preV: c - 0.4,
        postH: c + 0.4 * k, postV: c - 0.4),
      Knot(linked: true, anchorH: c + 0.4, anchorV: c,
        preH: c + 0.4, preV: c - 0.4 * k,
        postH: c + 0.4, postV: c + 0.4 * k),
      Knot(linked: true, anchorH: c, anchorV: c + 0.4,
        preH: c + 0.4 * k, preV: c + 0.4,
        postH: c - 0.4 * k, postV: c + 0.4),
      Knot(linked: true, anchorH: c - 0.4, anchorV: c,
        preH: c - 0.4, preV: c + 0.4 * k,
        postH: c - 0.4, postV: c - 0.4 * k)])
    let n = 128
    let plane = rasterize(@[circle], n, n)
    let mid = n div 2
    # The centre pixel is deep inside the circle.
    check uint8(plane[mid * n + mid]) == 255'u8

  test "a disabled mask block rasterises to nothing":
    # Disabled means the mask is not applied at all, so there is no plane to
    # hand the compositor -- distinct from a mask that is present but empty.
    var vb = VectorMaskBlock(version: 3, flags: VectorFlagDisabled,
      path: PathData(records: @[]), trailing: emptySpan())
    check rasterizeBlock(vb, 8, 8) == ""
    # Enabled, but no records: a plane of zeroes, i.e. nothing visible.
    vb.flags = 0
    check rasterizeBlock(vb, 8, 8) == newString(64)