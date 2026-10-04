import std/options
import unittest
import ../src/opengraphics/psd


proc rawBlock(key, data: string, padding: Option[seq[byte]] = none(seq[byte]),
    sig = "8BIM", version = Version.Psd): string =
  ## Serialize one block the way the writer would.
  var w = initWriter()
  w.putStr4(sig)
  w.putStr4(key)
  w.putLen(int64(data.len), usesLongLength(version, key))
  w.put(data)
  if padding.isSome:
    for x in padding.get():
      w.putU8(x)
  elif (data.len and 1) != 0:
    w.putU8(0)
  w.toString()

proc parseOne(s: string, version = Version.Psd): TaggedBlock =
  var r = initReader(s)
  let got = readBlocks(r, version)
  got.blocks[0]

suite "tagged: section types":
  test "codes 0..3 round-trip":
    for (kind, code) in [(stOther, 0'u32), (stOpenFolder, 1'u32),
        (stClosedFolder, 2'u32), (stBoundingDivider, 3'u32)]:
      let s = sectionTypeFromU32(code)
      check s.kind == kind
      check s.toU32() == code

  test "an unknown code keeps its raw value":
    let s = sectionTypeFromU32(9'u32)
    check s.kind == stUnknown
    check s.raw == 9'u32
    check s.toU32() == 9'u32

  test "folder and divider predicates":
    check sectionTypeFromU32(1'u32).isFolder()
    check sectionTypeFromU32(2'u32).isFolder()
    check not sectionTypeFromU32(0'u32).isFolder()
    check sectionTypeFromU32(3'u32).isDivider()

suite "tagged: PSB long-length keys":
  test "only the 13 listed keys widen in PSB":
    check usesLongLength(Version.Psb, "Lr16")
    check usesLongLength(Version.Psb, "PxSD")
    check usesLongLength(Version.Psb, "FMsk")
    check not usesLongLength(Version.Psb, "luni")
    check not usesLongLength(Version.Psd, "Lr16")

  test "there are exactly 13 long keys":
    check PsbLongKeys.len == 13

  test "a long key uses a 64-bit length in PSB":
    let b = rawBlock("Lr16", "abcd", version = Version.Psb)
    check b.len == 8 + 8 + 4
    let parsed = parseOne(b, Version.Psb)
    check parsed.key == "Lr16"
    check parsed.data == "abcd"

  test "the same key stays 32-bit in PSD":
    check rawBlock("Lr16", "abcd", version = Version.Psd).len == 8 + 4 + 4

suite "tagged: round-trip":
  test "an even-length block needs no padding":
    var r = initReader(rawBlock("luni", "abcd"))
    let got = readBlocks(r, Version.Psd)
    check got.blocks.len == 1
    check got.blocks[0].data == "abcd"
    check got.blocks[0].padding.isNone
    check got.trailing.len == 0
    var w = initWriter()
    writeBlocks(w, got.blocks, Version.Psd)
    check w.toString() == rawBlock("luni", "abcd")

  test "an odd-length block gets one canonical pad byte":
    let raw = rawBlock("luni", "abc")
    check raw.len == 8 + 4 + 3 + 1
    let parsed = parseOne(raw)
    check parsed.data == "abc"
    check parsed.padding.isNone # canonical, so not stored
    var w = initWriter()
    writeBlocks(w, [parsed], Version.Psd)
    check w.toString() == raw

  test "non-canonical padding is preserved exactly":
    # three pad bytes where the canonical form needs one
    let raw = rawBlock("luni", "abc", some(@[byte(0), 0, 0]))
    let parsed = parseOne(raw)
    check parsed.padding.isSome
    check parsed.padding.get().len == 3
    var w = initWriter()
    writeBlocks(w, [parsed], Version.Psd)
    check w.toString() == raw

  test "non-zero padding is preserved":
    let raw = rawBlock("luni", "abc", some(@[byte(0x41)]))
    let parsed = parseOne(raw)
    check parsed.padding.isSome
    var w = initWriter()
    writeBlocks(w, [parsed], Version.Psd)
    check w.toString() == raw

  test "a misaligned block with no padding still round-trips":
    let raw = rawBlock("luni", "abc", some(newSeq[byte](0)))
    let parsed = parseOne(raw)
    check parsed.padding.isSome
    check parsed.padding.get().len == 0
    var w = initWriter()
    writeBlocks(w, [parsed], Version.Psd)
    check w.toString() == raw

  test "the 8B64 signature is preserved":
    let raw = rawBlock("luni", "abcd", sig = "8B64")
    let parsed = parseOne(raw)
    check parsed.signature == "8B64"
    var w = initWriter()
    writeBlocks(w, [parsed], Version.Psd)
    check w.toString() == raw

  test "several blocks round-trip in order":
    var raw = rawBlock("luni", "abcd") & rawBlock("lyid", "1234") &
      rawBlock("zzzz", "xyz")
    var r = initReader(raw)
    let got = readBlocks(r, Version.Psd)
    check got.blocks.len == 3
    check got.blocks[0].key == "luni"
    check got.blocks[1].key == "lyid"
    check got.blocks[2].key == "zzzz"
    var w = initWriter()
    writeBlocks(w, got.blocks, Version.Psd)
    raw = w.toString()
    check raw.len > 0

  test "trailing bytes are returned rather than guessed at":
    var r = initReader(rawBlock("luni", "abcd") & "trailing junk")
    let got = readBlocks(r, Version.Psd)
    check got.blocks.len == 1
    check got.trailing == "trailing junk"

  test "a few trailing zero bytes are read as the block's padding":
    # documented behaviour: up to 3 zero bytes at the end of a region are
    # attributed to the last block's padding rather than to trailing bytes
    var r = initReader(rawBlock("luni", "abcd") & "\x00\x00")
    let got = readBlocks(r, Version.Psd)
    check got.blocks.len == 1
    check got.trailing.len == 0
    check got.blocks[0].padding.isSome
    check got.blocks[0].padding.get().len == 2
    var w = initWriter()
    writeBlocks(w, got.blocks, Version.Psd)
    check w.toString() == rawBlock("luni", "abcd") & "\x00\x00"

  test "eight trailing zero bytes stay as trailing data":
    var r = initReader(rawBlock("luni", "abcd") & "\x00\x00\x00\x00\x00\x00\x00\x00")
    let got = readBlocks(r, Version.Psd)
    check got.blocks.len == 1
    check got.trailing.len == 8

  test "a block claiming more bytes than remain raises":
    var w = initWriter()
    w.putStr4("8BIM")
    w.putStr4("luni")
    w.putU32(0xFFFF)
    var r = initReader(w.toString())
    expect(PsdError):
      discard readBlocks(r, Version.Psd)

  test "encodedLen matches the bytes actually written":
    for key in ["luni", "lclr", "Lr16"]:
      let data = if key == "lclr": "abcde" else: "abcd"
      let version = if key == "Lr16": Version.Psb else: Version.Psd
      let raw = rawBlock(key, data, version = version)
      let parsed = parseOne(raw, version)
      check parsed.encodedLen(version) == raw.len

suite "tagged: typed access":
  test "luni decodes to a name":
    let d = parseOne(rawBlock("luni", "\x00\x00\x00\x02\x00A\x00B")).parsed().get()
    check d.kind == bdUnicodeName
    check d.name == "AB"

  test "lyid decodes to a layer id":
    let d = parseOne(rawBlock("lyid", "\x00\x00\x00\x2A")).parsed().get()
    check d.kind == bdLayerId
    check d.layerId == 42'u32

  test "lsct decodes a 4-byte divider":
    let d = parseOne(rawBlock("lsct", "\x00\x00\x00\x01")).parsed().get()
    check d.kind == bdSectionDivider
    let sd = d.divider
    check sd.sectionType().kind == stOpenFolder
    check not sd.hasBlendMode

  test "lsct decodes a 12-byte divider with a blend mode":
    let d = parseOne(rawBlock("lsct",
      "\x00\x00\x00\x018BIMPssM\x00\x00\x00\x00")).parsed().get()
    let sd = d.divider
    check sd.sectionType().kind == stOpenFolder
    check sd.hasBlendMode
    check sd.blendMode == "PssM"
    check sd.subType == 0'u32

  test "lsct rejects a bad inner signature":
    let b = TaggedBlock(signature: "8BIM", key: "lsct",
      data: toSpan("\x00\x00\x00\x01XXXXpass"), padding: none(Span))
    check b.parsed().isNone

  test "clbl and infx decode a flag":
    for key in ["clbl", "infx"]:
      let d = parseOne(rawBlock(key, "\x01\x00\x00\x00")).parsed().get()
      check d.flag == true
      let z = parseOne(rawBlock(key, "\x00\x00\x00\x00")).parsed().get()
      check z.flag == false

  test "knko, lspf, lclr and iOpa decode":
    check parseOne(rawBlock("knko", "\x02\x00\x00\x00")).parsed().get().knockout == 2'u8
    check parseOne(rawBlock("lspf", "\x00\x00\x00\x07")).parsed().get().protection == 7'u32
    check parseOne(rawBlock("lclr", "\x00\x05\x00\x00\x00\x00\x00\x00")).parsed().get().color == 5'u16
    check parseOne(rawBlock("iOpa", "\x80\x00\x00\x00")).parsed().get().fillOpacity == 128'u8

  test "lnsr keeps its four bytes":
    let d = parseOne(rawBlock("lnsr", "cust")).parsed().get()
    check d.kind == bdNameSource
    check d.source == "cust"

  test "shmd hands back the raw bytes":
    let d = parseOne(rawBlock("shmd", "rawmeta")).parsed().get()
    check d.kind == bdMetadataSetting
    check d.metadata == "rawmeta"

  test "unmodelled keys return none so the caller falls back to data":
    for key in ["lfx2", "TySh", "SoLd", "vmsk", "vsms", "vscg", "Patt"]:
      check parseOne(rawBlock(key, "whatever")).parsed().isNone

  test "a truncated known key returns none rather than raising":
    check parseOne(rawBlock("lyid", "\x00")).parsed().isNone
    check parseOne(rawBlock("luni", "\x00\x00")).parsed().isNone
    check parseOne(rawBlock("iOpa", "")).parsed().isNone

suite "tagged: constructors":
  test "unicodeNameBlock writes a NUL-terminated 4-aligned payload":
    let b = unicodeNameBlock("Hi")
    check b.key == "luni"
    check (b.data.len and 3) == 0
    let d = b.parsed().get()
    check d.name == "Hi"

  test "sectionDividerBlock emits 4, 12 or 16 bytes":
    check sectionDividerBlock(sectionTypeFromU32(1'u32)).data.len == 4
    check sectionDividerBlock(sectionTypeFromU32(1'u32), "pass").data.len == 12
    check sectionDividerBlock(sectionTypeFromU32(3'u32), "pass",
      some(1'u32)).data.len == 16

  test "layerIdBlock round-trips":
    check layerIdBlock(99'u32).parsed().get().layerId == 99'u32

  test "sheetColorBlock is the 8-byte shape Photoshop uses":
    var w = initWriter()
    w.put(sheetColorBlock(4'u16).data)
    check w.toString() == "\x00\x04\x00\x00\x00\x00\x00\x00"

  test "constructors round-trip through the parser":
    let blocks = [unicodeNameBlock("Layer"), layerIdBlock(7'u32),
      sectionDividerBlock(sectionTypeFromU32(2'u32), "pass"),
      fillOpacityBlock(200'u8), protectionBlock(3'u32),
      nameSourceBlock("cust")]
    var w = initWriter()
    writeBlocks(w, blocks, Version.Psd)
    var r = initReader(w.toString())
    let got = readBlocks(r, Version.Psd)
    check got.blocks.len == blocks.len
    for i in 0 ..< blocks.len:
      check got.blocks[i].key == blocks[i].key
      check got.blocks[i].data == blocks[i].data

suite "tagged: lookup":
  test "findBlock and getBlock agree":
    let blocks = [layerIdBlock(1'u32), fillOpacityBlock(2'u8)]
    check findBlock(blocks, "lyid") == 0
    check findBlock(blocks, "iOpa") == 1
    check findBlock(blocks, "zzzz") == -1
    check getBlock(blocks, "lyid").isSome
    check getBlock(blocks, "zzzz").isNone
