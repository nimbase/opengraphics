import std/options
import std/sequtils
import std/strutils
import unittest
import ../src/opengraphics/psd



proc fixture(): PsdFile =
  readPsd(readFile("tests/data/01.psd"))

suite "metadata: round trip":
  test "items round-trip through the binary layout":
    var second = newMetadataItem("cust", repeat('\x09', 4))
    second.copy = true
    let items = @[newMetadataItem("cmls", "\x01\x02\x03"), second]
    let bytes = writeShmd(items)
    check parseShmd(bytes) == items

  test "odd data is zero-padded to an even length":
    let items = @[newMetadataItem("cmls", "\x01\x02\x03")]
    check items[0].data.len == 4
    check items[0].data == "\x01\x02\x03\x00"

  test "even data is left alone":
    check newMetadataItem("cmls", "\x01\x02").data == "\x01\x02"

  test "the bytes are stable across a second write":
    let bytes = writeShmd(@[newMetadataItem("cmls", "\x01\x02\x03")])
    check writeShmd(parseShmd(bytes)) == bytes

  test "a new item uses the 8BIM signature":
    let item = newMetadataItem("cmls", "")
    check item.keyString() == "cmls"
    check item.signature == [byte(ord('8')), byte(ord('B')), byte(ord('I')),
                             byte(ord('M'))]

  test "keys shorter than four bytes are padded":
    check newMetadataItem("ab", "").keyString() == "ab\x00\x00"

  test "an empty list round-trips":
    let empty: seq[MetadataItem] = @[]
    check parseShmd(writeShmd(empty)) == empty

  test "several items keep their order":
    let items = @[newMetadataItem("aaaa", "\x01"), newMetadataItem("bbbb", "\x02\x03"),
                  newMetadataItem("cccc", "\x04\x05\x06")]
    let back = parseShmd(writeShmd(items))
    check back.mapIt(it.keyString()) == @["aaaa", "bbbb", "cccc"]
    check back.mapIt(it.data) == items.mapIt(it.data)

suite "metadata: malformed input":
  test "an empty block raises":
    expect(PsdError):
      discard parseShmd("")

  test "a count with no items raises":
    expect(PsdError):
      discard parseShmd("\x00\x00\x00\x09")

  test "trailing bytes after the last item raise":
    let bytes = writeShmd(@[newMetadataItem("cmls", "\x00\x00")])
    expect(PsdError):
      discard parseShmd(bytes & "\x00")

  test "a truncated item raises":
    let bytes = writeShmd(@[newMetadataItem("cmls", "\x00\x00")])
    expect(PsdError):
      discard parseShmd(bytes[0 ..< bytes.len - 3])

  test "a truncated header raises":
    expect(PsdError):
      discard parseShmd("\x00\x00\x00\x01\x38\x42\x49")

  test "an absurd count is rejected before allocating":
    expect(PsdError):
      discard parseShmd("\xFF\xFF\xFF\xFF" & repeat('\x00', 32))

suite "metadata: the real fixtures":
  test "every layer of 01.psd carries one cust item":
    let f = fixture()
    check f.layers().len == 4
    for l in f.layers():
      check l.hasMetadata()
      let items = l.metadataOf().get()
      check items.len == 1
      check items[0].keyString() == "cust"
      check items[0].copy == false
      check items[0].data.len == 52

  test "the shmd payload is byte-exact on every layer":
    for l in fixture().layers():
      let raw = l.getBlock("shmd").get().data
      check writeShmd(parseShmd(raw)) == raw

  test "the gray fixture's layers also carry metadata":
    let f = readPsd(readFile("tests/data/03.psd"))
    check f.layers().len == 3
    for l in f.layers():
      check l.metadataOf().get().len == 1

  test "the item header is exactly 16 bytes":
    # 4 count + 16 header + 52 data
    check fixture().layers()[0].getBlock("shmd").get().data.len == 72

  test "the cust item parses as a versioned descriptor":
    # Note the trailing pad byte: a strict parse would reject it.
    let items = fixture().layers()[0].metadataOf().get()
    let vd = compositorInfo(items[0].data).get()
    check vd.version == 16
    check vd.descriptor.classId.asString() == "metadata"

  test "the descriptor carries a layerTime":
    let info = compositorInfoOf(fixture().layers()[0]).get()
    check info.descriptor.getDouble("layerTime") > 1_600_000_000.0

  test "compositorInfoOf finds cust on every layer":
    for l in fixture().layers():
      check compositorInfoOf(l).isSome

  test "a strict parse rejects the padded cust item":
    # This is why `compositorInfo` uses a prefix parse.
    let items = fixture().layers()[0].metadataOf().get()
    expect(PsdError):
      discard parseVersionedDescriptor(items[0].data)

  test "a layer without the block reports none":
    var l = fixture().layers()[0]
    l.blocks = l.blocks.filterIt(it.key != "shmd")
    check not l.hasMetadata()
    check l.metadataOf().isNone
    check compositorInfoOf(l).isNone

  test "a corrupt block reports none rather than raising":
    var l = fixture().layers()[0]
    let i = l.blocks.findIt(it.key == "shmd")
    l.blocks[i].data = toSpan("\xFF\xFF\xFF\xFF")
    check l.hasMetadata()          # the block is still there
    check l.metadataOf().isNone    # but it does not parse

suite "metadata: whole-file round trip":
  test "the fixtures still round-trip byte for byte":
    for path in ["tests/data/01.psd", "tests/data/03.psd"]:
      let bytes = readFile(path)
      check writePsd(readPsd(bytes)) == bytes