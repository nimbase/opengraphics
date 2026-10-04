import std/options
import unittest
import ../src/opengraphics/psd



proc roundTrip(d: Descriptor): Descriptor =
  ## Write then re-parse, which is the guarantee that matters.
  let bytes = toBytes(d)
  let got = parseDescriptor(bytes)
  check toBytes(got) == bytes
  got

proc roundTrip(v: Value): Value =
  let d = newDescriptor("null").with("k", v)
  let got = roundTrip(d)
  got.get("k").get()

suite "descriptor: identifiers":
  test "a four-character key uses the compact code form":
    let id = newId("null")
    check id.kind == idCode
    check id.asString() == "null"

  test "other lengths use the explicit form":
    for s in ["", "ab", "abcde", "aLongKeyName"]:
      let id = newId(s)
      check id.kind == idStr
      check id.asString() == s

  test "an explicit length of four stays explicit, so it round-trips":
    # a hand-built explicit-length id survives write and read
    let d = Descriptor(name: newUnicodeString(""),
      classId: DescId(kind: idStr, str: "null"),
      items: @[DescItem(key: DescId(kind: idStr, str: "abcd"),
        value: intValue(1))])
    let bytes = toBytes(d)
    let back = parseDescriptor(bytes)
    check back.items[0].key.kind == idStr
    check toBytes(back) == bytes

  test "equals compares raw bytes":
    check newId("null").equals("null")
    check not newId("null").equals("nulL")
    check newId("aLongKey").equals("aLongKey")

suite "descriptor: every OSType round-trips":
  test "long":
    let v = roundTrip(intValue(-70000'i32))
    check v.kind == vInteger
    check v.integer == -70000'i32

  test "comp":
    let v = roundTrip(longValue(1'i64 shl 40))
    check v.kind == vLargeInteger
    check v.large == 1'i64 shl 40

  test "doub":
    let v = roundTrip(doubleValue(-2.5))
    check v.kind == vDouble
    check v.double == -2.5

  test "bool":
    check roundTrip(boolValue(true)).boolean == true
    check roundTrip(boolValue(false)).boolean == false

  test "TEXT":
    let v = roundTrip(textValue("hello"))
    check v.kind == vText
    check v.text.toString() == "hello"

  test "enum":
    let v = roundTrip(enumValue("warpStyle", "warpNone"))
    check v.kind == vEnumerated
    check v.typeId.asString() == "warpStyle"
    check v.valueId.asString() == "warpNone"

  test "UntF carries its unit":
    let v = roundTrip(unitFloatValue("#Pxl", 12.5))
    check v.kind == vUnitFloat
    check v.floatUnitValue == 12.5
    check v.floatUnit == unitBytes("#Pxl")

  test "UnFl carries a list":
    let v = roundTrip(unitFloatsValue("#Pxl", @[1.0, 2.0, 3.0]))
    check v.kind == vUnitFloats
    check v.floatsUnitValues.len == 3
    check v.floatsUnitValues[2] == 3.0

  test "VlLs holds a mixed list":
    let v = roundTrip(listValue(@[intValue(1), doubleValue(2.0),
      textValue("three"), boolValue(true)]))
    check v.kind == vList
    check v.items.len == 4
    check v.items[0].integer == 1
    check v.items[3].boolean == true

  test "Objc nests a descriptor":
    let inner = newDescriptor("RGBC").with("Rd  ", doubleValue(255.0))
    let v = roundTrip(descriptorValue(inner))
    check v.kind == vDescriptor
    check v.descriptor.classId.asString() == "RGBC"
    check v.descriptor.getDouble("Rd  ") == 255.0

  test "GlbO nests a descriptor like Objc":
    let v = roundTrip(globalObjectValue(newDescriptor("RGBC")))
    check v.kind == vGlobalObject
    check v.globalObject.classId.asString() == "RGBC"

  test "type and GlbC carry a class":
    check roundTrip(classValue("Pnt ")).kind == vClass
    check roundTrip(globalClassValue("Pnt ")).kind == vGlobalClass

  test "tdta, alis and Pth keep raw bytes":
    check roundTrip(rawDataValue("raw bytes")).rawData == "raw bytes"
    check roundTrip(aliasValue("ali")).alias == "ali"
    check roundTrip(pathValue("path bytes")).path == "path bytes"

  test "ObAr keeps its prefix and body":
    let body = newDescriptor("Pnt ").with("Wdth", doubleValue(20.0))
    let v = roundTrip(objectArrayValue(16'u32, body))
    check v.kind == vObjectArray
    check v.arrayPrefix == 16'u32
    check v.arrayBody.getDouble("Wdth") == 20.0

  test "obj carries references":
    var items: seq[ReferenceItem] = @[]
    items.add(ReferenceItem(kind: riIdentifier, identifier: 7'u32))
    items.add(ReferenceItem(kind: riIndex, index: 3'u32))
    let v = roundTrip(referenceValue(items))
    check v.kind == vReference
    check v.reference.len == 2
    check v.reference[0].identifier == 7'u32
    check v.reference[1].index == 3'u32

suite "descriptor: every reference item round-trips":
  test "all seven kinds":
    var items: seq[ReferenceItem] = @[]
    items.add(ReferenceItem(kind: riProperty,
      propClass: emptyClass("layer"), propKey: newId("M   ")))
    items.add(ReferenceItem(kind: riClass, clsClass: emptyClass("layer")))
    items.add(ReferenceItem(kind: riEnumerated, enumClass: emptyClass("or"),
      typeId: newId("Ornt"), valueId: newId("Hrzn")))
    items.add(ReferenceItem(kind: riOffset, offClass: emptyClass("doc"),
      offset: 42'i32))
    items.add(ReferenceItem(kind: riIdentifier, identifier: 1'u32))
    items.add(ReferenceItem(kind: riIndex, index: 2'u32))
    items.add(ReferenceItem(kind: riName, nameClass: emptyClass("layer"),
      name: newUnicodeString("name")))
    let v = roundTrip(referenceValue(items))
    check v.reference.len == 7
    check v.reference[3].offset == 42'i32

  test "an unknown reference item type is reported as unsupported":
    var r = initReader("\x00\x00\x00\x01zzzz")
    expect(PsdError):
      discard readReference(r, 0, defaultLimits())

suite "descriptor: versioned wrapper":
  test "a versioned descriptor round-trips":
    let vd = newVersioned(newDescriptor("null").with("a", intValue(1)))
    let bytes = toBytes(vd)
    let got = parseVersionedDescriptor(bytes)
    check got.version == 16'u32
    check got.descriptor.getInt("a") == 1
    check toBytes(got) == bytes

  test "parsePrefix reports how much it consumed and allows a tail":
    var d = newVersioned(newDescriptor("null").with("a", intValue(1)))
    d.version = 16'u32
    let bytes = toBytes(d) & "TRAILING"
    let p = parsePrefixDescriptor(bytes)
    check p.consumed == toBytes(d).len
    check p.descriptor.descriptor.getInt("a") == 1

  test "parseVersioned rejects trailing bytes":
    let vd = newVersioned(newDescriptor("null"))
    expect(PsdError):
      discard parseVersionedDescriptor(toBytes(vd) & "junk")

  test "a version other than 16 is rejected":
    var w = initWriter()
    w.putU32(15'u32)
    w.put("\x00\x00\x00\x00")
    try:
      discard parseVersionedDescriptor(w.toString())
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.Invalid

suite "descriptor: unknown input":
  test "an unknown OSType is reported as unsupported":
    # the reference cannot size it either, so the stream could not stay aligned
    var w = initWriter()
    w.writeUnicodeString(newUnicodeString(""))
    w.writeId(newId("null"))
    w.putU32(1'u32)
    w.writeId(newId("k"))
    w.putStr4("zzzz")
    w.putU8(0)
    try:
      discard parseDescriptor(w.toString())
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.Unsupported

  test "trailing bytes on a bare descriptor are rejected":
    let bytes = toBytes(newDescriptor("null")) & "extra"
    expect(PsdError):
      discard parseDescriptor(bytes)

  test "nesting deeper than the cap is refused without recursing forever":
    # build 70 nested Objc values by hand
    var w = initWriter()
    for _ in 0 ..< 70:
      w.writeUnicodeString(newUnicodeString(""))
      w.writeId(newId("null"))
      w.putU32(1'u32)
      w.writeId(newId("k"))
      w.putStr4("Objc")
    w.writeUnicodeString(newUnicodeString(""))
    w.writeId(newId("null"))
    w.putU32(0'u32)
    try:
      discard parseDescriptor(w.toString())
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.LimitExceeded

  test "an implausible item count is refused before allocating":
    var w = initWriter()
    w.writeUnicodeString(newUnicodeString(""))
    w.writeId(newId("null"))
    w.putU32(0xFFFFFFFF'u32)
    try:
      discard parseDescriptor(w.toString())
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.LimitExceeded

  test "every truncation of a rich descriptor raises":
    let d = newDescriptor("Lyr ").with("Idnt", textValue("uuid")).with(
      "Trnf", listValue(@[doubleValue(1.0), doubleValue(2.0)])).with(
      "warp", descriptorValue(newDescriptor("warp").with(
        "warpStyle", enumValue("warpStyle", "warpNone"))))
    let bytes = toBytes(d)
    for n in 0 ..< bytes.len:
      expect(PsdError):
        discard parseDescriptor(bytes[0 ..< n])

suite "descriptor: accessors":
  test "typed getters read the matching kinds":
    let d = newDescriptor("null").
      with("Nm  ", textValue("name")).
      with("num", intValue(7)).
      with("dbl", doubleValue(1.25)).
      with("bln", boolValue(true)).
      with("obj", descriptorValue(newDescriptor("inner"))).
      with("lst", listValue(@[doubleValue(1.0), doubleValue(2.0)]))
    check d.getText("Nm  ") == "name"
    check d.getInt("num") == 7
    check d.getDouble("dbl") == 1.25
    check d.getBool("bln")
    check d.getDescriptor("obj").get().classId.asString() == "inner"
    check d.getDoubles("lst") == @[1.0, 2.0]

  test "missing and mistyped keys fall back to the default":
    let d = newDescriptor("null").with("s", textValue("x"))
    check d.getText("nope") == ""
    check d.getInt("nope") == 0
    check d.getInt("s") == 0      # wrong kind
    check not d.getBool("s")
    check d.getDescriptor("nope").isNone
    check d.getDoubles("nope").len == 0
    check d.getDoubles("s").len == 0

  test "has reports presence":
    let d = newDescriptor("null").with("k", intValue(1))
    check d.has("k")
    check not d.has("z")

  test "a unit float is readable with its unit":
    let d = newDescriptor("null").with("Rslt", unitFloatValue("#Rsl", 72.0))
    let uf = d.getUnitFloat("Rslt")
    check uf.isSome
    check uf.get().unit == "#Rsl"
    check uf.get().value == 72.0
    check d.getUnitFloat("nope").isNone

suite "descriptor: bool normalisation":
  test "a non-zero bool byte reads as true and writes back as 1":
    # the documented normalising round-trip case
    var w = initWriter()
    w.writeUnicodeString(newUnicodeString(""))
    w.writeId(newId("null"))
    w.putU32(1'u32)
    w.writeId(newId("b"))
    w.putStr4("bool")
    w.putU8(0xFF)
    let d = parseDescriptor(w.toString())
    check d.getBool("b")
    check toBytes(d) == toBytes(newDescriptor("null").with("b", boolValue(true)))

  test "TEXT is terminated with a NUL unit on read":
    var w = initWriter()
    w.writeUnicodeString(newUnicodeString(""))
    w.writeId(newId("null"))
    w.putU32(1'u32)
    w.writeId(newId("t"))
    w.putStr4("TEXT")
    w.putU32(3'u32) # "AB" plus a terminating NUL
    w.putU16('A'.ord)
    w.putU16('B'.ord)
    w.putU16(0'u16)
    let d = parseDescriptor(w.toString())
    check d.getText("t") == "AB"
    check d.items[0].value.text.units.len == 3 # the NUL is kept

  test "a name keeps trailing NULs in the model but not in toString":
    let u = newUnicodeString("hi", true)
    check u.units.len == 3
    check u.toString() == "hi"

suite "descriptor: real Photoshop blocks":
  test "01.psd exposes a vscg solid-colour descriptor":
    let f = readPsd(readFile("tests/data/01.psd"))
    let b = f.layers()[0].getBlock("vscg")
    check b.isSome
    let vd = parseBlockDescriptor(b.get().data)
    check vd.version == 16'u32
    # the payload is a single `Clr ` object of class RGBC
    check vd.descriptor.items.len == 1
    let clr = vd.descriptor.getDescriptor("Clr ")
    check clr.isSome
    let rgb = clr.get()
    check rgb.classId.asString() == "RGBC"
    check rgb.items.len == 3

  test "01.psd exposes a vogk origination descriptor":
    let f = readPsd(readFile("tests/data/01.psd"))
    let b = f.layers()[0].getBlock("vogk")
    check b.isSome
    let vd = parseBlockDescriptor(b.get().data)
    check vd.descriptor.has("keyDescriptorList")

  test "SoLd needs its own version stripped before the descriptor":
    # SoLd is "soLD" + block version 4 + descriptor version 16 + body,
    # unlike SoCo which has no block-level version
    let f = readPsd(readFile("tests/data/01.psd"))
    let b = f.layers()[1].getBlock("SoLd")
    check b.isSome
    let data = b.get().data
    check data.head(4) == "soLD"
    # the block version is 4, so a four-byte prefix misreads it
    expect(PsdError):
      discard parseBlockDescriptor(data)
    let vd = parseBlockDescriptor(data, PlacedBlockPrefixLen)
    check vd.version == 16'u32
    check vd.descriptor.items.len > 4

  test "a Photoshop descriptor rewrites to the same bytes":
    # the point of parsing them properly: we can read them and write them back
    let f = readPsd(readFile("tests/data/01.psd"))
    for key in ["vscg", "vogk"]:
      let b = f.layers()[0].getBlock(key)
      let vd = parseBlockDescriptor(b.get().data)
      let bytes = toBytes(vd)
      let back = parseVersionedDescriptor(bytes)
      check toBytes(back) == bytes
      check back.descriptor.items.len == vd.descriptor.items.len
    let sold = parseBlockDescriptor(f.layers()[1].getBlock("SoLd").get().data,
      PlacedBlockPrefixLen)
    let bytes = toBytes(sold)
    check toBytes(parseVersionedDescriptor(bytes)) == bytes
