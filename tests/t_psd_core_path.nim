import std/math
import std/options
import std/strutils
import unittest
import ../src/opengraphics/psd



proc knotRecord(linked: bool, anchorH, anchorV: float64): string =
  ## One knot record: selector plus 24 bytes, vertical before horizontal in
  ## each point pair.
  var w = initWriter()
  w.putU16(if linked: 1'u16 else: 2'u16)
  proc put(v: float64) =
    let f = cast[uint32](floatToFixed(v))
    w.putU8(byte(f shr 24))
    w.putU8(byte(f shr 16))
    w.putU8(byte(f shr 8))
    w.putU8(byte(f and 0xFF))
  put(anchorH); put(anchorV) # anchor
  put(anchorH); put(anchorV) # pre
  put(anchorH); put(anchorV) # post
  w.toString()

proc lengthRecord(closed: bool, count: int): string =
  var w = initWriter()
  w.putU16(if closed: 0'u16 else: 3'u16)
  w.putU16(uint16(count))
  for i in 2 ..< 24:
    w.putU8(0)
  w.toString()

suite "path: fixed point":
  test "round-trips a fraction":
    check fixedToFloat(floatToFixed(0.5)) == 0.5
    check fixedToFloat(floatToFixed(0.25)) == 0.25

  test "one maps to exactly one":
    check fixedToFloat(floatToFixed(1.0)) == 1.0
    check fixedToFloat(floatToFixed(0.0)) == 0.0

  test "saturates rather than overflowing":
    # int32 tops out at 8.24's 128.0, so values past that must clamp
    check floatToFixed(2.0) == 33554432'i32
    check floatToFixed(1e9) == high(int32)
    check floatToFixed(-1e9) == low(int32)

suite "path: selectors":
  test "the documented codes map both ways":
    for (kind, code) in [(selClosedLength, 0'u16), (selClosedKnotLinked, 1'u16),
        (selClosedKnotUnlinked, 2'u16), (selOpenLength, 3'u16),
        (selOpenKnotLinked, 4'u16), (selOpenKnotUnlinked, 5'u16),
        (selFillRule, 6'u16), (selClipboard, 7'u16), (selInitialFill, 8'u16)]:
      let s = selectorFromU16(code)
      check s.kind == kind
      check s.toU16() == code

  test "an unmodelled code is preserved":
    let s = selectorFromU16(42'u16)
    check s.kind == selOther
    check s.raw == 42'u16
    check s.toU16() == 42'u16

  test "length and knot predicates":
    check selectorFromU16(0'u16).isLength()
    check selectorFromU16(3'u16).isLength()
    check not selectorFromU16(6'u16).isLength()
    for code in [1'u16, 2, 4, 5]:
      check selectorFromU16(code).isKnot()
    check not selectorFromU16(0'u16).isKnot()

suite "path: record stream":
  test "records parse to the documented count":
    let data = lengthRecord(true, 2) & knotRecord(true, 0.5, 0.5) &
      knotRecord(true, 1.0, 1.0)
    let p = parsePathData(data)
    check p.records.len == 3
    check writePathData(p) == data

  test "a tail shorter than a record is ignored when parsing":
    let data = lengthRecord(true, 1) & knotRecord(true, 0.5, 0.5) & "junkjunk"
    check parsePathData(data).records.len == 2

  test "an empty payload has no records":
    check parsePathData("").records.len == 0
    check writePathData(parsePathData("")) == ""

  test "an unknown selector is kept as a record":
    var w = initWriter()
    w.putU16(99'u16)
    for i in 0 ..< 24:
      w.putU8(byte(i))
    let data = w.toString()
    let p = parsePathData(data)
    check p.records[0].selector.kind == selOther
    check p.records[0].selector.raw == 99'u16
    check writePathData(p) == data

  test "initialFill reads the selector-8 record":
    var w = initWriter()
    w.putU16(8'u16)
    w.putU16(1'u16)
    for _ in 1 ..< 24:
      w.putU8(0)
    check parsePathData(w.toString()).initialFill()
    w = initWriter()
    w.putU16(8'u16)
    w.putU16(0'u16)
    for _ in 1 ..< 24:
      w.putU8(0)
    check not parsePathData(w.toString()).initialFill()

suite "path: subpaths":
  test "a closed subpath with knots":
    let p = parsePathData(lengthRecord(true, 2) & knotRecord(true, 0.25, 0.75) &
      knotRecord(false, 1.0, 1.0))
    let subs = p.subpaths()
    check subs.len == 1
    check subs[0].closed
    check subs[0].knots.len == 2
    check subs[0].knots[0].anchorH == 0.25
    check subs[0].knots[0].anchorV == 0.75
    check subs[0].knots[0].linked
    check not subs[0].knots[1].linked

  test "an open subpath":
    let subs = parsePathData(lengthRecord(false, 1) &
      knotRecord(true, 0.5, 0.5)).subpaths()
    check not subs[0].closed

  test "several subpaths":
    let p = parsePathData(lengthRecord(true, 1) & knotRecord(true, 0.1, 0.1) &
      lengthRecord(false, 1) & knotRecord(true, 0.2, 0.2))
    check p.subpaths().len == 2

  test "a knot with no length record starts a subpath rather than failing":
    let subs = parsePathData(knotRecord(true, 0.5, 0.5)).subpaths()
    check subs.len == 1
    check subs[0].knots.len == 1

  test "subpaths survive a write and re-read":
    let p = parsePathData(lengthRecord(true, 2) & knotRecord(true, 0.25, 0.75) &
      knotRecord(false, 1.0, 1.0))
    let subs = p.subpaths()
    let again = pathFromSubPaths(subs).subpaths()
    check again.len == subs.len
    check again[0].knots.len == 2
    check again[0].knots[0].anchorH == subs[0].knots[0].anchorH
    check again[0].knots[1].linked == false

  test "the operation code is preserved":
    var w = initWriter()
    w.putU16(0'u16)
    w.putU16(1'u16)
    w.putU16(3'u16) # operation + 1 = 3, so operation is 2 (subtract)
    for i in 2 ..< 24:
      w.putU8(0)
    check parsePathData(w.toString()).subpaths()[0].operation == 2

suite "path: vector mask block":
  test "a payload parses with its version and flags":
    var w = initWriter()
    w.putU32(3'u32)
    w.putU32(0'u32)
    w.put(lengthRecord(true, 1) & knotRecord(true, 0.5, 0.5))
    let data = w.toString()
    let vm = parseVectorMaskBlock(data)
    check vm.version == 3'u32
    check vm.path.records.len == 2
    check writeVectorMaskBlock(vm) == data

  test "flag bits are readable":
    var w = initWriter()
    w.putU32(3'u32)
    w.putU32(7'u32)
    w.put("")
    let vm = parseVectorMaskBlock(w.toString())
    check vm.isInverted()
    check vm.isNotLinked()
    check vm.isDisabled()

  test "a trailing partial record is preserved verbatim":
    # the fixture's payload is 192 bytes: seven 26-byte records plus ten
    var w = initWriter()
    w.putU32(3'u32)
    w.putU32(0'u32)
    w.put(lengthRecord(true, 1) & knotRecord(true, 0.5, 0.5))
    w.put("0123456789")
    let data = w.toString()
    let vm = parseVectorMaskBlock(data)
    check vm.path.records.len == 2
    check vm.trailing == "0123456789"
    check writeVectorMaskBlock(vm) == data

  test "a payload shorter than the header is rejected":
    expect(PsdError):
      discard parseVectorMaskBlock("\x00\x00\x00\x03")

suite "path: the real fixture":
  test "01.psd layer 0 is a closed four-knot rectangle":
    let f = readPsd(readFile("tests/data/01.psd"))
    let b = f.layers()[0].getBlock("vsms")
    check b.isSome
    let vm = parseVectorMaskBlock(b.get().data)
    check vm.path.records.len == 7
    let subs = vm.path.subpaths()
    check subs.len == 1
    check subs[0].closed
    check subs[0].knots.len == 4
    # anchors sit at the four corners, inset slightly from the edges
    let k = subs[0].knots
    check abs(k[0].anchorH) < 0.01 and abs(k[0].anchorV) < 0.01
    check abs(k[2].anchorH - 1.0) < 0.01
    check abs(k[2].anchorV - 1.0) < 0.01
    for knot in k:
      check knot.linked

  test "the fixture vector mask rewrites byte for byte":
    let f = readPsd(readFile("tests/data/01.psd"))
    let b = f.layers()[0].getBlock("vsms")
    let vm = parseVectorMaskBlock(b.get().data)
    check writeVectorMaskBlock(vm) == b.get().data
# --- saved and work paths as resources --------------------------------------

proc subpathFixture(): seq[SubPath] =
  ## Two subpaths: a closed one with three knots and an open one with one.
  ## Fields are `*H` (horizontal) then `*V` (vertical) fractions of the
  ## document size, matching the 8.24 storage order.
  @[
    SubPath(closed: true, operation: 1, knots: @[
      Knot(linked: false, preH: 0.25, preV: 0.25, anchorH: 0.25,
        anchorV: 0.25, postH: 0.25, postV: 0.25),
      Knot(linked: true, preH: 0.625, preV: 0.125, anchorH: 0.75,
        anchorV: 0.25, postH: 0.875, postV: 0.375),
      Knot(linked: false, preH: 0.5, preV: 0.75, anchorH: 0.5, anchorV: 0.75,
        postH: 0.5, postV: 0.75),
    ]),
    SubPath(closed: false, operation: 2, knots: @[
      Knot(linked: false, preH: -0.5, preV: 1.5, anchorH: 0.0, anchorV: 1.0,
        postH: 0.0625, postV: 0.9375),
    ]),
  ]

suite "path resources: saved paths":
  test "a saved path resource round-trips through its record list":
    let bytes = writePathData(pathFromSubPaths(subpathFixture(), true))
    let res = newImageResource(2000, bytes)
    let p = parsePathResource(res)
    # initial fill, 2 subpath lengths, 4 knots
    check p.records.len == 7
    check p.initialFill()
    check p.subpaths().len == 2
    check p.subpaths()[0].knots.len == 3

  test "every saved path is found in resource order":
    let bytes = writePathData(pathFromSubPaths(subpathFixture()))
    var resources = @[
      newImageResource(1005, "\x00" & repeat('\x00', 15)),
      newImageResource(2000, bytes),
      newImageResource(2001, bytes),
      newImageResource(2997, bytes),
      newImageResource(1050, "junk"),
    ]
    let found = savedPaths(resources)
    check found.len == 3
    check found[0].id == 2000
    check found[1].id == 2001
    check found[2].id == 2997
    check found[0].path.records.len == 6   # 2 lengths + 4 knots, no fill

  test "the resource ids outside 2000-2997 are not treated as paths":
    check not isPathResource(1025)
    check not isPathResource(2998)
    check not isPathResource(1999)
    check isPathResource(2000)
    check isPathResource(2997)

  test "the Pascal name is carried through":
    var res = newImageResource(2000,
      writePathData(pathFromSubPaths(subpathFixture())))
    res.name = "Guide"
    check savedPaths(@[res])[0].name == "Guide"

  test "an empty record list is valid":
    let res = newImageResource(2000, "")
    check parsePathResource(res).records.len == 0
    check parsePathResource(res).subpaths().len == 0

  test "trailing bytes shorter than a record are ignored":
    let good = writePathData(pathFromSubPaths(subpathFixture()))
    check parsePathResource(newImageResource(2000, good & "xyz")).records.len ==
      good.len div PathRecordLen

  test "no path resources yields nothing":
    let empty: seq[ImageResource] = @[]
    check savedPaths(empty).len == 0

suite "path resources: the work path":
  test "the work path is read from resource 1025":
    let bytes = writePathData(pathFromSubPaths(subpathFixture()))
    let p = workPath(@[newImageResource(WorkPathId, bytes)]).get()
    check p.records.len == 6
    check p.subpaths().len == 2

  test "1025 is not a saved path":
    let bytes = writePathData(pathFromSubPaths(subpathFixture()))
    check savedPaths(@[newImageResource(WorkPathId, bytes)]).len == 0

  test "a missing work path reports none":
    let empty: seq[ImageResource] = @[]
    check workPath(empty).isNone
    check workPath(@[newImageResource(2000, "")]).isNone

suite "path resources: the real fixtures":
  test "01.psd has neither saved paths nor a work path":
    let f = readPsd(readFile("tests/data/01.psd"))
    check f.savedPaths().len == 0
    check f.workPath().isNone

  test "no fixture resource id falls in the saved-path range":
    for path in ["tests/data/01.psd", "tests/data/03.psd"]:
      let f = readPsd(readFile(path))
      for res in f.resources:
        check not isPathResource(res.id)

  test "the vector mask path is unaffected by the resource work":
    let f = readPsd(readFile("tests/data/01.psd"))
    let vm = f.layers()[0].vectorMask().get()
    check vm.path.records.len == 7
    check writeVectorMaskBlock(vm) == f.layers()[0].getBlock("vsms").get().data
