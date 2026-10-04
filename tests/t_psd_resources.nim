## Image resources against the promoted core API.
##
## Resource framing, resolution and the ICC lookup are covered in depth by
## `t_psd_core_resources`. What is left here is the thumbnail view, which lives
## in `document.nim` because it is a decoded convenience rather than a
## round-tripped model.

import std/options
import std/os
import unittest
import ../src/opengraphics/psd

proc solidRgba(w, h: int, r, g, bl, a: uint8): PixelData =
  result = initRgba8(w, h)
  for i in 0 ..< w * h:
    result.rgba8[i * 4 + 0] = r
    result.rgba8[i * 4 + 1] = g
    result.rgba8[i * 4 + 2] = bl
    result.rgba8[i * 4 + 3] = a

proc thumbPayload(w, h: int, jpeg: string): string =
  var w2 = initWriter()
  w2.putU32(1)                      # kJpegRGB
  w2.putU32(uint32(w))
  w2.putU32(uint32(h))
  w2.putU32(uint32(w * 3))          # widthBytes
  w2.putU32(uint32(w * h * 3))      # totalSize
  w2.putU32(uint32(jpeg.len))
  w2.putU16(24)
  w2.putU16(1)
  w2.put(jpeg)
  w2.toString()

proc docWithThumbnails(res: seq[ImageResource]): Document =
  ## The smallest document that carries resources: a 1x1 RGB file.
  var b = initPsdBuilder(1, 1)
  for r in res:
    b.addResource(r)
  b.setComposite(solidRgba(1, 1, 0'u8, 0'u8, 0'u8, 255'u8))
  readPsdBytes(b.toBytes())


test "empty resources parse":
  var r = initReader("\x00\x00\x00\x00")
  check readResourceSection(r).len == 0

test "single block round-trips with odd-size padding":
  var b = initWriter()
  b.putStr4("8BIM")
  b.putU16(1005)
  b.writePascal("", 2)
  b.putU32(3)
  b.put("\x01\x02\x03")
  var blk = b.toString()
  blk.add(char(0)) # pad to even
  var rw = initWriter()
  rw.putU32(uint32(blk.len))
  rw.put(blk)
  let raw = rw.toString()
  var r = initReader(raw)
  let res = readResourceSection(r)
  check res.len == 1
  check res[0].id == 1005
  check res[0].data == "\x01\x02\x03"
  check findResource(res, 1005) == 0
  check findResource(res, 9999) == -1

test "resolution info decodes":
  var w = initWriter()
  writeResolution(w, ResolutionInfo(hResFixed: 720000'u32, hResUnit: 1,
    widthUnit: 1, vResFixed: 720000'u32, vResUnit: 1, heightUnit: 1))
  let d = w.toString()
  check readResolution(d).hResFixed == 720000'u32
  check abs(readResolution(d).hRes() - 720000.0 / 65536.0) < 1e-9

test "thumbnail parses and prefers RGB over BGR":
  let jpeg = "\xFF\xD8\x01\x02\xFF\xD9"
  let doc = docWithThumbnails(@[
    newImageResource(1033, thumbPayload(4, 4, jpeg)),
    newImageResource(1036, thumbPayload(8, 6, jpeg)),
  ])
  let t = doc.thumbnailOf().get
  check t.width == 8
  check t.height == 6
  check t.format == 1
  check t.bitsPerPixel == 24
  check t.planes == 1
  check t.jpeg == jpeg

test "thumbnail falls back to BGR when 1036 is absent":
  let doc = docWithThumbnails(@[
    newImageResource(1033, thumbPayload(4, 4, "\xFF\xD8\xFF\xD9")),
  ])
  let t = doc.thumbnailOf().get
  check t.width == 4
  check t.height == 4

test "thumbnail absent or empty gives none":
  check docWithThumbnails(@[]).thumbnailOf().isNone
  check not docWithThumbnails(@[]).hasThumbnail()
  check docWithThumbnails(@[newImageResource(1036, "")]).thumbnailOf().isNone

test "hasThumbnail and save round-trip":
  let jpeg = "\xFF\xD8\x01\x02\xFF\xD9"
  let doc = docWithThumbnails(@[newImageResource(1036, thumbPayload(8, 6, jpeg))])
  check doc.hasThumbnail()
  let path = getTempDir() / "psd_test_thumb.jpg"
  doc.saveThumbnailJpeg(path)
  check readFile(path) == jpeg

  # the Thumbnail overload writes the same bytes
  let path2 = getTempDir() / "psd_test_thumb2.jpg"
  doc.thumbnailOf().get.saveThumbnailJpeg(path2)
  check readFile(path2) == jpeg

test "saveThumbnailJpeg raises without a payload":
  expect(PsdError):
    docWithThumbnails(@[]).saveThumbnailJpeg(getTempDir() / "psd_nothumb.jpg")
  expect(PsdError):
    Thumbnail(format: 1, width: 8, height: 6, bitsPerPixel: 24, planes: 1,
      jpeg: "").saveThumbnailJpeg(getTempDir() / "psd_emptythumb.jpg")

test "short thumbnail raises":
  expect(PsdError):
    discard parseThumbnail("\x01\x02\x03")

test "a thumbnail whose length disagrees with its header raises":
  var d = thumbPayload(8, 6, "\xFF\xD8\xFF\xD9")
  # rewrite compSize to something wrong
  # compSize sits at byte 20: format 4 + width 4 + height 4 + widthBytes 4 + totalSize 4
  d[20] = char(0); d[21] = char(0); d[22] = char(0); d[23] = char(99)
  expect(PsdError):
    discard parseThumbnail(d)

test "skipThumbnail clears the payload at read time":
  let jpeg = "\xFF\xD8\x01\x02\xFF\xD9"
  var b = initPsdBuilder(1, 1)
  b.addResource(newImageResource(1036, thumbPayload(8, 6, jpeg)))
  b.setComposite(solidRgba(1, 1, 0, 0, 0, 255))
  let skipped = readPsdBytes(b.toBytes(), ReadOptions(skipThumbnail: true))
  check not skipped.hasThumbnail()
  check skipped.hasComposite # unrelated sections still decode

test "icc profile lookup":
  let noneDoc = docWithThumbnails(@[])
  check noneDoc.iccProfile() == ""
  check not noneDoc.hasIccProfile()

  let withIcc = docWithThumbnails(@[
    newImageResource(1040, "\x00\x00\x00\x08\x01\x02\x03\x04"),
    newImageResource(1039, "\x00\x00\x00\x04\x09\x09"),
  ])
  check withIcc.hasIccProfile()
  # 1039 wins over the 1040 fallback
  check withIcc.iccProfile() == "\x00\x00\x00\x04\x09\x09"