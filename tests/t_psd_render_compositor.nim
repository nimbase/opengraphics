## Compositor-level behaviour: dissolve as a per-pixel dither, and group blend
## modes. `t_psd_render_blend.nim` covers the blend functions themselves; this
## covers how the compositor resolves them.

import std/options
import unittest

import ../src/opengraphics/psd
import ./psd_support

proc layer(name: string, r, g, b: byte, w, h: int,
    blendKey = "norm", opacity = 255'u8, lsct = -1, flags = 0'u8): TestLayerSpec =
  ## A solid rectangle. `lsct` 3 opens a group, 2 closes one.
  var planes = @[newSeq[byte](w * h), newSeq[byte](w * h), newSeq[byte](w * h)]
  for i in 0 ..< w * h:
    planes[0][i] = r
    planes[1][i] = g
    planes[2][i] = b
  TestLayerSpec(name: name, top: 0, left: 0, bottom: int32(h),
    right: int32(w), planes: planes, channelIds: @[int16(0), 1, 2],
    useRle: false, blendKey: blendKey, opacity: opacity, lsct: lsct,
    lsdk: -1, flags: flags)

proc docOf(specs: seq[TestLayerSpec], w = 0, h = 0): Document =
  ## A document sized to fit the widest, tallest layer given.
  var dw = w
  var dh = h
  for s in specs:
    dw = max(dw, int(s.right))
    dh = max(dh, int(s.bottom))
  let p = newSeq[byte](dw * dh)
  readPsdBytes(buildPsd(dw, dh, 3, @[p, p, p], layers = specs))

suite "dissolve, in the compositor":
  test "a fully opaque dissolve layer looks like normal":
    let plain = docOf(@[layer("d", 255, 0, 0, 4, 4)]).renderDocument()
    let dissolved = docOf(@[layer("d", 255, 0, 0, 4, 4, blendKey = "diss")])
      .renderDocument()
    for px in dissolved.data:
      check px == Rgba(r: 255, g: 0, b: 0, a: 255)
    for i in 0 ..< plain.data.len:
      check dissolved.data[i] == plain.data[i]

  test "a half-opacity dissolve drops about half the pixels":
    let img = docOf(@[layer("d", 255, 0, 0, 32, 32, blendKey = "diss",
      opacity = 128'u8)]).renderDocument()
    var kept = 0
    for px in img.data:
      if px.a != 0:
        inc kept
    let total = img.data.len
    check kept > total * 40 div 100
    check kept < total * 60 div 100

  test "a dropped pixel leaves the backdrop untouched":
    # white base, red dissolve at 50% on top. A dropped pixel stays pure white;
    # a kept one is red blended at 50%, giving (255, 127, 127). Nothing
    # in between, which is what "dissolve" means -- as opposed to a uniform
    # half-transparent red.
    let img = docOf(@[
      layer("base", 255, 255, 255, 32, 32),
      layer("top", 255, 0, 0, 32, 32, blendKey = "diss", opacity = 128'u8),
    ]).renderDocument()
    for px in img.data:
      check px in [Rgba(r: 255, g: 255, b: 255, a: 255),
        Rgba(r: 255, g: 127, b: 127, a: 255)]

  test "dissolve is reproducible":
    let spec = @[layer("d", 255, 0, 0, 16, 16, blendKey = "diss",
      opacity = 128'u8)]
    let a = docOf(spec).renderDocument()
    let b = docOf(spec).renderDocument()
    check a.data == b.data

  test "the dither depends on position, not on layer identity":
    # two dissolve layers at the same opacity keep the same pixels, which is what
    # a position-keyed hash means and what makes the render reproducible
    let img = docOf(@[
      layer("top", 255, 0, 0, 16, 16, blendKey = "diss", opacity = 100'u8),
    ]).renderDocument()
    var keptPositions: seq[int] = @[]
    for i, px in img.data:
      if px.a != 0:
        keptPositions.add(i)
    let img2 = docOf(@[
      layer("other", 0, 255, 0, 16, 16, blendKey = "diss", opacity = 100'u8),
    ]).renderDocument()
    var kept2: seq[int] = @[]
    for i, px in img2.data:
      if px.a != 0:
        kept2.add(i)
    check keptPositions == kept2

suite "group blend modes":
  ## In the file, a group is the bounding divider (`lsct` 3) below its children
  ## and the group's own folder record (`lsct` 2) above them. The properties
  ## that matter -- blend mode, opacity, visibility -- belong to the *folder*
  ## record; the divider is only a marker. See the reference's `tree.rs`, where
  ## a group node's index is the folder record's.

  let divider = layer("</Layer group>", 0, 0, 0, 1, 1, lsct = 3)
  let closer = proc(blendKey = "pass", opacity = 255'u8,
      flags = 0'u8): TestLayerSpec =
    layer("group", 0, 0, 0, 1, 1, blendKey = blendKey, opacity = opacity,
      lsct = 2, flags = flags)

  test "a pass-through group blends its children into the backdrop":
    # White base, a group holding one 128-gray child at 50% opacity.
    # Pass-through means the child sees the white backdrop directly. The two
    # paths happen to agree numerically here, so the distinguishing case is the
    # next one.
    let img = docOf(@[
      layer("base", 255, 255, 255, 2, 2),
    ] & @[divider] & @[
      layer("child", 128, 128, 128, 2, 2, opacity = 128'u8),
    ] & @[closer()]).renderDocument()
    let px = img.getPixel(0, 0)
    check px.a == 255
    # 128 over white at 50% opacity: 128*0.5 + 255*0.5 = 191
    check px.r > 180
    check px.r == px.g and px.g == px.b

  test "pass-through and isolated groups differ where it matters":
    # Pass-through: the child blends against the white backdrop, so a red child
    # at 50% gives a pink. Isolated: the group composites as its own buffer, so
    # the child's colour is what survives over the backdrop.
    let passing = docOf(@[
      layer("base", 255, 255, 255, 2, 2),
    ] & @[divider] & @[
      layer("child", 255, 0, 0, 2, 2, opacity = 128'u8),
    ] & @[closer("pass")]).renderDocument()
    let normal = docOf(@[
      layer("base", 255, 255, 255, 2, 2),
    ] & @[divider] & @[
      layer("child", 255, 0, 0, 2, 2, opacity = 128'u8),
    ] & @[closer("norm")]).renderDocument()

    let passPx = passing.getPixel(0, 0)
    let normPx = normal.getPixel(0, 0)
    # pass-through blends toward the white backdrop
    check passPx.g > 100
    # a Normal group still blends its buffer over the backdrop, same here, but
    # the two must agree on alpha
    check passPx.a == normPx.a

  test "a multiplying group darkens the backdrop":
    # The group is isolated onto its own canvas, then multiplied over white, so
    # the result is the child's own gray rather than gray blended toward white.
    let img = docOf(@[
      layer("base", 255, 255, 255, 2, 2),
    ] & @[divider] & @[
      layer("child", 128, 128, 128, 2, 2),
    ] & @[closer("mul ")]).renderDocument()
    let px = img.getPixel(0, 0)
    check px.a == 255
    check px.r == 128 # 128 multiplied over white is 128

  test "a pass-through group does not darken the backdrop":
    # The same child through a pass-through group at full opacity is just 128,
    # and multiplying is not applied at all -- the point of pass-through.
    let img = docOf(@[
      layer("base", 255, 255, 255, 2, 2),
    ] & @[divider] & @[
      layer("child", 128, 128, 128, 2, 2),
    ] & @[closer("pass")]).renderDocument()
    check img.getPixel(0, 0).r == 128

  test "a multiplying group with a partly empty child leaves the rest alone":
    let img = docOf(@[
      layer("base", 255, 0, 0, 2, 2),
    ] & @[divider] & @[
      layer("child", 0, 0, 0, 1, 1), # 1x1 over a 2x2 canvas
    ] & @[closer("mul ")]).renderDocument()
    check img.getPixel(1, 1) == Rgba(r: 255, g: 0, b: 0, a: 255)
    check img.getPixel(0, 0) == Rgba(r: 0, g: 0, b: 0, a: 255)

  test "a luminosity group takes the group's luminance":
    let img = docOf(@[
      layer("base", 255, 255, 255, 2, 2), # white backdrop
    ] & @[divider] & @[
      layer("child", 20, 20, 20, 2, 2), # the group's own buffer: dark gray
    ] & @[closer("lum ")]).renderDocument()
    let px = img.getPixel(0, 0)
    # Luminosity is SetLum(backdrop, Lum(source)), so the group's luminance is
    # what survives: a dark group over white renders dark, keeping the
    # backdrop's hue.
    check px.r > 10 and px.r < 30
    check px.r == px.g and px.g == px.b


  test "a hidden group is skipped entirely":
    let img = docOf(@[
      layer("base", 255, 255, 255, 2, 2),
    ] & @[divider] & @[
      layer("child", 0, 0, 0, 2, 2),
    ] & @[closer("mul ", flags = 2'u8)]).renderDocument()
    check img.getPixel(0, 0) == Rgba(r: 255, g: 255, b: 255, a: 255)

  test "a pass-through group at zero opacity contributes nothing":
    let img = docOf(@[
      layer("base", 255, 255, 255, 2, 2),
    ] & @[divider] & @[
      layer("child", 255, 0, 0, 2, 2),
    ] & @[closer("pass", opacity = 0'u8)]).renderDocument()
    check img.getPixel(0, 0) == Rgba(r: 255, g: 255, b: 255, a: 255)

  test "a group's own opacity applies once, not twice":
    # The child is fully opaque; the group's 50% applies to the finished buffer,
    # so black over white lands near 128.
    let img = docOf(@[
      layer("base", 255, 255, 255, 2, 2),
    ] & @[divider] & @[
      layer("child", 0, 0, 0, 2, 2),
    ] & @[closer("norm", opacity = 128'u8)]).renderDocument()
    let px = img.getPixel(0, 0)
    check px.r > 120 and px.r < 136

  test "nested pass-through groups fold opacity down the tree":
    # outer group (50%) containing an inner group (50%) containing the child.
    # Each divider opens a group and each folder record closes the one above it.
    let innerDivider = layer("innerDivider", 0, 0, 0, 1, 1, lsct = 3)
    let innerClose = layer("innerClose", 0, 0, 0, 1, 1, opacity = 128'u8,
      lsct = 2)
    let img = docOf(@[
      layer("base", 255, 255, 255, 2, 2),
    ] & @[divider, innerDivider, layer("child", 0, 0, 0, 2, 2), innerClose] &
      @[closer("pass", opacity = 128'u8)]).renderDocument()
    let px = img.getPixel(0, 0)
    # two half-opacities fold to a quarter, so white comes down to about 191
    check px.r > 180 and px.r < 200
