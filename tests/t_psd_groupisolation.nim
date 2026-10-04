## `iSO`: a pass-through group that is nonetheless isolated.
##
## Phase 8 decided pass-through versus isolated purely from a group's blend key.
## That is wrong: Photoshop writes an `iSO` block on a group whose blend mode is
## still `pass`, and such a group must be composited as a unit. Reading the mode
## alone let those children blend straight into the backdrop.

import std/options
import std/unittest
import ../src/opengraphics/psd
import ./psd_support
import ./psd_testgen

proc solid(name: string, r, g, b: byte, w = 2, h = 2,
    blendKey = "norm", opacity = 255'u8, lsct = -1, alpha = -1,
    extra: seq[tuple[key: string, payload: seq[byte]]] = @[]): TestLayerSpec =
  ## An opaque raster layer, or a zero-size divider record when `lsct >= 0`.
  ## `alpha` of -1 means no alpha channel, so the layer is fully opaque.
  var planes = @[newSeq[byte](w * h), newSeq[byte](w * h),
    newSeq[byte](w * h)]
  for i in 0 ..< w * h:
    planes[0][i] = r
    planes[1][i] = g
    planes[2][i] = b
  var ids = @[int16(0), 1, 2]
  if alpha >= 0:
    planes.add(newSeq[byte](w * h))
    planes[3] = newSeq[byte](w * h)
    for i in 0 ..< w * h:
      planes[3][i] = uint8(alpha)
    ids.add(int16(-1))
  TestLayerSpec(name: name, top: 0, left: 0, bottom: int32(h),
    right: int32(w), planes: planes, channelIds: ids, useRle: false,
    blendKey: blendKey, opacity: opacity, lsct: lsct, lsdk: -1, extra: extra)

proc docOf(specs: seq[TestLayerSpec], w = 2, h = 2): Document =
  let p = newSeq[byte](w * h)
  readPsdBytes(buildPsd(w, h, 3, @[p, p, p], layers = specs))

suite "iSO group isolation":
  test "the block parses as a typed view":
    let blk = isolationOverrideBlock(true)
    check blk.key == "iSO"
    let parsed = blk.parsed()
    check parsed.isSome
    check parsed.get().kind == bdIsolationOverride
    check parsed.get().isolated
    # And the false form, which is four bytes with a zero first byte.
    let off = isolationOverrideBlock(false)
    check off.parsed().get().isolated == false

  test "a 4-byte payload survives the round trip":
    let blk = isolationOverrideBlock(true)
    check blk.data.len == 4

  test "the generated large fixture really carries iSO":
    # Asserted rather than assumed: if the generator stopped emitting it, the
    # renderer tests below would silently stop testing anything.
    let f = readPsdFile(largeFixture())
    var n = 0
    for l in f.layers:
      if l.getBlock("iSO").isSome: inc n
    check n > 0

  test "a pass-through group with iSO is isolated, one without is not":
    # Both groups carry the blend key `pass`, so the mode alone cannot tell them
    # apart; only the `iSO` block can.
    #
    # Getting a *pixel* difference took two attempts, and the reason is worth
    # recording. A Normal child cannot show it: with an opaque Normal layer,
    # blending into the backdrop and compositing an isolated canvas give the same
    # pixels. A Multiply child cannot either, because the compositor treats a
    # fully transparent destination as "nothing below" and keeps the source
    # colour rather than multiplying it against black (mirroring libpsd, and
    # matching Photoshop). That is exactly right, and it means Multiply inside
    # an isolated group looks identical to Multiply inside a pass-through one.
    #
    # Screen on a white base does separate them:
    #   pass-through: Screen(128) against white is 255, so the group vanishes.
    #   isolated:     the isolated canvas starts transparent, so the child keeps
    #                 its own 128, and that grey is what composites over white.
    let mk = proc(withIso: bool): Document =
      var closer = solid("g", 0, 0, 0, 2, 2, "pass", 255'u8, 2)
      if withIso:
        closer.extra = @[("iSO", @[byte(1), 0'u8, 0'u8, 0'u8])]
      docOf(@[
        solid("base", 255, 255, 255),
        solid("</Layer group>", 0, 0, 0, 2, 2, "norm", 255'u8, 3),
        solid("child", 128, 128, 128, 2, 2, "scrn", 255'u8),
        closer,
      ])
    let isoDoc = mk(true)
    let passDoc = mk(false)

    # Structure first: both parse, both are groups, both say `pass`.
    for d in [isoDoc, passDoc]:
      let tree = d.layerTree()
      check tree.len == 2
      check tree[1].kind == lnGroup
      check tree[1].layer.blendMode == "pass"
      check tree[1].children.len == 1
    check isoDoc.layerTree()[1].layer.getBlock("iSO").isSome
    check passDoc.layerTree()[1].layer.getBlock("iSO").isNone

    let isoPx = renderDocument(isoDoc).getPixel(0, 0)
    let passPx = renderDocument(passDoc).getPixel(0, 0)
    check isoPx.a == 255 and passPx.a == 255
    # The discriminator.
    check passPx.r == 255 # Screen against the white backdrop saturates
    check isoPx.r > 120 and isoPx.r < 136 # the child's own grey survives

  test "a self-blended group is isolated whether or not it carries iSO":
    # The ordinary case, to confirm the override does not disturb it: a mode
    # other than pass through already forces isolation.
    var withIso = solid("g", 0, 0, 0, 2, 2, "norm", 255'u8, 2)
    withIso.extra = @[("iSO", @[byte(1), 0'u8, 0'u8, 0'u8])]
    let a = docOf(@[
      solid("base", 255, 255, 255),
      solid("</Layer group>", 0, 0, 0, 2, 2, "norm", 255'u8, 3),
      solid("child", 128, 128, 128, 2, 2, "scrn", 255'u8),
      withIso,
    ])
    let b = docOf(@[
      solid("base", 255, 255, 255),
      solid("</Layer group>", 0, 0, 0, 2, 2, "norm", 255'u8, 3),
      solid("child", 128, 128, 128, 2, 2, "scrn", 255'u8),
      solid("g", 0, 0, 0, 2, 2, "norm", 255'u8, 2),
    ])
    check renderDocument(a).getPixel(0, 0) == renderDocument(b).getPixel(0, 0)

  test "an iSO of zero does not isolate":
    # The block's payload is a flag, not merely its presence.
    let zero = docOf(@[
      solid("base", 255, 255, 255),
      solid("</Layer group>", 0, 0, 0, 2, 2, "norm", 255'u8, 3),
      solid("child", 128, 128, 128, 2, 2, "scrn", 255'u8),
      solid("g", 0, 0, 0, 2, 2, "pass", 255'u8, 2, -1,
        @[("iSO", @[byte(0), 0'u8, 0'u8, 0'u8])]),
    ])
    check zero.layerTree()[1].layer.getBlock("iSO").isSome
    # Screen against white saturates, i.e. it stayed pass-through.
    check renderDocument(zero).getPixel(0, 0).r == 255
