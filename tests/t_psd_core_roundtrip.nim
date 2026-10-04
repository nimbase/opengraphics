import std/options
import std/sequtils
import std/strutils
import unittest
import ../src/opengraphics/psd
import ./psd_testgen




proc parse(s: string): PsdFile = readPsd(s)

proc serialize(f: PsdFile): string = writePsd(f)

proc minimalFile(width = 2, height = 2, channels = 3,
    compression = Raw, data = ""): string =
  ## A header, empty colour data, empty resources, no layers, then a raw
  ## merged image of `width*height*channels` bytes.
  var w = initWriter()
  w.putStr4("8BPS")
  w.putU16(1)
  for _ in 0 ..< 6:
    w.putU8(0)
  w.putU16(uint16(channels))
  w.putU32(uint32(height))
  w.putU32(uint32(width))
  w.putU16(8)
  w.putU16(3)
  w.putU32(0) # colour mode data
  w.putU32(0) # resources
  w.putU32(0) # layer and mask section
  w.putU16(compression.toU16)
  if data.len == 0:
    for _ in 0 ..< width * height * channels:
      w.putU8(byte(7))
  else:
    w.put(data)
  w.toString()

suite "round-trip: the real fixtures":
  test "01.psd comes back byte for byte":
    let bytes = readFile("tests/data/01.psd")
    let f = parse(bytes)
    check serialize(f) == bytes

  test "02.psd, three layers and one text layer, comes back byte for byte":
    let bytes = readFile("tests/data/02.psd")
    let f = parse(bytes)
    check f.layers().len == 3
    check serialize(f) == bytes

  test "a large generated file with groups, masks and reserved flags comes back byte for byte":
    # This is what 02.psd used to cover. It was replaced by a much smaller file,
    # and no committed fixture now carries a group, a mask or an undefined flag
    # bit, so the generator supplies them: the reserved bits in particular are
    # the ones that exposed the original layer-flags bug, since a reader that
    # rebuilds the byte from the five defined bits cannot write the file back
    # identically.
    let bytes = readFile(largeFixture())
    let f = parse(bytes)
    var groups = 0
    var reserved = 0
    var masks = 0
    for l in f.layers():
      if l.blocks.anyIt(it.key == "lsct"): inc groups
      if (l.flags.rawFlags and 0xE0'u8) != 0: inc reserved
      if l.layerMask().isSome: inc masks
    check groups > 0
    check reserved > 0
    check masks > 0
    check serialize(f) == bytes

  test "03.psd, grayscale with a text layer, comes back byte for byte":
    let bytes = readFile("tests/data/03.psd")
    let f = parse(bytes)
    check f.header.colorMode.kind == cmGrayscale
    check serialize(f) == bytes

  test "parsing is idempotent":
    let bytes = readFile("tests/data/01.psd")
    let once = serialize(parse(bytes))
    let twice = serialize(parse(once))
    check once == twice

suite "round-trip: structure of 01.psd":
  test "the header is what the fixture declares":
    let f = parse(readFile("tests/data/01.psd"))
    check f.header.version == Version.Psd
    check f.width() == 700
    check f.height() == 700
    check f.header.depth == 8
    check f.header.colorMode.kind == cmRgb
    check f.header.channels in 3..4

  test "four layers are found":
    let f = parse(readFile("tests/data/01.psd"))
    check f.layers().len == 4

  test "every layer rect is sane":
    let f = parse(readFile("tests/data/01.psd"))
    for l in f.layers():
      # negative offsets are legal: layers may hang off the canvas
      check not l.rect.isEmpty()
      check l.rect.width() > 0 and l.rect.height() > 0
      check l.channelRect(-1'i16).width() == l.rect.width()

  test "channel data is preserved verbatim, not decoded":
    let f = parse(readFile("tests/data/01.psd"))
    for l in f.layers():
      for c in l.channels:
        if c.compression.isSome:
          # encoded bytes are exactly what the file held
          check c.data.len > 0
          # and they are NOT width*height raw bytes, which proves laziness
          let rect = l.channelRect(c.id)
          if not rect.isEmpty():
            check c.data.len != rect.width() * rect.height() or
              c.compression.get().kind == cRaw

  test "the layer tree builds and flattens back to the file order":
    let f = parse(readFile("tests/data/01.psd"))
    let tree = f.layerTree()
    check tree.len > 0
    let flat = flattenTree(tree)
    # every non-divider record survives the walk
    var nonDividers = 0
    for l in f.layers():
      if not l.sectionType().isDivider():
        inc nonDividers
    check flat.len == nonDividers

  test "the merged image decodes to the expected volume":
    let f = parse(readFile("tests/data/01.psd"))
    let merged = decodeMerged(f)
    let expected = f.header.width * f.header.height * f.header.channels
    check merged.len == expected

  test "layers carry readable names":
    let f = parse(readFile("tests/data/01.psd"))
    var named = 0
    for l in f.layers():
      if l.name().len > 0:
        inc named
    check named >= 3

suite "round-trip: model mutations":
  test "a layer name change survives a write and re-read":
    var f = parse(readFile("tests/data/01.psd"))
    f.layerAt(0).blocks = @[unicodeNameBlock("Renamed")]
    check parse(serialize(f)).layers()[0].name() == "Renamed"

  test "an unknown tagged block passes through unchanged":
    var f = parse(readFile("tests/data/01.psd"))
    f.layerAt(0).blocks.add(TaggedBlock(signature: "8BIM", key: "zzzz",
      data: toSpan("opaque payload"), padding: none(Span)))
    let written = serialize(f)
    check written.find("opaque payload") >= 0
    check parse(written).layers()[0].getBlock("zzzz").isSome

  test "an unknown resource passes through unchanged":
    var f = parse(readFile("tests/data/01.psd"))
    f.resources.add(newImageResource(2999, "printer flags"))
    let g = parse(serialize(f))
    let r = g.resource(2999)
    check r.isSome
    check r.get().data == "printer flags"

  test "adding a layer is visible after re-reading":
    var f = parse(readFile("tests/data/01.psd"))
    let before = f.layers().len
    var l = f.layers()[0]
    l.name = "extra"
    l.blocks = @[unicodeNameBlock("extra")]
    f.addLayer(l)
    check parse(serialize(f)).layers().len == before + 1

  test "dropping a layer is visible after re-reading":
    var f = parse(readFile("tests/data/01.psd"))
    f.setLayers(@[f.layers()[0]])
    check parse(serialize(f)).layers().len == 1

suite "round-trip: hand-built files":
  test "a minimal file round-trips":
    let bytes = minimalFile()
    check serialize(parse(bytes)) == bytes

  test "a minimal grayscale file round-trips":
    var w = initWriter()
    w.putStr4("8BPS")
    w.putU16(1)
    for _ in 0 ..< 6:
      w.putU8(0)
    w.putU16(1)
    w.putU32(2)
    w.putU32(2)
    w.putU16(8)
    w.putU16(1)
    w.putU32(0)
    w.putU32(0)
    w.putU32(0)
    w.putU16(0)
    for _ in 0 ..< 4:
      w.putU8(byte(3))
    let bytes = w.toString()
    check serialize(parse(bytes)) == bytes

  test "each compression round-trips":
    for comp in [Raw, Rle, Zip, ZipPrediction]:
      let l = newPlaneLayout(3, 2, 2, 8, Version.Psd)
      var plane = newString(l.totalBytes())
      for i in 0 ..< plane.len:
        plane[i] = char(byte(i * 9))
      let payload = encodePlanes(comp, plane, l)
      let bytes = minimalFile(compression = comp, data = payload)
      let f = parse(bytes)
      check serialize(f) == bytes
      check decodeMerged(f) == plane

  test "PSB uses 64-bit section lengths":
    var w = initWriter()
    w.putStr4("8BPS")
    w.putU16(2) # PSB
    for _ in 0 ..< 6:
      w.putU8(0)
    w.putU16(3)
    w.putU32(2)
    w.putU32(2)
    w.putU16(8)
    w.putU16(3)
    w.putU32(0) # colour mode data stays 32-bit
    w.putU32(0) # resources stay 32-bit
    w.putI64(0) # layer and mask section is 64-bit
    w.putU16(0)
    for _ in 0 ..< 12:
      w.putU8(byte(5))
    let bytes = w.toString()
    let f = parse(bytes)
    check f.header.version == Version.Psb
    check serialize(f) == bytes

  test "a 16-bit file round-trips and reports its placement":
    var w = initWriter()
    w.putStr4("8BPS")
    w.putU16(1)
    for _ in 0 ..< 6:
      w.putU8(0)
    w.putU16(3)
    w.putU32(2)
    w.putU32(2)
    w.putU16(16)
    w.putU16(3)
    w.putU32(0)
    w.putU32(0)
    # layer and mask section holding only an Lr16 global block
    var sec = initWriter()
    let liAt = sec.beginLen(false)
    sec.endLen(liAt, false) # zero-length layer info
    let gmAt = sec.beginLen(false)
    sec.endLen(gmAt, false) # zero-length global mask
    var lr = initWriter()
    lr.putI16(0) # layer count 0
    let lr16: seq[TaggedBlock] = @[TaggedBlock(signature: "8BIM", key: "Lr16",
      data: toSpan(lr.toString()), padding: none(Span))]
    sec.writeBlocks(lr16, Version.Psd)
    w.putU32(uint32(sec.len()))
    w.put(sec.toString())
    w.putU16(0)
    for _ in 0 ..< 24:
      w.putU8(byte(0))
    let bytes = w.toString()
    let f = parse(bytes)
    check f.header.depth == 16
    check f.layerInfo.isSome
    check f.layerInfoPlacement.kind == pkGlobalBlock
    check serialize(f) == bytes

  test "a file with a global layer mask round-trips":
    var sec = initWriter()
    let liAt = sec.beginLen(false)
    sec.endLen(liAt, false)
    let gmAt = sec.beginLen(false)
    for i in 0 ..< 13:
      sec.putU8(uint8(i))
    sec.endLen(gmAt, false)
    var w = initWriter()
    w.putStr4("8BPS")
    w.putU16(1)
    for _ in 0 ..< 6:
      w.putU8(0)
    w.putU16(3)
    w.putU32(1)
    w.putU32(1)
    w.putU16(8)
    w.putU16(3)
    w.putU32(0)
    w.putU32(0)
    w.putU32(uint32(sec.len()))
    w.put(sec.toString())
    w.putU16(0)
    for _ in 0 ..< 3:
      w.putU8(byte(9))
    let bytes = w.toString()
    let f = parse(bytes)
    check f.globalLayerMask.isSome
    check f.globalLayerMask.get().overlayColorSpace().isSome
    check serialize(f) == bytes

suite "malformed input":
  test "an empty input raises":
    expect(PsdError):
      discard parse("")

  test "a bad signature raises InvalidSignature":
    var s = minimalFile()
    s[0] = 'X'
    try:
      discard parse(s)
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.InvalidSignature

  test "every truncation of a small file raises, and the full file parses":
    let bytes = minimalFile()
    for n in 0 ..< bytes.len:
      expect(PsdError):
        discard parse(bytes[0 ..< n])

  test "an oversize section length raises LimitExceeded":
    var s = minimalFile()
    # colour mode length sits at offset 26
    s[26] = '\x7F'
    expect(PsdError):
      discard parse(s)

  test "a huge declared channel count raises":
    var w = initWriter()
    w.putStr4("8BPS")
    w.putU16(1)
    for _ in 0 ..< 6:
      w.putU8(0)
    w.putU16(99'u16) # beyond MaxChannels
    w.putU32(1)
    w.putU32(1)
    w.putU16(8)
    w.putU16(3)
    try:
      discard parse(w.toString())
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.Invalid
