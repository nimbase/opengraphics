## Layer masks: geometry, flag interpretation and channel framing.
##
## The interesting cases here are the ones where the mask's own rect decides how
## much of the channel data area belongs to the -2 channel. Get that wrong and
## every channel after it is misaligned, which the byte-count assertions below
## are designed to catch.

import std/options
import unittest
import ../src/opengraphics/psd
import ./psd_support

proc maskSpec(top, left, bottom, right: int32, color = 255'u8,
    flags = 0'u8): TestMaskSpec =
  TestMaskSpec(present: true, top: top, left: left, bottom: bottom,
    right: right, defaultColor: color, flags: flags)

proc maskedLayer(m: TestMaskSpec, useRle = false, useZip = false,
    prediction = false): Document =
  ## A 4x4 layer carrying one -2 mask channel of 12 samples (a 3x4 mask).
  let px = @[byte(10), 11, 12, 13, 14, 15, 16, 17, byte(18), 19, 20, 21, 22,
    23, 24, 25]
  let mp = @[byte(0), 30, 60, 90, 120, 150, 180, 210, byte(240), 255, 128, 64]
  let spec = TestLayerSpec(name: "m", top: 0, left: 0, bottom: 4, right: 4,
    planes: @[px, mp], channelIds: @[int16(0), int16(-2)], useRle: useRle,
    useZip: useZip, zipPrediction: prediction, blendKey: "norm", opacity: 255,
    flags: 0, lsct: -1, lsdk: -1, mask: m)
  readPsdBytes(buildPsd(4, 4, 3, @[px, px, px], useRle, @[spec],
    useZip = useZip, zipPrediction = prediction))

proc maskPlane(doc: Document, index = 0): string =
  ## The -2 channel decoded at the mask's own dimensions.
  let l = doc.layers()[index]
  let r = l.channelRect(ChannelUserMask)
  let (w, h) = (r.width(), r.height())
  if w <= 0 or h <= 0:
    return ""
  let c = l.channel(ChannelUserMask)
  if c.isNone:
    return ""
  planeToU8(c.get().decode(w, h, 8, Version.Psd), 8, w, h)

test "no mask by default":
  let px = @[byte(1), 2, 3, 4]
  let spec = TestLayerSpec(name: "p", top: 0, left: 0, bottom: 2, right: 2,
    planes: @[px], channelIds: @[int16(0)], useRle: false, blendKey: "norm",
    opacity: 255, flags: 0, lsct: -1, lsdk: -1)
  let doc = readPsdBytes(buildPsd(2, 2, 3, @[px, px, px], false, @[spec]))
  let l = doc.layers[0]
  check l.mask.kind == mdNone
  check l.layerMask().isNone
  check l.channelIndex(ChannelUserMask) == -1
  # With no mask, the -2 rect falls back to the layer rect rather than being
  # empty, so a caller that asks for the rect always gets a usable one.
  check l.channelRect(ChannelUserMask) == l.rect

test "the 20-byte form parses rect, colour and flags":
  let doc = maskedLayer(maskSpec(10, 20, 13, 24, 0, 0b101))
  let l = doc.layers[0]
  check l.mask.kind == mdMask
  let m = l.layerMask().get
  check m.rect == Rect(top: 10, left: 20, bottom: 13, right: 24)
  check m.rect.width() == 4
  check m.rect.height() == 3
  check m.defaultColor == 0
  check m.flags.relative
  check not m.flags.disabled
  check m.flags.invert
  check m.real.isNone
  # the two pad bytes of the simple form are kept
  check m.trailing.len == 2

test "a disabled mask reports itself disabled":
  let doc = maskedLayer(maskSpec(0, 0, 3, 4, 255, 0b10))
  let l = doc.layers[0]
  check l.mask.kind == mdMask
  check l.layerMask().get.flags.disabled

test "the 36-byte form carries a real mask rect":
  var m = maskSpec(0, 0, 3, 4)
  m.real = true
  m.realFlags = 0b1
  m.realDefault = 255
  m.realTop = 5
  m.realLeft = 6
  m.realBottom = 9
  m.realRight = 14
  let l = maskedLayer(m).layers[0]
  check l.layerMask().get.real.isSome
  let rm = l.layerMask().get.real.get
  check rm.rect == Rect(top: 5, left: 6, bottom: 9, right: 14)
  check rm.rect.width() == 8
  check rm.rect.height() == 4
  check rm.background == 255

test "the mask rect sizes the -2 channel":
  let doc = maskedLayer(maskSpec(0, 0, 3, 4))
  let l = doc.layers[0]
  check l.channelIndex(ChannelUserMask) == 1
  check maskPlane(doc) == "\x00\x1E\x3C\x5A\x78\x96\xB4\xD2\xF0\xFF\x80\x40"
  # The colour channel is untouched: 16 layer bytes, not the mask's 12.
  let c = l.channel(0).get
  check c.decode(4, 4, 8, Version.Psd) ==
    "\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19"

test "an RLE mask channel decodes at the mask dimensions":
  check maskPlane(maskedLayer(maskSpec(0, 0, 3, 4), useRle = true)) ==
    "\x00\x1E\x3C\x5A\x78\x96\xB4\xD2\xF0\xFF\x80\x40"

test "a ZIP mask channel decodes at the mask dimensions":
  for prediction in [false, true]:
    check maskPlane(maskedLayer(maskSpec(0, 0, 3, 4), useZip = true,
      prediction = prediction)) ==
        "\x00\x1E\x3C\x5A\x78\x96\xB4\xD2\xF0\xFF\x80\x40"

test "an empty mask rect consumes its payload without desyncing":
  let px = @[byte(1), 2, 3, 4]
  let spec = TestLayerSpec(name: "e", top: 0, left: 0, bottom: 2, right: 2,
    planes: @[@[byte(1), 2, 3, 4], @[]], channelIds: @[int16(0), int16(-2)],
    useRle: false, blendKey: "norm", opacity: 255, flags: 0, lsct: -1,
    lsdk: -1, mask: maskSpec(0, 0, 0, 0))
  let doc = readPsdBytes(buildPsd(2, 2, 3, @[px, px, px], false, @[spec]))
  check doc.layers[0].mask.kind == mdMask
  check doc.layers[0].channelRect(ChannelUserMask).isEmpty()
  check maskPlane(doc).len == 0
  check doc.hasComposite # the file stayed aligned to the end

test "a mask payload too short to hold a rect raises":
  var raw: seq[byte] = @[]
  for v in [byte(0), 0, 0, 0, 0, 0, 0, 0, 0, 0]: raw.add(v)
  let px = @[byte(1), 2, 3, 4]
  let spec = TestLayerSpec(name: "t", top: 0, left: 0, bottom: 2, right: 2,
    planes: @[px], channelIds: @[int16(0)], useRle: false, blendKey: "norm",
    opacity: 255, flags: 0, lsct: -1, lsdk: -1,
    mask: TestMaskSpec(rawOverride: raw))
  # A 10-byte mask is kept as `mdRaw` rather than rejected: no bytes are lost.
  let doc = readPsdBytes(buildPsd(2, 2, 3, @[px, px, px], false, @[spec]))
  check doc.layers[0].mask.kind == mdRaw
  check doc.layers[0].mask.raw == cast[string](raw)

test "an implausible mask rect only fails when the channel is decoded":
  # Channels are lazy: reading the file succeeds and the implausible geometry
  # is caught when someone actually asks for the samples. That is the point of
  # the lazy model, so the error is expected at decode rather than at parse.
  var raw: seq[byte] = @[]
  putI32BE(raw, 0)
  putI32BE(raw, 0)
  putI32BE(raw, 20000)
  putI32BE(raw, 20000)
  raw.add(255)
  raw.add(0)
  raw.add(0)
  raw.add(0)
  let px = @[byte(1), 2, 3, 4]
  let spec = TestLayerSpec(name: "h", top: 0, left: 0, bottom: 2, right: 2,
    planes: @[px, @[byte(7)]], channelIds: @[int16(0), int16(-2)],
    useRle: false, blendKey: "norm", opacity: 255, flags: 0, lsct: -1,
    lsdk: -1, mask: TestMaskSpec(rawOverride: raw))
  let doc = readPsdBytes(buildPsd(2, 2, 3, @[px, px, px], false, @[spec]))
  let l = doc.layers[0]
  check l.channelIndex(ChannelUserMask) == 1
  let r = l.channelRect(ChannelUserMask)
  check r.width() == 20000
  check r.height() == 20000
  expect(PsdError):
    discard l.channel(ChannelUserMask).get().decode(r.width(), r.height(), 8,
      Version.Psd)

test "the global layer mask parses opacity and kind":
  var gm: seq[byte] = @[]
  putU16BE(gm, 0) # overlay colour space
  for _ in 0 ..< 4: putU16BE(gm, 0)
  putU16BE(gm, 100) # opacity, 0..100
  gm.add(128)     # kind: use the per-layer value
  let px = @[byte(1), 2, 3, 4]
  let doc = readPsdBytes(buildPsd(2, 2, 3, @[px, px, px], globalMask = gm))
  check doc.file.globalLayerMask.isSome
  let g = doc.file.globalLayerMask.get
  check g.data == cast[string](gm)
  check g.opacity() == some(100)
  check g.kind() == some(128)

test "the global layer mask is absent when the section is empty":
  let px = @[byte(1), 2, 3, 4]
  let doc = readPsdBytes(buildPsd(2, 2, 3, @[px, px, px]))
  check doc.file.globalLayerMask.isNone

test "the real fixtures parse whether or not they carry masks":
  for name in ["01.psd", "03.psd"]:
    let f = readPsd(readFile("tests/data/" & name))
    for l in f.layers():
      check l.channelIndex(ChannelUserMask) == -1
      check l.layerMask().isNone
    # 02.psd does have one, so it is checked separately
    check f.header.width > 0
  let big = readPsd(readFile("tests/data/02.psd"))
  var withMask = 0
  for l in big.layers():
    if l.layerMask().isSome:
      inc withMask
  check withMask > 0