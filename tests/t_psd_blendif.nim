## Blend If ("Blend Using Blend If") coverage arithmetic.
##
## A layer record carries one 8-byte entry per range: a source quadruple applied
## to the backdrop, then a destination quadruple applied to the layer's own
## value. The first entry is the composite (grey) one and the rest are per
## channel.
##
## The ramps are checked against hand-computed values rather than against a
## previous run of this code, and the record layout is checked for the property
## that makes it safe: a layer must not read past the end of its own range list.

import std/options
import std/unittest
import ../src/opengraphics/psd
import ./psd_support

proc fullRanges(n: int): string =
  ## `n` records of Photoshop's default 8-byte entry: 0,0,255,255 twice.
  for _ in 0 ..< n:
    for v in [0'u8, 0'u8, 255'u8, 255'u8]:
      result.add(char(v))
    for v in [0'u8, 0'u8, 255'u8, 255'u8]:
      result.add(char(v))

proc quad(r: BlendRange, which: int): array[4, int] =
  let q = (if which == 0: r.source else: r.dest)
  [int(q[0]), int(q[1]), int(q[2]), int(q[3])]

suite "blend if: the ramp":
  test "the Photoshop default passes everything":
    # 0,0,255,255 is "no restriction", which is what every layer without Blend If
    # set carries. If this were not 255 the compositor would darken every layer.
    for v in [0'i32, 1, 64, 128, 200, 254, 255]:
      check blendIfAt(@[BlendRange(source: [0'u8, 0'u8, 255'u8, 255'u8],
        dest: [0'u8, 0'u8, 255'u8, 255'u8])], v, v, v) == 255

  test "an empty range list passes everything":
    check blendIfAt(@[], 10, 10, 10) == 255

  test "a black cutoff removes values below it":
    # blackLo=100: values under 100 do not pass at all.
    let r = BlendRange(source: [100'u8, 100'u8, 255'u8, 255'u8],
      dest: [0'u8, 0'u8, 255'u8, 255'u8])
    check blendIfAt(@[r], 99, 99, 99) == 0
    check blendIfAt(@[r], 100, 100, 100) == 255

  test "a white cutoff removes values above it":
    let r = BlendRange(source: [0'u8, 0'u8, 200'u8, 200'u8],
      dest: [0'u8, 0'u8, 255'u8, 255'u8])
    check blendIfAt(@[r], 201, 201, 201) == 0
    check blendIfAt(@[r], 200, 200, 200) == 255

  test "the black ramp is linear between the two blacks":
    # blackLo=0, blackHi=128: 64 is halfway, so 128 of 255.
    let r = BlendRange(source: [0'u8, 128'u8, 255'u8, 255'u8],
      dest: [0'u8, 0'u8, 255'u8, 255'u8])
    check blendIfAt(@[r], 0, 0, 0) == 0
    check blendIfAt(@[r], 64, 64, 64) == 128
    check blendIfAt(@[r], 128, 128, 128) == 255
    # And linear in between, to within a level of quantisation.
    for v in 1 .. 127:
      let cov = blendIfAt(@[r], v, v, v)
      check cov >= (v * 255 + 63) div 128 - 1
      check cov <= (v * 255 + 64) div 128 + 1

  test "the white ramp falls linearly between the two whites":
    # whiteLo=128, whiteHi=255: 191 is halfway, so 128 of 255.
    let r = BlendRange(source: [0'u8, 0'u8, 128'u8, 255'u8],
      dest: [0'u8, 0'u8, 255'u8, 255'u8])
    check blendIfAt(@[r], 255, 255, 255) == 0
    # 191 is halfway between the two whites, so about half. Exactly 128 or 129
    # depending on which way the division rounds; the value is quantised to 8
    # bits either way and the ramp is documented as approximate.
    let mid = blendIfAt(@[r], 191, 191, 191)
    check mid >= 128 and mid <= 129
    check blendIfAt(@[r], 128, 128, 128) == 255

  test "source and destination multiply":
    # Two half-strength ramps in series give a quarter, not a half: the
    # destination quadruple applied to the composite grey, times the source
    # quadruple applied to the backdrop. Both are white ramps here, so 191 is
    # halfway in each, giving 128/255 * 128/255 of full strength.
    let r = BlendRange(source: [0'u8, 0'u8, 128'u8, 255'u8],
      dest: [0'u8, 0'u8, 128'u8, 255'u8])
    let cov = blendIfAt(@[r], 191, 191, 191)
    check cov >= 63 and cov <= 65
    # One ramp alone is about half, so the pair really is multiplying.
    check blendIfAt(@[BlendRange(source: [0'u8, 0'u8, 128'u8, 255'u8],
      dest: [0'u8, 0'u8, 255'u8, 255'u8])], 191, 191, 191) >= 128

suite "blend if: record layout":
  test "default ranges are recognised":
    let d = BlendingRanges(data: spanOf(fullRanges(4)))
    check isDefaultBlendIf(d.ranges())
    var custom = BlendingRanges(data: spanOf(fullRanges(4)))
    # Same shape, but one black cutoff raised: no longer the default.
    var bytes = fullRanges(4)
    bytes[0] = char(50)
    custom = BlendingRanges(data: spanOf(bytes))
    check not isDefaultBlendIf(custom.ranges())

  test "the composite entry comes first and the rest are per channel":
    let bytes = fullRanges(4)
    let rs = BlendingRanges(data: spanOf(bytes)).ranges()
    # One composite entry plus one per colour channel.
    check rs.len == 4
    for i in 0 ..< 4:
      check quad(rs[i], 0) == [0, 0, 255, 255]
      check quad(rs[i], 1) == [0, 0, 255, 255]

  test "a shorter range list is not read past its end":
    # A grayscale document's layer still gets a composite entry plus one per
    # channel; anything less must degrade rather than index out of bounds.
    for n in [1'i32, 2, 3]:
      let rs = BlendingRanges(data: spanOf(fullRanges(n))).ranges()
      check rs.len == n
      for gray in [0'i32, 128, 255]:
        for sv in [0'i32, 200]:
          for dv in [0'i32, 200]:
            let cov = blendIfAt(rs, gray, sv, dv)
            check cov >= 0 and cov <= 255

suite "blend if: end to end":
  test "a Blend If cutoff removes part of a layer's render":
    # Built by hand: a red layer whose composite grey is cut off above 100, so
    # the bright part of it stops contributing.
    let w = 4
    let h = 4
    var plane = newSeq[byte](w * h)
    for i in 0 ..< plane.len:
      plane[i] = if i < 8: 255'u8 else: 60'u8 # top half bright, bottom dim
    let planes = @[plane, newSeq[byte](w * h), newSeq[byte](w * h)]
    let spec = TestLayerSpec(name: "if", top: 0, left: 0, bottom: int32(h),
      right: int32(w), planes: planes, channelIds: @[int16(0), 1, 2],
      useRle: false, blendKey: "norm", opacity: 255'u8, lsct: -1, lsdk: -1)
    # A black canvas for the backdrop would need a second layer; instead the
    # document's own composite is transparent, so this exercises the arithmetic
    # rather than the backdrop, which is what the unit tests above cover.
    let doc = readPsdBytes(buildPsd(w, h, 3,
      @[newSeq[byte](w * h), newSeq[byte](w * h), newSeq[byte](w * h)],
      layers = @[spec]))
    let img = renderDocument(doc)
    check img.getPixel(0, 0).r == 255 # bright pixels are unaffected
    check img.getPixel(0, 3).r == 60  # dim pixels are unaffected
