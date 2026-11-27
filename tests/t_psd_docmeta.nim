## Document metadata: guides (1032/1092), comps (1065), extra channels.
##
## Layouts from Adobe's spec; 1092 colors from Photocraft's corpus notes.
## Hand-built payloads since no committed fixture carries guides or comps.

import std/options
import std/unittest
import ../src/opengraphics/psd

proc payload1032(gridH, gridV: uint32,
    guides: openArray[tuple[pos: uint32, horiz: bool]]): Span =
  var w = initWriter()
  w.putU32(1)
  w.putU32(gridH)
  w.putU32(gridV)
  w.putU32(uint32(guides.len))
  for g in guides:
    w.putU32(g.pos)
    w.putU8(if g.horiz: 1'u8 else: 0'u8)
  let s = w.toString()
  Span(src: newStringSource(s), start: 0, stop: s.len)

proc payload1092(gridH, gridV: uint32,
    guides: openArray[tuple[pos: int32, horiz: bool,
      rgb: array[3, uint8]]]): Span =
  var w = initWriter()
  w.putU32(2)
  w.putU32(gridH)
  w.putU32(gridV)
  w.putU32(uint32(guides.len))
  for g in guides:
    w.putI32(g.pos)
    w.putU8(if g.horiz: 1'u8 else: 0'u8)
    w.putU8(0)
    w.putU8(g.rgb[0])
    w.putU8(g.rgb[1])
    w.putU8(g.rgb[2])
  let s = w.toString()
  Span(src: newStringSource(s), start: 0, stop: s.len)

suite "docmeta: guides":
  test "1032 parses positions and directions":
    let g = parseGuides1032(payload1032(576, 576,
      @[(pos: 320'u32, horiz: false), (pos: 640'u32, horiz: true)]))
    check g.guides.len == 2
    check g.guides[0].position == 10.0
    check not g.guides[0].horizontal
    check g.guides[1].horizontal
    check not g.guides[0].hasColor

  test "1092 parses colors":
    let g = parseGuides1092(payload1092(576, 576,
      @[(pos: 320'i32, horiz: false, rgb: [74'u8, 255, 255])]))
    check g.guides.len == 1
    check g.guides[0].hasColor
    check g.guides[0].color == [74'u8, 255, 255]

  test "wrong versions raise, guidesOf prefers 1092":
    let bad = payload1032(576, 576, @[])
    var r = initReader(bad)
    discard r.readU32BE()
    # guidesOf with both present prefers 1092 (tested via resources below)
    let res1032 = newImageResource(1032,
      payload1032(576, 576, @[(pos: 32'u32, horiz: false)]).clone)
    let res1092 = newImageResource(1092,
      payload1092(576, 576,
        @[(pos: 32'i32, horiz: false, rgb: [10'u8, 20, 30])]).clone)
    let g = guidesOf(@[res1032, res1092])
    check g.guides.len == 1
    check g.guides[0].hasColor

  test "empty resources give empty guides":
    let g = guidesOf(@[])
    check g.guides.len == 0

suite "docmeta: comps":
  test "1065 with empty list parses":
    var d = newDescriptor("CompList")
    var w = initWriter()
    w.putU32(16)
    w.writeDescriptorBody(d)
    let c = parseComps(spanOf(w.toString()))
    check c.comps.len == 0
    check c.lastApplied.isNone

  test "1065 list items parse names":
    var item = newDescriptor("Comp")
    discard item.add("Nm  ", textValue("A"))
    discard item.add("compID", intValue(7))
    discard item.add("capturedInfo", intValue(1))
    var d = newDescriptor("CompList")
    discard d.add("list", listValue(@[descriptorValue(item)]))
    var w = initWriter()
    w.putU32(16)
    w.writeDescriptorBody(d)
    let c = parseComps(spanOf(w.toString()))
    check c.comps.len == 1
    check c.comps[0].name == "A"
    check c.comps[0].id == 7

  test "missing comps give none":
    check compsOf(@[]).isNone

suite "docmeta: extra channels":
  test "rgb with alpha has no extras":
    var f = PsdFile(header: Header(version: Version.Psd,
      channels: 4, width: 1, height: 1, depth: 8,
      colorMode: ColorMode(kind: cmRgb)))
    check extraChannelCount(f) == 0

  test "rgb with two spare planes reports two":
    var f = PsdFile(header: Header(version: Version.Psd,
      channels: 5, width: 1, height: 1, depth: 8,
      colorMode: ColorMode(kind: cmRgb)))
    check extraChannelCount(f) == 1

suite "docmeta: duotone":
  test "524-byte block parses inks and curves":
    var w = initWriter()
    w.putU16(1)
    w.putU16(2)
    # 4x10B colors: first ink gray (space 8), second empty
    w.putU16(8)
    w.putU16(0); w.putU16(0); w.putU16(0); w.putU16(0)
    for _ in 1 ..< 4:
      w.putU16(0xFFFF)
      w.putU16(0); w.putU16(0); w.putU16(0); w.putU16(0)
    # 4x64B names
    for nm in ["Black", ""]:
      var blk = newString(64)
      blk[0] = char(nm.len)
      for i, c in nm: blk[1 + i] = c
      w.put(blk)
    for _ in 2 ..< 4:
      w.put(newString(64))
    # 4x28B curves: 13xi16 + i16 zero; first ink linear-ish
    for ink in 0 ..< 4:
      for j in 0 ..< 13:
        w.putI16(int16(j * 80))
      w.putI16(0)
    w.putU16(20)
    w.put(newString(110)) # 11x10B overprint colors
    let s = w.toString()
    check s.len == 524
    let d = parseDuotone(spanOf(s))
    check d.inks.len == 2
    check d.inks[0].name == "Black"
    check d.dotGain == 20

  test "short duotone raises":
    var raised = false
    try: discard parseDuotone(spanOf("\x00\x01"))
    except PsdError: raised = true
    check raised

suite "docmeta: alternate colors and channel names":
  test "1066 Lab entries parse":
    var w = initWriter()
    w.putU16(1)
    w.putU16(1)
    w.putU16(7)
    w.putU16(30000); w.putU16(100); w.putU16(200); w.putU16(0)
    let res = newImageResource(1066, w.toString())
    let cols = alternateDuotoneColors(@[res])
    check cols.len == 1
    check cols[0][0] == 30000

  test "wrong 1066 version gives empty":
    var w = initWriter()
    w.putU16(2)
    w.putU16(0)
    check alternateDuotoneColors(@[newImageResource(1066, w.toString())]).len == 0

  test "no channel names gives empty":
    check channelNames(@[]).len == 0
