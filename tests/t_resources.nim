import unittest
import std/options
import ../src/opengraphics/psd/reader
import ../src/opengraphics/psd/resources
import ../src/opengraphics/psd/types
import ./support

test "empty resources parse":
  var r = initReader(@[byte(0), 0, 0, 0])
  let res = parseResources(r)
  check res.blocks.len == 0

test "single block round-trips with odd-size padding":
  var raw: seq[byte] = @[]
  putU32BE(raw, 20) # section len: filled below? compute manually
  # Build one block: sig + id + name + size + data + pad
  var blk: seq[byte] = @[]
  putStr(blk, "8BIM")
  putU16BE(blk, 1005)
  putPascalEven(blk, "")
  putU32BE(blk, 3)
  blk.add(byte(1)); blk.add(byte(2)); blk.add(byte(3))
  blk.add(byte(0)) # pad to even
  # section len = blk.len
  raw = @[]
  putU32BE(raw, uint32(blk.len))
  for v in blk: raw.add(v)
  var r = initReader(raw)
  let res = parseResources(r)
  check res.blocks.len == 1
  check res.blocks[0].id == 1005
  check res.blocks[0].data == @[byte(1), 2, 3]
  check res.findResource(1005) == 0
  check res.findResource(9999) == -1

test "resolution info decodes":
  var d: seq[byte] = @[]
  putI32BE(d, 720000)
  putI16BE(d, 1)
  putI16BE(d, 1)
  putI32BE(d, 720000)
  putI16BE(d, 1)
  putI16BE(d, 1)
  let ri = parseResolution(d)
  check ri.hRes == 720000

proc thumbPayload(w, h: int, jpeg: seq[byte]): seq[byte] =
  result = @[]
  putU32BE(result, 1) # kJpegRGB
  putU32BE(result, uint32(w))
  putU32BE(result, uint32(h))
  putU32BE(result, uint32(w * 3)) # widthBytes
  putU32BE(result, uint32(w * h * 3)) # totalSize
  putU32BE(result, uint32(jpeg.len))
  putU16BE(result, 24)
  putU16BE(result, 1)
  for v in jpeg: result.add(v)

test "thumbnail parses and prefers RGB over BGR":
  let jpeg = @[byte(0xFF), 0xD8, 0x01, 0x02, 0xFF, 0xD9]
  var res = ImageResources(blocks: @[
    ResourceBlock(id: 1033, name: "", data: thumbPayload(4, 4, jpeg)),
    ResourceBlock(id: 1036, name: "", data: thumbPayload(8, 6, jpeg)),
  ])
  let t = res.getThumbnail()
  check t.isSome
  check t.get.width == 8
  check t.get.height == 6
  check t.get.format == 1
  check t.get.jpeg == jpeg

test "thumbnail absent or skipped gives none":
  check ImageResources(blocks: @[]).getThumbnail().isNone
  let empty = ImageResources(blocks: @[
    ResourceBlock(id: 1036, name: "", data: @[]),
  ])
  check empty.getThumbnail().isNone

test "short thumbnail raises":
  expect(PsdError):
    discard parseThumbnail(@[byte(1), 2, 3])

test "icc profile lookup":
  check ImageResources(blocks: @[]).iccProfile() == newSeq[byte]()
  check not ImageResources(blocks: @[]).hasIccProfile()
  let withIcc = ImageResources(blocks: @[
    ResourceBlock(id: 1040, name: "", data: @[byte(0), byte(0), byte(0), byte(8), byte(1), byte(2), byte(3), byte(4)]),
    ResourceBlock(id: 1039, name: "", data: @[byte(0), byte(0), byte(0), byte(4), byte(9), byte(9)]),
  ])
  check withIcc.hasIccProfile()
  check withIcc.iccProfile() == @[byte(0), byte(0), byte(0), byte(4), byte(9), byte(9)]
