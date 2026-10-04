## A vector mask actually clips the render.
##
## `01.psd` is the only committed fixture with a shape layer, and its path fills
## essentially the whole layer rect, so it cannot show that masking works. These
## build the case by hand: a layer whose raster pixels cover its whole rect and
## whose vector mask covers only part of it.

import std/options
import std/unittest
import ../src/opengraphics/psd
import ./psd_support

proc knotBlock(): string =
  ## A `vsms` payload for a rectangle covering the middle half of the document.
  ## Knot coordinates are fractions of the document, so 0.25..0.75 is the middle
  ## half of a unit document.
  let lo = 0.25
  let hi = 0.75
  var b = VectorMaskBlock(version: 3, flags: 0, path: PathData(records: @[]),
    trailing: emptySpan())
  b.path = pathFromSubPaths(@[SubPath(closed: true, operation: PathOpAdd,
    knots: @[
      Knot(anchorH: lo, anchorV: lo),
      Knot(anchorH: hi, anchorV: lo),
      Knot(anchorH: hi, anchorV: hi),
      Knot(anchorH: lo, anchorV: hi)])])
  writeVectorMaskBlock(b)

proc filled(v: byte, n: int): seq[byte] =
  ## A plane of one value throughout, so assertions can read colour directly.
  for _ in 0 ..< n:
    result.add(v)

proc maskBytes(payload: string): seq[byte] =
  for c in payload: result.add(byte(ord(c)))

proc redFirstPixelLayer(name: string, w, h: int,
    extra: seq[tuple[key: string, payload: seq[byte]]] = @[]): Document =
  ## One uniformly red layer covering the whole canvas.
  let n = w * h
  let spec = TestLayerSpec(name: name, top: 0, left: 0, bottom: int32(h),
    right: int32(w), planes: @[filled(255, n), filled(0, n), filled(0, n)],
    channelIds: @[int16(0), 1, 2], useRle: false,
    blendKey: "norm", opacity: 255'u8, lsct: -1, lsdk: -1, extra: extra)
  readPsdBytes(buildPsd(w, h, 3, @[newSeq[byte](n), newSeq[byte](n),
    newSeq[byte](n)], layers = @[spec]))

proc masked(w, h: int): Document =
  ## A layer whose raster covers its whole rect, with a vector mask over the
  ## middle half of each axis.
  redFirstPixelLayer("shape", w, h,
    @[("vsms", maskBytes(knotBlock()))])

suite "vector mask clips the render":
  test "the block is parsed and rasterised":
    let doc = masked(8, 8)
    check doc.layers().len == 1
    let l = doc.layers()[0]
    check l.hasVectorMask
    let vb = l.vectorMask().get()
    check vb.path.subpaths().len == 1
    let plane = rasterizeBlock(vb, 8, 8)
    check plane.len == 64
    var covered = 0
    for c in plane:
      if uint8(c) > 127'u8: inc covered
    # The middle half of an 8x8 is 4x4.
    check covered == 16

  test "pixels outside the vector mask do not render":
    let doc = masked(8, 8)
    let img = renderDocument(doc)
    # The middle half is drawn.
    check img.getPixel(4, 4).r == 255
    check img.getPixel(4, 4).a == 255
    check img.getPixel(2, 2).a == 255
    # The corners are not drawn at all, so the canvas stays transparent there.
    check img.getPixel(0, 0).a == 0
    check img.getPixel(7, 7).a == 0

  test "a layer with no vector mask still fills its rect":
    # The control: without the mask the same layer covers everything, so the
    # previous test is measuring the mask and not something incidental.
    let doc = redFirstPixelLayer("flat", 8, 8)
    check not doc.layers()[0].hasVectorMask
    let img = renderDocument(doc)
    check img.getPixel(0, 0).r == 255
    check img.getPixel(0, 0).a == 255
    check img.getPixel(7, 7).r == 255
    check img.getPixel(7, 7).a == 255

  test "the real fixture's shape layer is bounded by its own path":
    # Documented rather than asserted as a failure: `01.psd` layer 0 is a shape
    # layer whose path fills essentially the whole layer rect, which is why
    # wiring the rasteriser in does not move that fixture's fidelity number.
    let doc = openPsd("tests/data/01.psd")
    for l in doc.layers:
      if not l.hasVectorMask: continue
      let vb = l.vectorMask().get()
      let plane = rasterizeBlock(vb, l.rect.width(), l.rect.height())
      var covered = 0
      for c in plane:
        if uint8(c) > 127'u8: inc covered
      let area = l.rect.width() * l.rect.height()
      check covered * 100 > area * 98
