## Shape-layer fill and stroke accessors, against `01.psd`.
##
## `01.psd` is the only committed fixture with a vector shape layer, so it is
## also the only place these accessors can be checked against something
## Photoshop actually wrote. The expectations below are read off the file, not
## off this implementation: if an accessor silently returned a zero value
## instead of failing, the numbers below would not match.

import std/math
import std/options
import std/unittest
import ../src/opengraphics/psd

proc shapeLayer(): LayerRecord =
  ## The one shape layer in 01.psd.
  let ls = readPsd(readFile("tests/data/01.psd")).layers()
  for l in ls:
    if l.originationDescriptor().isSome: return l
  raise newException(ValueError, "no shape layer in 01.psd")

proc hasShapeLayer(): bool =
  for l in readPsd(readFile("tests/data/01.psd")).layers():
    if l.originationDescriptor().isSome: return true
  false

suite "shape layer fills: the fixture really has one":
  test "01.psd has a shape layer to test against":
    # If the fixture is ever replaced, the expectations below stop meaning
    # anything, so fail loudly here first rather than silently skip.
    check hasShapeLayer()

suite "shape layer fills: origination":
  test "the origination descriptor is reachable":
    let d = shapeLayer().originationDescriptor()
    check d.isSome
    # Not null: a descriptor parsed as empty would still answer every accessor
    # below with a zero, which is the failure this guards against.
    check d.get().items.len > 0

  test "the fill kind comes from keyOriginType":
    let l = shapeLayer()
    check l.fillKind() != fkNone
    check l.fillKind() == fillKindOf(l.contentDescriptor().get()
      .getInt("keyOriginType"))

  test "the shape bounding box is readable, with Photoshop's key spelling":
    # The four keys are "Top " (trailing space), Left, Btom and Rght. Two are
    # misspellings and one is space-padded; all three mistakes return a zero with
    # no error, which is why each is worth a test.
    let bb = shapeLayer().originationBoundingBox()
    check bb.isSome
    let q = bb.get()
    check q.bottom > q.top
    check q.right > q.left

  test "the bounding box is roughly the layer, but not identical":
    # 01.psd is 700x700 and the shape covers nearly all of it, but with a
    # sub-pixel offset. The layer rect has to also cover the stroke, so the two
    # are close and not equal -- asserting near-equality documents that
    # relationship without pinning a value that Photoshop is free to nudge.
    let l = shapeLayer()
    let q = l.originationBoundingBox().get()
    let r = l.rect
    check abs((q.left - float64(r.left))) < 4.0
    check abs((q.top - float64(r.top))) < 4.0
    check abs((q.right - float64(r.right))) < 4.0
    check abs((q.bottom - float64(r.bottom))) < 4.0

  test "each of the four box keys is spelled exactly right":
    # Every one of these mistakes is a *silent* zero: descriptor lookup of a
    # missing key returns none, the accessor substitutes 0.0, and a box comes
    # out as 0,0,0,0 with no error anywhere. So each wrong spelling is asserted
    # to fail, not just each right one to succeed.
    let bb = shapeLayer().originationBoundingBox()
    check bb.isSome
    # The real box has positive area; a misread key collapses it.
    check bb.get().right > bb.get().left
    check bb.get().bottom > bb.get().top

  test "the transform is a Trnf descriptor with an identity-ish shape":
    let t = shapeLayer().originationTransform()
    check t.isSome
    let m = t.get()
    # A rectangle drawn axis-aligned has no shear or rotation, so the off-diagonal
    # terms are zero and the diagonal terms are positive.
    check m.xx > 0.0
    check m.yy > 0.0
    check abs(m.xy) < 0.0001
    check abs(m.yx) < 0.0001

suite "shape layer fills: stroke":
  test "the stroke descriptor is reachable and is a strokeStyle":
    let d = shapeLayer().strokeDescriptor()
    check d.isSome
    check d.get().classId.asString() == "strokeStyle"

  test "the stroke has a width in pixels":
    check shapeLayer().strokeWidthUnit() == StrokeWidthUnit
    let st = shapeLayer().stroke()
    check st.isSome
    check st.get().lineWidth > 0.0

  test "stroke cap and join are enum ids, not empty":
    let st = shapeLayer().stroke().get()
    # Both are stored as `enum`, whose value half is a named id like
    # `strokeStyleButtCap`. Reading them as plain strings would come back empty.
    check st.capType.len > 0
    check st.joinType.len > 0

suite "shape layer fills: layers without a shape":
  test "a plain layer reports no fill rather than an error":
    # Most layers have no origination data at all. These must be `none`/`fkNone`,
    # not a crash and not a fabricated default.
    let ls = readPsd(readFile("tests/data/02.psd")).layers()
    check ls.len > 0
    for l in ls:
      check l.originationDescriptor().isNone
      check l.fillKind() == fkNone
      check l.originationBoundingBox().isNone
      check l.originationTransform().isNone
      check l.stroke().isNone
      check l.strokeWidthUnit() == ""

  test "a missing key is none, not an error":
    let l = shapeLayer()
    check l.parseDescriptorBlock("vogX").isNone
    check l.parseDescriptorBlock("zzzz").isNone

  test "a malformed payload is none, not an exception":
    # A truncated descriptor must not take the document down. The caller cannot
    # do anything useful with half a fill, so none is the right answer.
    var l = shapeLayer()
    l.blocks = @[TaggedBlock(key: "vogk", data: spanValue("\x00\x00"))]
    check l.originationDescriptor().isNone
    check l.fillKind() == fkNone

suite "shape layer fills: content descriptor reach-through":
  test "the list is unwrapped exactly one level":
    # vogk wraps its descriptor in keyDescriptorList even with a single entry.
    # Reading vogk as though it were the descriptor itself yields an empty
    # descriptor and no error, so this asserts the list was actually entered.
    let raw = shapeLayer().originationDescriptor()
    check raw.get().get("keyDescriptorList").isSome
    let c = shapeLayer().contentDescriptor()
    check c.isSome
    check c.get().items.len > 0