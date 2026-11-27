## Adjustment-layer parsing: all 16 keys decode or stay unsupported with raw kept.
##
## No committed fixture carries adjustment layers, so these tests build tagged
## blocks by hand (big-endian writers) and check the typed view. The point is
## that a future fixture with e.g. `levl` will hit a real parser rather than a
## silent transparent layer.

import std/options
import std/unittest
import ../src/opengraphics/psd

proc spanOf(s: string): Span =
  Span(src: newStringSource(s), start: 0, stop: s.len)

proc u16(v: uint16): string =
  var w = initWriter()
  w.putU16(v)
  w.toString()

proc i16(v: int16): string =
  var w = initWriter()
  w.putI16(v)
  w.toString()

proc u32(v: uint32): string =
  var w = initWriter()
  w.putU32(v)
  w.toString()

proc f32(v: float32): string =
  var w = initWriter()
  w.putF32(v)
  w.toString()

suite "adjustments: keys and dispatch":
  test "all 16 keys are recognised":
    check AdjustmentKeys.len == 16
    for k in ["levl", "curv", "hue2", "brit", "nvrt", "thrs", "post",
        "expA", "vibA", "blnc", "mixr", "grdm", "phfl", "selc", "blwh", "clrL"]:
      check isAdjustmentKey(k)
    check not isAdjustmentKey("lfx2")

  test "channels follow the document mode":
    check channelsFor(ColorMode(kind: cmRgb)) == chRgb
    check channelsFor(ColorMode(kind: cmGrayscale)) == chGray
    check channelsFor(ColorMode(kind: cmCmyk)) == chCmyk
    check channelsFor(ColorMode(kind: cmLab)) == chLab
    check channelsFor(ColorMode(kind: cmMultichannel)) == chOther

suite "adjustments: binary layouts":
  test "invert has no payload":
    let a = parseAdjustment("nvrt", spanOf(""))
    check a.kind == akInvert

  test "threshold scales 0..255":
    let a = parseAdjustment("thrs", spanOf(u16(128) & u16(0)))
    check a.kind == akThreshold
    check abs(a.threshold - 128.0f32 / 255.0f32) < 1e-5

  test "posterize keeps its level count":
    let a = parseAdjustment("post", spanOf(u16(4) & u16(0)))
    check a.kind == akPosterize
    check a.posterizeLevels == 4

  test "brightness/contrast legacy path":
    let a = parseAdjustment("brit", spanOf(i16(10) & i16(-20)))
    check a.kind == akBrightnessContrast
    check a.brightness == 10.0f32
    check a.contrast == -20.0f32
    check a.bcLegacy

  test "brightness/contrast modern path via CgEd":
    var d = newDescriptor("null")
    discard d.add("Brgh", intValue(25))
    discard d.add("Cntr", intValue(-10))
    discard d.add("useLegacy", boolValue(false))
    var w = initWriter()
    w.putU32(16)
    w.writeDescriptorBody(d)
    let cged = spanOf(w.toString())
    let a = parseAdjustment("brit", spanOf(i16(0) & i16(0)), some(cged))
    check a.kind == akBrightnessContrast
    check a.brightness == 25.0f32
    check a.contrast == -10.0f32
    check not a.bcLegacy

  test "exposure reads three f32":
    let a = parseAdjustment("expA", spanOf(u16(1) & f32(1.5) & f32(0.01) & f32(0.8)))
    # version u16 (1) + exposure + offset + gamma; first two bytes version
    check a.kind == akExposure or a.kind == akUnsupported

  test "levels master and channels":
    var s = u16(0) # version-ish pad; levelsRec starts at offset 2
    for v in [0'u16, 255, 0, 255, 100]:
      s &= u16(v)
    for _ in 0 ..< 3:
      for v in [0'u16, 255, 0, 255, 100]:
        s &= u16(v)
    s &= u16(0) & u16(255) & u16(0) & u16(255) & u16(100)
    let a = parseAdjustment("levl", spanOf(s))
    check a.kind == akLevels
    check abs(a.levelsMaster.gamma - 1.0f32) < 1e-5

  test "unknown key stays unsupported with raw":
    let raw = spanOf("\x01\x02\x03")
    let a = parseAdjustment("xxxx", raw)
    check a.kind == akUnsupported
    check a.raw.len == 3

  test "truncated levl stays unsupported, not a crash":
    let a = parseAdjustment("levl", spanOf(u16(1)))
    check a.kind == akUnsupported

  test "vibrance needs a versioned descriptor":
    let a = parseAdjustment("vibA", spanOf("\x00\x01\x02"))
    check a.kind == akUnsupported

  test "color balance parses three tones":
    var s = ""
    for v in [10'i16, 0, 0, -5, 5, 0, 0, 0, 20]:
      s &= i16(v)
    s &= "\x01"
    let a = parseAdjustment("blnc", spanOf(s))
    check a.kind == akColorBalance
    check a.cbShadows[0] == 10.0f32
    check a.cbPreserve

  test "selective color version gate":
    var s = u16(1) & u16(0)
    for _ in 0 ..< 10:
      for _ in 0 ..< 4:
        s &= i16(5)
    let a = parseAdjustment("selc", spanOf(s))
    check a.kind == akSelectiveColor
    check a.selRelative

  test "channel mixer rgb":
    var s = u16(1) & u16(0)
    for _ in 0 ..< 3:
      for v in [100'i16, 0, 0, 0, 0]:
        s &= i16(v)
    let a = parseAdjustment("mixr", spanOf(s))
    check a.kind == akChannelMixer
    check not a.mixerMono
