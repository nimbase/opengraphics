## Smart-object linked files (`lnk2`) and `SoLE` placed layers.
##
## No committed fixture carries `lnk2`, so these tests build items with the
## writer and check the typed view. `01.psd` carries a smart object, which
## pins the `SoLd` path against a real file.

import std/options
import std/unittest
import ../src/opengraphics/psd

proc writeItem(uuid, fname, payload: string): string =
  var w = initWriter()
  w.putStr4("liFD")
  w.putU32(7) # version
  w.writePascal(uuid, 4)
  w.writeUnicode(fname)
  w.putStr4("8BIM")
  w.putStr4("TEXT")
  w.putU64(uint64(payload.len))
  w.putU8(0) # no descriptor
  w.put(payload)
  w.toString()

proc writeBlock(items: openArray[string]): string =
  var w = initWriter()
  for it in items:
    w.putU64(uint64(it.len))
    w.put(it)
    let pad = (4 - (it.len mod 4)) mod 4
    for _ in 0 ..< pad: w.putU8(0)
  w.toString()

suite "smart: linked files":
  test "liFD round-trips uuid, name and bytes":
    let item = writeItem("abc", "art.png", "PAYLOAD")
    let files = parseLinkedBlock(spanOf(writeBlock([item])))
    check files.len == 1
    check files[0].uuid == "abc"
    check files[0].fileName == "art.png"
    check files[0].kind == lkEmbedded
    check files[0].hasBytes
    check files[0].bytes.clone == "PAYLOAD"

  test "external items carry identity without bytes":
    var w = initWriter()
    w.putStr4("liFE")
    w.putU32(7)
    w.writePascal("ext-id", 4)
    w.writeUnicode("http://example/x.png")
    w.putStr4("8BIM")
    w.putStr4("TEXT")
    w.putU64(0)
    w.putU8(0)
    let files = parseLinkedBlock(spanOf(writeBlock([w.toString()])))
    check files.len == 1
    check files[0].kind == lkExternal
    check not files[0].hasBytes

  test "truncated tail stops the scan, keeps earlier records":
    let good = writeItem("u1", "a.bin", "AB")
    let files = parseLinkedBlock(spanOf(writeBlock([good]) & "\x00\x00\x00"))
    check files.len == 1

  test "01.psd smart object still parses with SoLE support":
    let f = readPsd(readFile("tests/data/01.psd"))
    var found = false
    for l in f.layers():
      if l.isSmartObject():
        found = true
        let p = l.placedLayer()
        check p.isSome
    check found

  test "SoLE payload parses like SoLd":
    # Minimal soLE: sig + version 4 + versioned empty descriptor.
    var w = initWriter()
    w.putStr4("soLE")
    w.putU32(4)
    w.putU32(16)
    w.writeUnicode("")
    w.writeId(newId("null"))
    w.putU32(0)
    let p = parsePlacedLayer(spanOf(w.toString()))
    check p.kind == "SoLE"
