import std/options
import unittest
import ../src/opengraphics/psd




proc sectionOf(resources: openArray[ImageResource]): string =
  var w = initWriter()
  writeResourceSection(w, resources)
  w.toString()

proc parseSection(s: string): seq[ImageResource] =
  var r = initReader(s)
  result = readResourceSection(r)

suite "resources: wire layout":
  test "a resource round-trips":
    let bytes = sectionOf([newImageResource(1005, "sixteen byte res!")])
    let got = parseSection(bytes)
    check got.len == 1
    check got[0].id == 1005
    check got[0].data == "sixteen byte res!"
    check got[0].signature == "8BIM"

  test "an odd-length payload gets one pad byte":
    let bytes = sectionOf([newImageResource(2000, "abc")])
    # 4 section length + 4 signature + 2 id + 2 name + 4 length + 3 + 1 pad
    check bytes.len == 4 + 4 + 2 + 2 + 4 + 3 + 1
    check parseSection(bytes)[0].data == "abc"

  test "an even-length payload gets no pad byte":
    let bytes = sectionOf([newImageResource(2000, "abcd")])
    check bytes.len == 4 + 4 + 2 + 2 + 4 + 4
    check parseSection(bytes)[0].data == "abcd"

  test "several resources round-trip in order":
    let all = [newImageResource(1005, "a"), newImageResource(1036, "bb"),
      newImageResource(2999, "ccc")]
    let got = parseSection(sectionOf(all))
    check got.len == 3
    check got[0].id == 1005
    check got[1].data == "bb"
    check got[2].data == "ccc"

  test "an empty section round-trips":
    check parseSection(sectionOf([])).len == 0
    check sectionOf([]) == "\x00\x00\x00\x00"

  test "a Pascal name round-trips":
    var res = newImageResource(1005, "x")
    res.name = "layer 1"
    let got = parseSection(sectionOf([res]))
    check got[0].name == "layer 1"

  test "all five accepted signatures round-trip":
    for sig in KnownSignatures:
      var res = newImageResource(2000, "d")
      res.signature = sig
      check parseSection(sectionOf([res]))[0].signature == sig

  test "an unknown signature is rejected":
    var w = initWriter()
    w.putStr4("XXXX")
    w.putU16(1005'u16)
    w.writePascal("", 2)
    w.putU32(1)
    w.put("a")
    var body = initWriter()
    body.putU32(uint32(w.len))
    body.put(w.toString())
    var r = initReader(body.toString())
    try:
      discard readResourceSection(r)
      fail()
    except PsdError as e:
      check e.kind == PsdErrorKind.InvalidSignature

  test "a length overrunning the section raises":
    var w = initWriter()
    w.putStr4("8BIM")
    w.putU16(1005'u16)
    w.writePascal("", 2)
    w.putU32(0xFFFF)
    var r = initReader("\x00\x00\x00\x10" & w.toString())
    expect(PsdError):
      discard readResourceSection(r)

  test "every truncation of a two-resource section raises":
    let bytes = sectionOf([newImageResource(1005, "aaaa"),
      newImageResource(2000, "bbbb")])
    for n in 0 ..< bytes.len:
      expect(PsdError):
        discard parseSection(bytes[0 ..< n])

suite "resources: typed access":
  test "resolution 1005 decodes and re-encodes":
    let res = resolutionFromDpi(72.0)
    check res.hRes() == 72.0
    check res.vRes() == 72.0
    check resolutionFromDpi(300.0).hRes() == 300.0
    var w = initWriter()
    w.writeResolution(res)
    let got = parseSection(sectionOf([newImageResource(1005, w.toString())]))
    check readResolution(got[0].data).hResFixed == res.hResFixed

  test "resolution rejects a short payload":
    expect(PsdError):
      discard readResolution("short")

  test "layer state 1024 decodes":
    let got = newImageResource(1024, "\x00\x07").parsed()
    check got.get().kind == rdLayerState
    check got.get().layerState == 7'u16

  test "layer group info 1026 decodes a list":
    let got = newImageResource(1026, "\x00\x01\x00\x02\x00\x03").parsed()
    check got.get().kind == rdLayerGroupInfo
    check got.get().groupIds == @[1'u16, 2, 3]

  test "an odd-length layer group info is not typed":
    check newImageResource(1026, "\x00\x01\x00").parsed().isNone

  test "global angle and altitude decode as signed values":
    check newImageResource(1037, "\xFF\xFF\xFF\x9C").parsed().get().angle == -100'i32
    check newImageResource(1049, "\x00\x00\x00\x32").parsed().get().altitude == 50'i32

  test "thumbnails hand back the raw header plus payload":
    let payload = "JFIF\x00" & "rest of the jpeg"
    check newImageResource(1036, payload).parsed().get().thumbnail == payload
    check newImageResource(1033, payload).parsed().get().thumbnail == payload

  test "version info 1057 decodes and round-trips":
    var w = initWriter()
    w.writeVersionInfoResource(true)
    let got = newImageResource(1057, w.toString()).parsed()
    check got.get().kind == rdVersionInfo
    check got.get().versionInfo.hasRealMergedData == true
    check got.get().versionInfo.version == 1'u32
    check got.get().versionInfo.writer == "Adobe Photoshop"
    check got.get().versionInfo.reader == "Adobe Photoshop CS6"

  test "version info can flag a placeholder composite":
    var w = initWriter()
    w.writeVersionInfoResource(false)
    let res = newImageResource(1057, w.toString())
    check res.parsed().get().versionInfo.hasRealMergedData == false

  test "ICC, EXIF and XMP keep raw bytes":
    for id in [1039, 1058, 1060]:
      let d = newImageResource(id, "payload").parsed().get()
      check d.raw == "payload"
    # 1040 is not itself typed; iccProfile falls back to it by id
    check newImageResource(1040, "payload").parsed().isNone

  test "XMP surfaces as text when it is valid UTF-8":
    let xmp = newImageResource(1060, "<x:xmpmeta/>").xmpText()
    check xmp.isSome
    check xmp.get() == "<x:xmpmeta/>"
    check newImageResource(1005, "not xmp").xmpText().isNone
    check newImageResource(1060, "\xFF\xFE").xmpText().isNone

  test "unmodelled ids are left raw":
    for id in [1025, 1050, 2000, 2997, 2999]:
      check newImageResource(id, "raw").parsed().isNone

  test "a truncated known id is not typed":
    check newImageResource(1024, "\x00").parsed().isNone
    check newImageResource(1037, "\x00").parsed().isNone
    check newImageResource(1057, "\x00").parsed().isNone

suite "resources: lookups":
  test "findResource and getResource agree":
    let all = [newImageResource(1005, "a"), newImageResource(1039, "b")]
    check findResource(all, 1039) == 1
    check findResource(all, 2000) == -1
    check getResource(all, 1005).isSome

  test "iccProfile prefers 1039 and falls back to 1040":
    check iccProfile([newImageResource(1040, "untagged")]) == "untagged"
    check iccProfile([newImageResource(1039, "tagged"),
      newImageResource(1040, "untagged")]) == "tagged"
    check iccProfile([]) == ""

  test "resolution returns none when absent or malformed":
    check resolution([]).isNone
    check resolution([newImageResource(1005, "short")]).isNone
    check resolution([newImageResource(1005, "0123456789abcdef")]).isSome

  test "an absent 1057 means the merged image is real":
    check hasRealMergedData([])
    var w = initWriter()
    w.writeVersionInfoResource(false)
    check not hasRealMergedData([newImageResource(1057, w.toString())])

  test "isPathResource covers the saved-path range only":
    check isPathResource(2000)
    check isPathResource(2500)
    check isPathResource(2997)
    check not isPathResource(1999)
    check not isPathResource(2998)
    check not isPathResource(1025)

suite "resources: the real fixture":
  test "01.psd exposes a resolution and ICC profile":
    let f = readFile("tests/data/01.psd")
    var r = initReader(f)
    discard readHeader(r)
    let cmdLen = int(r.readU32BE())
    r.skip(cmdLen)
    let res = readResourceSection(r)
    check res.len > 0
    check resolution(res).isSome
    check findResource(res, IccProfileId) >= 0
    check iccProfile(res).len > 0
    check res[0].signature == "8BIM"
