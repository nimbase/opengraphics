## Every checked-in fixture, opened and read through the public API.
##
## 01.psd is a small RGB document with a shape, a smart object and two text
## layers. 02.psd is large (45 MB, 75 layers) and exercises nesting, groups,
## many smart objects and reserved layer-flag bits. 03.psd is grayscale.
##
## These are the tests that would have caught the layer-flags bug: 02.psd sets
## bits 5-7 of the flags byte, which the spec leaves undefined, so a reader
## that rebuilds the byte from the five defined bits cannot round-trip it.

import std/options
import std/sequtils
import std/strutils
import unittest
import ../src/opengraphics/psd

proc fixture(name: string): Document =
  readPsdBytes(readFile("tests/data/" & name))

suite "fixtures: 01.psd":
  test "opens with the expected header":
    let d = fixture("01.psd")
    check d.width == 700
    check d.height == 700
    check d.file.header.depth == 8
    check d.file.header.colorMode.kind == cmRgb
    check d.file.header.channels == 3
    check d.file.header.version == Version.Psd
    check d.layerCount == 4

  test "reads every layer and its name":
    let ls = fixture("01.psd").layers()
    check ls.mapIt(it.name()) == @["Rectangle 1", "nim-lang",
      "Efficient, expressive, elegant",
      "Nim is a statically typed compiled systems programming language"]

  test "classifies each layer kind":
    let ls = fixture("01.psd").layers()
    check ls[0].hasVectorMask()
    check ls[0].hasFillContent()
    check ls[1].isSmartObject()
    check not ls[2].isSmartObject()
    check ls[2].isTextLayer()
    check ls[3].isTextLayer()

  test "has a decoded composite":
    let d = fixture("01.psd")
    check d.hasComposite
    check d.compositeImage().width == 700
    check d.compositeImage().height == 700

suite "fixtures: 02.psd":
  test "opens as a large RGB document":
    let f = readPsd(readFile("tests/data/02.psd"))
    check f.width == 1280
    check f.height == 640
    check f.header.depth == 8
    check f.header.colorMode.kind == cmRgb
    check f.header.channels == 3
    check f.layerInfo.isSome
    check f.layerInfo.get().layers.len == 75

  test "has 31 resources and 11 global blocks":
    let f = readPsd(readFile("tests/data/02.psd"))
    check f.resources.len == 31
    check f.globalBlocks.len == 11



  test "exercises every layer kind in one document":
    let f = readPsd(readFile("tests/data/02.psd"))
    let ls = f.layers()
    var text = 0
    var shapes = 0
    var smart = 0
    var masks = 0
    for l in ls:
      if l.isTextLayer(): inc text
      if l.hasVectorMask(): inc shapes
      if l.isSmartObject(): inc smart
      if l.layerMask().isSome: inc masks
    check text > 10
    check shapes > 0
    check smart > 10
    check masks > 0

  test "the layer stack nests into groups":
    let tree = readPsd(readFile("tests/data/02.psd")).layerTree()
    check tree.len < 75 # fewer roots than records: some are inside groups
    var groups = 0
    proc walk(nodes: seq[LayerNode]) =
      for n in nodes:
        if n.kind == lnGroup:
          inc groups
        walk(n.children)
    walk(tree)
    check groups > 0

  test "every layer's metadata block round-trips exactly":
    let f = readPsd(readFile("tests/data/02.psd"))
    for l in f.layers():
      check l.hasMetadata()
      let raw = l.getBlock("shmd").get().data
      check writeShmd(parseShmd(raw)) == raw

  test "text layers decode their text and fonts":
    let f = readPsd(readFile("tests/data/02.psd"))
    var found = 0
    for l in f.layers():
      if not l.isTextLayer():
        continue
      let t = l.textOf().get()
      check t.text.len > 0
      check t.fontNames.len > 0
      check t.fontSizes.len > 0
      check t.raw == l.getBlock("TySh").get().data
      inc found
      if found >= 10:
        break
    check found > 0

  test "reserved flag bits are preserved verbatim":
    # Bits 5-7 are undefined by the spec; 02.psd sets bit 5 on many records.
    let f = readPsd(readFile("tests/data/02.psd"))
    var withReserved = 0
    for l in f.layers():
      if (l.flags.rawFlags and 0xE0'u8) != 0:
        inc withReserved
    check withReserved > 0

  test "round-trips byte for byte":
    let bytes = readFile("tests/data/02.psd")
    check writePsd(readPsd(bytes)) == bytes

suite "fixtures: 03.psd":
  test "opens as a grayscale document":
    let f = readPsd(readFile("tests/data/03.psd"))
    check f.width == 700
    check f.height == 700
    check f.header.depth == 8
    check f.header.colorMode.kind == cmGrayscale
    check f.header.channels == 1
    check f.layerInfo.get().layers.len == 3

  test "the last layer is a text layer":
    let f = readPsd(readFile("tests/data/03.psd"))
    check f.layers()[2].isTextLayer()
    check not f.layers()[0].isTextLayer()
    let t = f.layers()[2].textOf().get()
    # the descriptor text keeps Photoshop's literal CR line breaks
    check t.text.contains("unifies popular")
    check t.text.contains("single API")
    # the engine text normalises them to LF
    check t.engineText.contains("unifies popular\ngraphics formats\nunder a single API")
    check t.fontNames == @["ArialMT", "AdobeInvisFont", "MyriadPro-Regular"]
    check t.fontSizes[0] > 20.0

  test "the slices resource names the recovered document":
    let s = slices(readPsd(readFile("tests/data/03.psd")).resources).get()
    check s.version == 6
    check s.groupName == "Untitled-1-Recovered"
    check s.slices.len == 1
    check s.slices[0].rect == [0'i32, 0'i32, 700'i32, 700'i32]

  test "the pattern block exists but is empty":
    let f = readPsd(readFile("tests/data/03.psd"))
    check f.globalBlock("Patt").isSome
    check f.globalBlock("Patt").get().data.len == 0
    check globalPatterns(f) == some(newSeq[PsdPattern]())

  test "there are no saved or work paths":
    let f = readPsd(readFile("tests/data/03.psd"))
    check f.savedPaths().len == 0
    check f.workPath().isNone

  test "round-trips byte for byte":
    let bytes = readFile("tests/data/03.psd")
    check writePsd(readPsd(bytes)) == bytes

suite "fixtures: all three through the compatibility API":
  test "each opens and reports its size":
    for name in ["01.psd", "02.psd", "03.psd"]:
      let d = fixture(name)
      check d.width > 0
      check d.height > 0
      check d.layerCount > 0
      check d.file.resources.len > 0

  test "all three round-trip byte for byte":
    for name in ["01.psd", "02.psd", "03.psd"]:
      let bytes = readFile("tests/data/" & name)
      check writePsd(readPsd(bytes)) == bytes

  test "layer names are unique enough to look up":
    check fixture("01.psd").layerByName("nim-lang") == 1
    check fixture("01.psd").layerByName("nope") == -1
    check fixture("03.psd").layerByName("Background") == 0

  test "layer pixels decode for a small document":
    # 01.psd only: 02.psd would decode 75 full-canvas layers.
    let d = fixture("01.psd")
    let li = d.layerImage(1)
    check li.img.width == li.rect.width()
    check li.img.height == li.rect.height()
    check li.img.data.len == li.img.width * li.img.height