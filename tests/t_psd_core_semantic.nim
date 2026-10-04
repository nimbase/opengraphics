import std/math
import std/strutils
import std/options
import unittest
import ../src/opengraphics/psd



proc fixture(): seq[LayerRecord] =
  readPsd(readFile("tests/data/01.psd")).layers()

proc rectForTest(): Rect =
  Rect(top: 0, left: 0, bottom: 10, right: 10)

proc vecMaskBlock(key: string, version: uint32): TaggedBlock =
  ## A minimal `vmsk` / `vsms` block: version and flags, no records.
  var w = initWriter()
  w.putU32(version)
  w.putU32(0'u32)
  newTaggedBlock(key, w.toString())

suite "semantic: type layers":
  test "layer 2's text comes out of the descriptor, not a byte scan":
    let t = fixture()[2].textOf().get()
    check t.text == "Efficient, expressive, elegant"
    check t.hasText

  test "the engine text preserves the paragraph line breaks":
    let t = fixture()[3].textOf().get()
    check t.engineText.contains("Nim is a statically typed compiled")
    check t.engineText.contains("mature languages like Python")
    # CR is normalised to LF
    check '\r' notin t.engineText
    check t.engineText.count('\n') >= 2

  test "the descriptor text keeps its raw line breaks":
    # the Txt  field is untouched, unlike the editor text
    let t = fixture()[3].textOf().get()
    check t.text.contains("Nim is a statically typed")

  test "fonts come from the font set, without unrelated names":
    let t = fixture()[2].textOf().get()
    check t.fontNames == @["ArialMT", "AdobeInvisFont", "MyriadPro-Regular"]
    # colour-profile names must not leak in
    for n in t.fontNames:
      check "PhotoshopKinsoku" notin n
      check "Normal RGB" notin n

  test "font sizes are read from the engine data":
    let a = fixture()[2].textOf().get()
    let b = fixture()[3].textOf().get()
    check a.fontSizes.len >= 2
    check a.fontSizes[0] == 40.0
    check b.fontSizes[0] == 23.0

  test "the transform is read as six doubles":
    let t = fixture()[2].textOf().get()
    check t.transform[0] == 1.0
    check t.transform[1] == 0.0
    check t.transform[2] == 0.0
    check t.transform[3] == 1.0
    check abs(t.transform[4] - 60.06) < 0.1
    check abs(t.transform[5] - 357.75) < 0.1

  test "the header is reported":
    let t = fixture()[2].textOf().get()
    check t.version == 1
    check t.textVersion == 50

  test "the raw payload is preserved on the result":
    let l = fixture()[2]
    let t = l.textOf().get()
    check t.raw == l.getBlock("TySh").get().data

  test "only the two real text layers report as text":
    let ls = fixture()
    check not ls[0].isTextLayer()   # shape layer
    check not ls[1].isTextLayer()   # smart object, despite the name
    check ls[2].isTextLayer()
    check ls[3].isTextLayer()
    check ls[0].textOf().isNone
    check ls[1].textOf().isNone

  test "a short payload raises":
    expect(PsdError):
      discard parseTextEngine("too short")

  test "a wrong header version raises":
    var w = initWriter()
    w.putU16(2'u16) # unsupported version
    for _ in 0 ..< 6:
      w.putF64(0.0)
    w.putU16(50'u16)
    w.putU32(16'u32)
    expect(PsdError):
      discard parseTextEngine(w.toString())

  test "a wrong descriptor version raises":
    var w = initWriter()
    w.putU16(1'u16)
    for _ in 0 ..< 6:
      w.putF64(0.0)
    w.putU16(50'u16)
    w.putU32(15'u32)
    expect(PsdError):
      discard parseTextEngine(w.toString())

suite "semantic: engine data scanning":
  test "normalizeReturns turns CR and CRLF into LF":
    check normalizeReturns("a\r\nb") == "a\nb"
    check normalizeReturns("a\rb") == "a\nb"
    check normalizeReturns("a\nb") == "a\nb"

  test "extractParen handles nesting and escapes":
    check extractParen("(abc)", 0) == "abc"
    check extractParen("(a(b)c)", 0) == "a(b)c"
    check extractParen("(a\\)b)", 0) == "a\\)b"
    check extractParen("no parens", 0) == ""

  test "decodeParenString reads a UTF-16BE string with a BOM":
    check decodeParenString("\xFE\xFF\x00A\x00B") == "AB"
    check decodeParenString("plain") == "plain"

  test "extractEditorText finds the text across separate lines":
    let engine = "<<\n\t/Editor\n\t<<\n\t\t/Text (hello)\n\t>>\n>>"
    check extractEditorText(engine) == "hello"

  test "extractEditorText returns empty when there is no Editor":
    check extractEditorText("<< /FontSet [] >>") == ""

  test "fontSetSlice scopes to the bracket-balanced section":
    let engine = "/Name (outside) /FontSet [ /Name (inside) ] /Name (after)"
    check fontSetSlice(engine) == "[ /Name (inside) ]"
    check extractFontNames(engine) == @["inside"]

  test "fontSetSlice falls back to the whole document":
    check fontSetSlice("/Name (only)") == "/Name (only)"

  test "extractFontSizes reads every size":
    let engine = "/StyleRun << /FontSize 40.0 >> /StyleRun << /FontSize 12.5 >>"
    check extractFontSizes(engine) == @[40.0, 12.5]

suite "semantic: shape fills":
  test "layer 0's fill is the navy solid colour":
    let l = fixture()[0]
    check l.hasFillContent()
    let fc = l.fillContent().get()
    check fc.key == "SoCo"
    check fc.solid.isSome
    let s = fc.solid.get()
    # the fixture's rectangle fill is a near-black navy
    check abs(s.red - 23.0) < 0.5
    check abs(s.green - 25.0) < 0.5
    check abs(s.blue - 33.0) < 0.5

  test "a non-SoCo content key is reported but not decoded":
    let fc = parseFillContent("GrFlsome payload")
    check fc.key == "GrFl"
    check fc.solid.isNone
    check fc.raw == "GrFlsome payload"

  test "a short payload raises":
    expect(PsdError):
      discard parseFillContent("ab")

  test "only layer 0 has a fill":
    for i in [1, 2, 3]:
      check not fixture()[i].hasFillContent()

suite "semantic: vector masks":
  test "layer 0 exposes the shape geometry":
    let l = fixture()[0]
    check l.hasVectorMask()
    let vm = l.vectorMask().get()
    check vm.path.records.len == 7
    check vm.path.subpaths()[0].knots.len == 4

  test "vsms is preferred over vmsk":
    var l = LayerRecord(rect: rectForTest())
    l.blocks = @[
      vecMaskBlock("vmsk", 3'u32),
      vecMaskBlock("vsms", 5'u32),
    ]
    check l.vectorMask().get().version == 5

  test "a layer with neither key reports none":
    check fixture()[1].vectorMask().isNone
    check not fixture()[1].hasVectorMask()

suite "semantic: smart objects":
  test "layer 1's placed layer is fully decoded":
    let l = fixture()[1]
    check l.isSmartObject()
    let pl = l.placedLayer().get()
    check pl.uniqueId.len > 0
    check pl.placedId.len > 0
    check pl.hasPage
    check pl.page == 1
    check pl.hasTransform
    # four placed corners as x,y pairs
    check pl.transform[0] != 0.0 or pl.transform[1] != 0.0
    check pl.hasWarp
    check pl.warpStyle == "warpNone"
    check pl.hasSize
    check abs(pl.width - 177.6) < 0.5
    check abs(pl.height - 48.8) < 0.5
    check pl.hasResolution
    check pl.resolution == 72.0
    check pl.resolutionUnit == "#Rsl"

  test "the raw payload is preserved":
    let l = fixture()[1]
    check l.placedLayer().get().raw == l.getBlock("SoLd").get().data

  test "non-smart-object layers report none":
    check fixture()[0].placedLayer().isNone
    check not fixture()[0].isSmartObject()

  test "a wrong signature raises":
    expect(PsdError):
      discard parsePlacedLayer("XXXX\x00\x00\x00\x04")

  test "a short payload raises":
    expect(PsdError):
      discard parsePlacedLayer("soLD")

  test "an unsupported block version raises":
    expect(PsdError):
      discard parsePlacedLayer("soLD\x00\x00\x00\x09")

suite "semantic: the real fixture as a whole":
  test "every layer's kind is identified":
    let ls = fixture()
    check ls[0].hasVectorMask()
    check ls[0].hasFillContent()
    check ls[1].isSmartObject()
    check ls[2].isTextLayer()
    check ls[3].isTextLayer()
proc buildTestPlLd(uuid: string, transform: array[8, float64]): string =
  ## A minimal `PlLd` fixed struct: "plcL", version 3, a 37-byte `$`-uuid,
  ## four opaque u32 fields, then eight f64 corners.
  var w = initWriter()
  w.putStr4("plcL")
  w.putU32(3)
  w.put(uuid)
  for _ in 0 ..< 4: w.putU32(0)
  for t in transform: w.putF64(t)
  w.toString()

proc plLdWithVersion(version: uint32, uuid: string): string =
  var w = initWriter()
  w.putStr4("plcL")
  w.putU32(version)
  w.put(uuid)
  for _ in 0 ..< 4: w.putU32(0)
  for _ in 0 ..< 8: w.putF64(0.0)
  w.toString()

suite "semantic: PlLd smart objects":
  test "a fixed-struct PlLd parses its uuid and corners":
    let tf: array[8, float64] = [1, 0, 0, 1, 10, 20, 30, 40]
    let p = parsePlacedLayer(buildTestPlLd(
      "$01234567-89ab-cdef-0123-456789abcdef", tf))
    check p.kind == "PlLd"
    check p.version == 3
    check p.uniqueId == "$01234567-89ab-cdef-0123-456789abcdef"
    check p.hasTransform
    check p.transform == tf
    # the fixed struct carries none of the descriptor-only fields
    check not p.hasPage
    check not p.hasSize
    check not p.hasWarp

  test "the PlLd tail is preserved verbatim":
    var bytes = buildTestPlLd("$01234567-89ab-cdef-0123-456789abcdef",
      [1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]) & "TRAILING"
    let p = parsePlacedLayer(bytes)
    check p.trailing == "TRAILING"
    check p.raw == bytes

  test "an empty PlLd tail is empty, not garbage":
    let p = parsePlacedLayer(buildTestPlLd(
      "$01234567-89ab-cdef-0123-456789abcdef",
      [1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]))
    check p.trailing.len == 0

  test "a short PlLd raises":
    expect(PsdError):
      discard parsePlacedLayer("plcL" & "\x00\x00\x00\x03")

  test "an unsupported PlLd version raises":
    expect(PsdError):
      discard parsePlacedLayer(plLdWithVersion(9,
        "$01234567-89ab-cdef-0123-456789abcdef"))

  test "a uuid with illegal characters raises":
    expect(PsdError):
      discard parsePlacedLayer(plLdWithVersion(3,
        "not a legal uuid at all, 37 bytes long ok!!"))

  test "PlLd counts as a smart object and SoLd wins when both are present":
    var l = LayerRecord(rect: rectForTest())
    l.blocks = @[newTaggedBlock("PlLd", buildTestPlLd(
      "$01234567-89ab-cdef-0123-456789abcdef",
      [1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]))]
    check l.isSmartObject()
    check l.placedLayer().get().kind == "PlLd"

  test "a layer with only PlLd is a smart object":
    var l = LayerRecord(rect: rectForTest())
    check not l.isSmartObject()
    check l.placedLayer().isNone

  test "the real fixture carries both, and SoLd wins":
    # 01.psd's smart-object layer has an `SoLd` and a `PlLd`. Photoshop writes
    # the older fixed struct alongside the descriptor one; `SoLd` is the richer
    # of the two, so it is the one reported.
    let ls = fixture()
    var both = 0
    for l in ls:
      if l.isSmartObject():
        check l.placedLayer().get().kind == "SoLd"
        if l.getBlock("PlLd").isSome:
          inc both
    check both > 0

  test "the PlLd of a real layer parses":
    let ls = fixture()
    for l in ls:
      let b = l.getBlock("PlLd")
      if b.isNone:
        continue
      let p = parsePlacedLayer(b.get().data)
      check p.kind == "PlLd"
      check p.version == 3
      check p.uniqueId.startsWith("$")
      check p.uniqueId.len == 37
      check p.hasTransform
