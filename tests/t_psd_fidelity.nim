## Compositor fidelity: our render against the composite Photoshop stored.
##
## The renderer never reads the stored composite -- it walks the layer tree and
## blends. So the stored composite is the closest thing to an oracle available,
## and this suite compares the two. It is worth being precise about what that
## comparison can and cannot prove, because the headline number is misleading.
##
## `01.psd` matches on 97.86% of pixels, which sounds like a real defect. It is
## not. Every pixel that differs by more than 8 levels -- 13,529 of them across
## the three fixtures -- lies inside a `TySh` text layer's rect. Not one lies
## anywhere else. So the compositor is exact everywhere except type layers, and
## the exact-match percentage is dominated by how much of each canvas the text
## happens to cover.
##
## The cause is not layer effects, which is what an earlier note in
## `psd-rewrite.md` claimed: `01.psd` contains no `lfx`, `lrFX` or `lfx2` bytes
## at all. The cause is that Photoshop's composite for a type layer is not a
## blend of the type layer's own stored pixels. Recomputing those pixels by hand
## with plain straight-alpha "source over" reproduces our render to within a
## rounding level, while Photoshop's stored value is consistently *lighter* --
## consistent with a gamma-aware composite, though no single exponent fits every
## case, so it is not worth claiming precisely. Either way the stored composite
## is not a pixel-exact oracle for type layers, and treating it as one would mean
## chasing a difference that is not in our code.
##
## That is why the load-bearing assertions here are the structural ones -- a
## bounded maximum delta, and *where* the differences are -- rather than the
## percentage. Those two catch a compositor regression anywhere outside a text
## layer, which is what the group isolation, vector mask and Blend If work could
## plausibly break, and they do not care that the percentage is unimpressive.

import std/[options, strutils]
import std/unittest
import ../src/opengraphics/psd

type
  Meas = object
    total, exact: int
    maxDelta, over8, over16: int
    minX, minY, maxX, maxY: int  ## bounding box of pixels differing by > 8

proc channelDelta(a, b: Rgba): int {.inline.} =
  max(int(abs(int(a.r) - int(b.r))),
    max(int(abs(int(a.g) - int(b.g))),
      max(int(abs(int(a.b) - int(b.b))), abs(int(a.a) - int(b.a)))))

proc measure(ours, theirs: ImageBuf): Meas =
  result.total = ours.width * ours.height
  result.exact = 0
  result.maxDelta = 0
  result.minX = 1_000_000
  result.minY = 1_000_000
  result.maxX = -1
  result.maxY = -1
  for i in 0 ..< result.total:
    let d = channelDelta(ours.data[i], theirs.data[i])
    if d == 0:
      inc result.exact
      continue
    result.maxDelta = max(result.maxDelta, d)
    if d > 8: inc result.over8
    if d > 16: inc result.over16
    if d > 8:
      let x = i mod ours.width
      let y = i div ours.width
      result.minX = min(result.minX, x)
      result.maxX = max(result.maxX, x)
      result.minY = min(result.minY, y)
      result.maxY = max(result.maxY, y)

proc textRects(doc: Document): seq[Rect] =
  ## Rects of the type layers, identified by carrying `TySh`.
  for l in doc.layers:
    for b in l.blocks:
      if b.key == "TySh":
        result.add l.rect
        break

proc insideAny(p: int, q: int, rects: seq[Rect]): bool {.inline.} =
  for r in rects:
    if p >= int(r.left) and p < int(r.right) and
        q >= int(r.top) and q < int(r.bottom):
      return true
  false

suite "fidelity: measurement is not vacuous":
  test "every fixture has a composite of the same size as our render":
    # Guards the whole suite. If the composite were absent, empty, or a
    # different size, every comparison below would silently compare nothing.
    for f in ["01.psd", "02.psd", "03.psd"]:
      let doc = readPsdBytes(readFile("tests/data/" & f))
      check doc.hasComposite
      let ours = renderDocument(doc)
      let theirs = doc.compositeImage()
      check ours.width == theirs.width
      check ours.height == theirs.height
      check ours.width > 0 and ours.height > 0
      check doc.width == ours.width
      check doc.height == ours.height

  test "the fixtures still contain type layers":
    # If the type layers went away, the attribution assertions below would hold
    # trivially and stop meaning anything.
    var totalText = 0
    for f in ["01.psd", "02.psd", "03.psd"]:
      let doc = readPsdBytes(readFile("tests/data/" & f))
      totalText += textRects(doc).len
      check textRects(doc).len > 0
    check totalText >= 3

  test "the differences being attributed are real":
    # Otherwise "every difference is inside a text layer" is trivially true.
    var anyDifferences = false
    for f in ["01.psd", "02.psd", "03.psd"]:
      let doc = readPsdBytes(readFile("tests/data/" & f))
      if measure(renderDocument(doc), doc.compositeImage()).over8 > 0:
        anyDifferences = true
    check anyDifferences

suite "fidelity: every real difference is a type-layer pixel":
  test "no pixel differs by more than 8 outside a TySh rect":
    # The load-bearing assertion. A regression in group isolation, vector masks
    # or Blend If would show up here as differences away from the text, which
    # the exact-match percentage could easily hide inside.
    var checkedPixels = 0
    for f in ["01.psd", "02.psd", "03.psd"]:
      let doc = readPsdBytes(readFile("tests/data/" & f))
      let ours = renderDocument(doc)
      let theirs = doc.compositeImage()
      let rects = textRects(doc)
      var offenders = 0
      var worst = ""
      for y in 0 ..< ours.height:
        for x in 0 ..< ours.width:
          inc checkedPixels
          if channelDelta(ours.getPixel(x, y), theirs.getPixel(x, y)) <= 8:
            continue
          if not insideAny(x, y, rects):
            inc offenders
            if worst.len == 0:
              worst = " (" & $x & "," & $y & ")"
      check offenders == 0
      check worst == ""
    check checkedPixels > 1_000_000

  test "no pixel differs by more than a small bound anywhere":
    # A structural floor, generous enough to absorb rounding but far too tight
    # for anything genuinely broken. Measured maxima: 01 -> 31, 02 -> 40,
    # 03 -> 2. Without text layers the difference would be 0.
    let cases: seq[tuple[name: string, bound: int]] =
      @[("01.psd", 48), ("02.psd", 48), ("03.psd", 8)]
    for c in cases:
      let doc = readPsdBytes(readFile("tests/data/" & c.name))
      let m = measure(renderDocument(doc), doc.compositeImage())
      check m.maxDelta <= c.bound

suite "fidelity: the headline percentages are recorded, not relied on":
  test "exact-match against the stored composite stays where it was":
    # These are informational floors. They exist so that a large change in the
    # right direction is noticed, and the low values for 02 and 03 look alarming
    # only because their canvases are mostly covered by one big type layer: 03
    # differs from Photoshop by at most 2 levels anywhere, yet matches exactly on
    # only 60% of pixels. See the note at the top of this file.
    let cases: seq[tuple[name: string, floor: float64]] =
      @[("01.psd", 97.5), ("02.psd", 59.0), ("03.psd", 60.0)]
    for c in cases:
      let doc = readPsdBytes(readFile("tests/data/" & c.name))
      let m = measure(renderDocument(doc), doc.compositeImage())
      let pct = float64(m.exact) * 100.0 / float64(m.total)
      check pct >= c.floor
      # And the opposite direction: never become perfect. If this ever hits
      # 100% the comparison has stopped testing anything.
      check pct < 100.0

suite "fidelity: our render is a faithful recomposition of the layer data":
  test "a hand-written straight-alpha blend reproduces our render":
    # Independent of the stored composite, and the strongest statement available
    # about our own arithmetic: naive 8-bit straight-alpha "source over" of a
    # layer's own pixels and the one below it matches `renderDocument` to within
    # a rounding level. That is what says the compositor is right and that the
    # type-layer difference is in Photoshop's composite, not in our blend.
    let doc = readPsdBytes(readFile("tests/data/01.psd"))
    # Index 0 is the only non-text layer and covers the whole canvas; index 2 is
    # a type layer sitting on top of it.
    let baseImg = doc.layerImage(0)
    let textIdx = 2
    let textImg = doc.layerImage(textIdx)
    let ours = renderDocument(doc)

    proc over(back, src: Rgba): Rgba =
      let a = float64(src.a)
      proc mix(sc, bc: uint8): uint8 =
        uint8((float64(sc) * a + float64(bc) * (255.0 - a)) / 255.0 + 0.5)
      Rgba(r: mix(src.r, back.r), g: mix(src.g, back.g), b: mix(src.b, back.b), a: 255)

    var mismatches = 0
    var compared = 0
    let tr = doc.layers[textIdx].rect
    for y in int(tr.top) ..< int(tr.bottom):
      for x in int(tr.left) ..< int(tr.right):
        let lx = x - int(tr.left)
        let ly = y - int(tr.top)
        if lx < 0 or ly < 0 or lx >= textImg.img.width or ly >= textImg.img.height:
          continue
        if x + 2 < 0 or y + 2 < 0 or
            x + 2 >= baseImg.img.width or y + 2 >= baseImg.img.height:
          continue
        let naive = over(baseImg.img.getPixel(x + 2, y + 2), textImg.img.getPixel(lx, ly))
        let rendered = ours.getPixel(x, y)
        if channelDelta(naive, rendered) > 1:
          inc mismatches
        inc compared
    check compared > 1000
    check mismatches == 0