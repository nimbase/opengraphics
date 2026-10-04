## The synthetic corpus round-trips byte for byte.
##
## Phase 9's core claim: every colour mode at every meaningful depth, under
## every compression, in both container formats, parses and re-serializes
## without losing a byte. The cases are built at the model level so they reach
## the modes and depths `PsdBuilder` deliberately refuses (Bitmap, Indexed,
## Lab, Multichannel, Duotone, 1 and 32 bits) -- those parse paths are the ones
## with the least other coverage.

import std/options
import std/unittest
import ../src/opengraphics/psd
import ./psd_testgen

suite "testgen corpus":
  test "every generated case parses and rewrites byte for byte":
    let cases = allCases()
    check cases.len > 100 # the matrix really is the whole cross product
    for c in cases:
      let bytes = writePsd(c.file)
      let parsed = readPsd(bytes)
      check parsed.header.depth == c.file.header.depth
      check parsed.header.colorMode.kind == c.file.header.colorMode.kind
      check parsed.header.channels == c.file.header.channels
      check parsed.header.width == c.file.header.width
      check parsed.header.height == c.file.header.height
      check writePsd(parsed) == bytes

  test "composites decode to the exact generated samples":
    # Round-tripping bytes proves the payload is preserved, not that it is
    # readable. Decode the merged image back and compare against the pattern.
    for mode in [ColorMode(kind: cmGrayscale), ColorMode(kind: cmRgb),
                 ColorMode(kind: cmCmyk)]:
      for depth in [8, 16]:
        for comp in [Raw, Rle, Zip, ZipPrediction]:
          let f = mergedOnly(Version.Psd, mode, depth, comp, 13, 7)
          let got = decodeMerged(readPsd(writePsd(f)))
          var want: string = ""
          for c in 0 ..< modeChannels(mode):
            want.add(patternPlane(13, 7, depth, MergedSeedBase + uint32(c)))
          check got == want

  test "layer channels decode to their generated samples":
    # Same argument one level down: the record's channels must inflate back to
    # the pattern each was built from, at every depth the corpus uses.
    for depth in [8, 16]:
      let c = layeredSeeded(Version.Psd, ColorMode(kind: cmRgb), depth, Rle)
      let parsed = readPsd(writePsd(c.file))
      let colorChannels = modeChannels(ColorMode(kind: cmRgb))
      # Only records that actually carry a colour plane were encoded from a
      # pattern: a group divider has no channels, and the empty layer's are
      # skipped entirely. Line the seeds up by that same rule.
      var withPlanes: seq[int] = @[]
      for j, rec in parsed.layers:
        let w = max(int(rec.rect.right - rec.rect.left), 0)
        let h = max(int(rec.rect.bottom - rec.rect.top), 0)
        if rec.channels.len > 0 and w > 0 and h > 0:
          withPlanes.add(j)
      check withPlanes.len == c.alphaSeeds.len
      var i = 0
      for j in withPlanes:
        let rec = parsed.layers[j]
        let w = max(int(rec.rect.right - rec.rect.left), 0)
        let h = max(int(rec.rect.bottom - rec.rect.top), 0)
        check i < c.alphaSeeds.len
        if w > 0 and h > 0:
          check rec.channels[0].decode(w, h, depth, Version.Psd) ==
            patternPlane(w, h, depth, c.alphaSeeds[i])
          # The colour planes are seeded one past alpha, per plane index. Only
          # the first `colorChannels` are colour: a masked layer also carries
          # the user mask and real mask, sized by the mask rects.
          for ci in 0 ..< colorChannels:
            check rec.channels[1 + ci].decode(w, h, depth, Version.Psd) ==
              patternPlane(w, h, depth, c.colorSeeds[i][ci])
        inc i
      check i == withPlanes.len

  test "nested groups reconstruct from the dividers":
    let f = layered(Version.Psd, ColorMode(kind: cmRgb), 8, Rle)
    let tree = readPsd(writePsd(f)).layerTree()
    # Root: Background, Neg offset, Empty, Wide, the Outer group, then one
    # layer per blend mode.
    check tree.len == 5 + 30
    check tree[0].kind == lnLayer
    check tree[0].layer.name() == "Background"
    # The empty layer keeps its degenerate rect rather than being dropped.
    check tree[2].layer.name() == "Empty"
    check tree[3].layer.rect.top == 5 and tree[3].layer.rect.left == -100
    check tree[4].kind == lnGroup
    check tree[4].layer.name() == "Outer"
    check tree[4].layer.blendMode == "pass"
    check tree[4].opened
    # Outer holds one layer and one group, the latter closed.
    check tree[4].children.len == 2
    check tree[4].children[0].layer.name() == "In outer"
    check tree[4].children[1].kind == lnGroup
    check tree[4].children[1].layer.name() == "Inner"
    check not tree[4].children[1].opened
    check tree[4].children[1].children[0].layer.name() == "Grüße"

  test "a 16-bit corpus case lifts its layer info out of an Lr16 block":
    let f = layeredSeeded(Version.Psd, ColorMode(kind: cmRgb), 16, Rle).file
    let parsed = readPsd(writePsd(f))
    check parsed.layerInfo.isSome
    check parsed.layerInfoPlacement.kind == pkGlobalBlock
    check parsed.layerInfoPlacement.key == "Lr16"
    check parsed.layers.len == f.layerInfo.get().layers.len

  test "an 8-bit corpus case keeps its layer info in the section":
    let parsed = readPsd(writePsd(layered(Version.Psd, ColorMode(kind: cmRgb),
      8, Rle)))
    check parsed.layerInfo.isSome
    check parsed.layerInfoPlacement.kind == pkSection

  test "mask parameters and the real mask survive":
    let parsed = readPsd(writePsd(layered(Version.Psd, ColorMode(kind: cmRgb),
      8, Rle)))
    var found = false
    for rec in parsed.layers:
      if rec.mask.kind == mdMask and rec.mask.mask.parameters.isSome:
        found = true
        let m = rec.mask.mask
        check m.parameters.get().userDensity.get() == 200
        check m.parameters.get().userFeather.get() == 1.5
        check m.real.isSome
        check m.real.get().rect == rectOf(0, 0, 3, 3)
        # The mask channel and the real-mask channel both made it.
        check rec.channel(ChannelUserMask).isSome
        check rec.channel(ChannelRealUserMask).isSome
    check found

  test "every blend mode in the corpus round-trips through the record key":
    let f = layered(Version.Psd, ColorMode(kind: cmRgb), 8, Rle)
    let parsed = readPsd(writePsd(f))
    var keys: seq[string] = @[]
    for rec in parsed.layers:
      if rec.blendMode notin keys:
        keys.add(rec.blendMode)
    # Every key the corpus writes comes back verbatim, including the
    # unrecognised one, which must not be mapped to a default.
    var expected: seq[string] = @["norm", "mul ", "scrn", "over", "dark", "div "]
    for rec in f.layers:
      if rec.channels.len == 0: continue
      if rec.blendMode notin expected: expected.add(rec.blendMode)
    for k in expected:
      check k in keys
    check "zzzz" in keys
    check keys.len == expected.len

  test "colour mode data is preserved per mode":
    for mode in [ColorMode(kind: cmIndexed), ColorMode(kind: cmDuotone)]:
      let parsed = readPsd(writePsd(mergedOnly(Version.Psd, mode, 8, Rle, 5, 3)))
      check parsed.colorModeData.len == colorModeData(mode).len
      check parsed.colorModeData == spanOf(colorModeData(mode))
    # Modes with no colour mode data carry a zero length, not a stray byte.
    let rgb = readPsd(writePsd(mergedOnly(Version.Psd, ColorMode(kind: cmRgb),
      8, Rle, 5, 3)))
    check rgb.colorModeData.len == 0

  test "a named resource keeps its Pascal name":
    let parsed = readPsd(writePsd(mergedOnly(Version.Psd, ColorMode(kind: cmRgb),
      8, Rle, 5, 3)))
    let named = parsed.resource(2000)
    check named.isSome
    check named.get().name == "Path 1"

  test "the global layer mask is preserved verbatim":
    let parsed = readPsd(writePsd(layered(Version.Psd, ColorMode(kind: cmRgb),
      8, Rle)))
    check parsed.globalLayerMask.isSome
    let gm = parsed.globalLayerMask.get()
    check gm.data.len == 13
    # The typed accessors see the fields the corpus set: a zero overlay colour
    # space, four colour components, an opacity of 50 percent and a kind.
    check gm.overlayColorSpace == some(0)
    check gm.colorComponents == some([0, 0, 0, 50])
    check gm.opacity == some(50)
    check gm.kind == some(128)

  test "tagged block padding follows the measured-not-assumed rule":
    let parsed = readPsd(writePsd(layered(Version.Psd, ColorMode(kind: cmRgb),
      8, Rle)))
    var sawClyr, sawZNoP = false
    for rec in parsed.layers:
      for blk in rec.blocks:
        case blk.key
        of "zOdd":
          # Three bytes of payload is already the canonical even length after
          # the usual one pad byte, so the parser normalises that pad away
          # rather than storing it. Storing it would make the writer re-emit a
          # byte the file never had.
          check blk.data.len == 3
          check blk.padding.isNone
        of "clyr":
          # One byte of payload with three pad bytes is *not* the canonical
          # single pad byte, so the real padding is measured and kept.
          sawClyr = true
          check blk.data.len == 1
          check blk.padding.isSome
          check blk.padding.get().len == 3
        of "zNop":
          sawZNoP = true
          check blk.data.len == 1
          check blk.padding.isSome
          check blk.padding.get().len == 0
        of "fxrp":
          check blk.data.len == 16
          check blk.padding.isNone
        else:
          discard
    check sawClyr
    check sawZNoP

  test "PSB uses 64-bit section lengths and 32-bit channel counts":
    let f = layered(Version.Psb, ColorMode(kind: cmRgb), 8, Rle)
    let bytes = writePsd(f)
    # The version field is the only place the container shows in the header;
    # everything else is verified by parsing and re-serialising.
    check bytes[4] == char(0) and bytes[5] == char(2)
    check writePsd(readPsd(bytes)) == bytes

  test "the corpus is deterministic":
    # A generator that depended on a clock or a hash seed would make failures
    # unreproducible. Two independent calls must agree exactly.
    for mode in [ColorMode(kind: cmBitmap), ColorMode(kind: cmIndexed),
                 ColorMode(kind: cmLab)]:
      for comp in AllCompressions:
        check writePsd(mergedOnly(Version.Psd, mode, modeDepths(mode)[0],
          comp, 9, 5)) == writePsd(mergedOnly(Version.Psd, mode,
          modeDepths(mode)[0], comp, 9, 5))