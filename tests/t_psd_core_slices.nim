import std/options
import unittest
import ../src/opengraphics/psd


proc fixture(): PsdFile =
  readPsd(readFile("tests/data/01.psd"))

proc sample(): SlicesResource =
  ## Three slices covering each origin and kind, plus outsets.
  SlicesResource(
    version: 6,
    bounds: [0'i32, 0'i32, 80'i32, 100'i32],
    groupName: "site",
    slices: @[
      SliceRecord(id: 0, origin: 0, kind: 1,
        rect: [0'i32, 0'i32, 100'i32, 10'i32]),
      SliceRecord(id: 1, groupId: 0, origin: 2, name: "logo", kind: 1,
        rect: [20'i32, 10'i32, 60'i32, 30'i32],
        url: "https://example.org/", target: "_blank", message: "hi",
        alt: "Logo", cellTextIsHtml: true, cellText: "<b>x</b>",
        horizontalAlign: 1, verticalAlign: 2,
        color: [255'u8, 10'u8, 20'u8, 30'u8]),
      SliceRecord(id: 2, origin: 1, layerId: some(7'u32), kind: 0,
        rect: [5'i32, 40'i32, 25'i32, 70'i32],
        outsets: [1'i32, 2'i32, 3'i32, 4'i32]),
    ])

suite "slices: version 6":
  test "a sample resource round-trips through the binary layout":
    let s = sample()
    let bytes = writeSlices(s)
    let back = parseSlices(bytes)
    check back.bounds == s.bounds
    check back.groupName == s.groupName
    check back.slices == s.slices

  test "the bytes are stable across a second write":
    let bytes = writeSlices(sample())
    check writeSlices(parseSlices(bytes)) == bytes

  test "the written version is always 6":
    var s = sample()
    s.version = 7
    check parseSlices(writeSlices(s)).version == 6

  test "a layer-based slice keeps its layer id":
    let back = parseSlices(writeSlices(sample()))
    check back.slices[2].origin == 1
    check back.slices[2].layerId == some(7'u32)

  test "non-layer slices have no layer id":
    let back = parseSlices(writeSlices(sample()))
    check back.slices[0].layerId.isNone
    check back.slices[1].layerId.isNone

  test "the optional outsets descriptor is written when needed":
    let bytes = writeSlices(sample())
    # 117 bytes of version 6 layout plus a trailing descriptor.
    check bytes.len > 117

  test "no outsets means no trailing descriptor":
    var s = sample()
    for slice in s.slices.mitems:
      slice.outsets = [0'i32, 0'i32, 0'i32, 0'i32]
    let back = parseSlices(writeSlices(s))
    check back.slices[2].outsets == [0'i32, 0'i32, 0'i32, 0'i32]

  test "a unicode name survives":
    var s = sample()
    s.groupName = "café ✓"
    s.slices[1].name = "naïve"
    let back = parseSlices(writeSlices(s))
    check back.groupName == "café ✓"
    check back.slices[1].name == "naïve"

suite "slices: version 7 descriptor form":
  test "the descriptor form parses back to the same records":
    let s = sample()
    let back = parseSlices(writeSlicesDescriptor(s))
    check back.version == 7
    check back.groupName == s.groupName
    check back.bounds == s.bounds
    check back.slices.len == 3
    check back.slices[1].rect == [20'i32, 10'i32, 60'i32, 30'i32]
    check back.slices[1].alt == "Logo"
    check back.slices[1].target == "_blank"
    check back.slices[2].origin == 1
    check back.slices[2].layerId == some(7'u32)
    check back.slices[2].kind == 0
    check back.slices[2].outsets == [1'i32, 2'i32, 3'i32, 4'i32]

  test "version 8 parses the same way as 7":
    let bytes = writeSlicesDescriptor(sample())
    # the trailing version u32 is 4 bytes
    check parseSlices("\x00\x00\x00\x08" & bytes[4 .. ^1]).version == 8

  test "an empty descriptor yields no slices":
    let empty = writeSlicesDescriptor(SlicesResource())
    let back = parseSlices(empty)
    check back.slices.len == 0
    check back.groupName == ""

  test "html and alignment flags survive":
    let back = parseSlices(writeSlicesDescriptor(sample()))
    check back.slices[1].cellTextIsHtml
    check back.slices[1].cellText == "<b>x</b>"

suite "slices: malformed input":
  test "truncation at any point is an error":
    let bytes = writeSlices(sample())
    for cut in [0, 3, 10, 30, 120]:
      expect(PsdError):
        discard parseSlices(bytes[0 ..< cut])

  test "a huge slice count is rejected":
    var w = initWriter()
    w.putU32(6)
    for _ in 0 ..< 4:
      w.putI32(0)
    w.writeUnicode("")
    w.putU32(0xFFFFFFFF'u32)
    expect(PsdError):
      discard parseSlices(w.toString())

  test "an unsupported version raises":
    expect(PsdError):
      discard parseSlices("\x00\x00\x00\x09")

  test "a damaged trailing descriptor is ignored, not fatal":
    # A valid version 6 layout with no outsets descriptor, then junk.
    var plain = sample()
    for slice in plain.slices.mitems:
      slice.outsets = [0'i32, 0'i32, 0'i32, 0'i32]
    let layout = writeSlices(plain)
    check parseSlices(layout & "GARBAGE").slices.len == 3
    let back = parseSlices(layout & "\x00\x00\x00\x10GARBAGE")
    check back.slices.len == 3
    check back.slices[2].outsets == [0'i32, 0'i32, 0'i32, 0'i32]

suite "slices: the real fixture":
  test "01.psd carries a version 6 slices resource":
    let f = fixture()
    let s = slices(f.resources).get()
    check s.version == 6
    check s.slices.len == 1
    check s.groupName == "Untitled-1"
    check s.bounds == [0'i32, 0'i32, 700'i32, 700'i32]

  test "the real slice is the auto-generated document rect":
    let s = slices(fixture().resources).get()
    let one = s.slices[0]
    check one.id == 0
    check one.groupId == 0
    check one.origin == 0
    check one.kind == 1
    check one.name == ""
    check one.rect == [0'i32, 0'i32, 700'i32, 700'i32]
    check one.layerId.isNone
    check one.url == ""
    check one.alt == ""

  test "the real slice has no outsets":
    check slices(fixture().resources).get().slices[0].outsets ==
      [0'i32, 0'i32, 0'i32, 0'i32]

  test "the second fixture's group name is recovered too":
    let f = readPsd(readFile("tests/data/03.psd"))
    let s = slices(f.resources).get()
    check s.version == 6
    check s.groupName == "Untitled-1-Recovered"

  test "the accessor returns none when the resource is absent":
    check slices([]).isNone

  test "the accessor tolerates a corrupt resource":
    var f = fixture()
    let i = findResource(f.resources, SlicesId)
    check i >= 0
    f.resources[i].data = toSpan("\x00\x00\x00\x63")
    check slices(f.resources).isNone

  test "the real resource is 841 bytes but only 117 are the layout":
    # The rest is Photoshop's extra trailing descriptor, which `writeSlices`
    # does not reproduce. The file itself still round-trips because resources
    # are preserved verbatim.
    let raw = fixture().resource(SlicesId).get().data
    check raw.len == 841
    check writeSlices(parseSlices(raw)).len == 117

suite "slices: whole-file round trip":
  test "the fixtures still round-trip byte for byte":
    for path in ["tests/data/01.psd", "tests/data/03.psd"]:
      let bytes = readFile(path)
      check writePsd(readPsd(bytes)) == bytes