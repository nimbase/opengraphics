## Export tests: format enum, memory encoding, file saves.
##
## PSD composites and PDF images share the same entry points.
## File saves go to the OS temp dir and are removed afterwards.

import std/os
import std/strutils
import unittest
import ../src/opengraphics/psd
import ../src/opengraphics/pdf

test "extension mapping":
  check formatForPath("a.jpg") == fmtJpeg
  check formatForPath("a.JPEG") == fmtJpeg
  check formatForPath("a.png") == fmtPng
  check formatForPath("a.webp") == fmtWebP
  check formatForPath("a.tif") == fmtTiff
  check formatForPath("a.tiff") == fmtTiff
  check formatForPath("a.gif") == fmtGif
  check formatForPath("a.heic") == fmtHeif
  check formatForPath("a.avif") == fmtAvif
  check formatForPath("a.jxl") == fmtJxl
  expect(ExportError):
    discard formatForPath("a.bmp")
  expect(ExportError):
    discard formatForPath("noext")

test "psd composite encodes jpeg png webp":
  let doc = openPsd("tests" / "data" / "01.psd")
  let jpg = encodeImage(doc.composite, fmtJpeg)
  check jpg.len > 100
  check byte(jpg[0]) == 0xFF and byte(jpg[1]) == 0xD8
  let png = encodeImage(doc.composite, fmtPng)
  check png[0 ..< 4] == "\x89PNG"
  let webp = encodeImage(doc.composite, fmtWebP)
  check webp[0 ..< 4] == "RIFF" and webp[8 ..< 12] == "WEBP"

test "alpha flattens for jpeg":
  var img = initImageBuf(2, 1)
  img.setPixel(0, 0, Rgba(r: 255, g: 0, b: 0, a: 0))
  img.setPixel(1, 0, Rgba(r: 0, g: 0, b: 255, a: 255))
  let jpg = encodeImage(img, fmtJpeg)
  check byte(jpg[0]) == 0xFF and byte(jpg[1]) == 0xD8
  let png = encodeImage(img, fmtPng)
  check png[0 ..< 4] == "\x89PNG"

test "pdf image encodes png":
  var d = openDoc(readFile("tests" / "data" / "pdf" / "m5_images.pdf"))
  var found = false
  for im in d.pageImages(0):
    if im.name == "Im1":
      let png = encodeImage(im, fmtPng)
      check png[0 ..< 4] == "\x89PNG"
      found = true
  check found

test "tiff without memory encoder names saveImage":
  let doc = openPsd("tests" / "data" / "01.psd")
  try:
    discard encodeImage(doc.composite, fmtTiff)
    fail()
  except ExportError as e:
    check "saveImage" in e.msg

test "empty image fails":
  expect(ExportError):
    discard encodeImage(ImageBuf(), fmtPng)

test "file saves round-trip":
  let doc = openPsd("tests" / "data" / "01.psd")
  let jpg = getTempDir() / "opengraphics_test.jpg"
  let png = getTempDir() / "opengraphics_test.png"
  let tif = getTempDir() / "opengraphics_test.tif"
  doc.composite.saveImage(jpg)
  doc.composite.saveImage(png)
  doc.composite.saveImage(tif)
  check getFileSize(jpg) > 100
  check readFile(png)[0 ..< 4] == "\x89PNG"
  check readFile(tif)[0 ..< 4] == "II*\x00"
  removeFile(jpg)
  removeFile(png)
  removeFile(tif)
