## Minimal non-premultiplied pixel buffer (stdlib only).
## A future pixie adapter can convert from ImageBuf without
## touching the decoders.

import ./types

type
  Rgba* = object
    r*, g*, b*, a*: uint8

  ImageBuf* = object
    width*: int
    height*: int
    data*: seq[Rgba] # row major, len == width * height

proc initImageBuf*(width, height: int, fill = Rgba(r: 0, g: 0, b: 0, a: 255)): ImageBuf =
  ImageBuf(width: width, height: height, data: newSeq[Rgba](width * height))

proc isEmpty*(img: ImageBuf): bool {.inline.} =
  img.width <= 0 or img.height <= 0 or img.data.len == 0

proc checkNotEmpty(img: ImageBuf, what: string) {.inline.} =
  if img.isEmpty():
    raise newException(PsdError, "cannot " & what & ": empty image")

proc getPixel*(img: ImageBuf, x, y: int): Rgba {.inline.} =
  img.data[y * img.width + x]

proc setPixel*(img: var ImageBuf, x, y: int, c: Rgba) {.inline.} =
  img.data[y * img.width + x] = c

proc toRgbBytes*(img: ImageBuf): seq[byte] =
  result = newSeqOfCap[byte](img.width * img.height * 3)
  for p in img.data:
    result.add(p.r)
    result.add(p.g)
    result.add(p.b)

proc savePpm*(img: ImageBuf, path: string) =
  ## Write binary P6 PPM for eyeball checks without dependencies.
  ## Note: macOS Preview cannot open PPM; use saveBmp for previews
  ## or open PPM in GIMP, Photoshop, or VS Code image preview.
  checkNotEmpty(img, "write PPM")
  var f = open(path, fmWrite)
  defer: close(f)
  # NOTE: plain concatenation, not fmt, so \n stays a real newline.
  let header = "P6\n" & $img.width & " " & $img.height & "\n255\n"
  discard f.writeBuffer(unsafeAddr header[0], header.len)
  let rgb = img.toRgbBytes()
  discard f.writeBuffer(unsafeAddr rgb[0], rgb.len)

proc bmpStride*(width: int): int {.inline.} =
  ## Padded row size for 24-bit BMP (rows align to 4 bytes).
  ((width * 3 + 3) div 4) * 4

proc putU16LE(b: var seq[byte], v: uint16) {.inline.} =
  b.add(byte(v and 0xFF))
  b.add(byte(v shr 8))

proc putU32LE(b: var seq[byte], v: uint32) {.inline.} =
  b.add(byte(v and 0xFF))
  b.add(byte((v shr 8) and 0xFF))
  b.add(byte((v shr 16) and 0xFF))
  b.add(byte(v shr 24))

proc putI32LE(b: var seq[byte], v: int32) {.inline.} =
  putU32LE(b, cast[uint32](v))

proc saveBmp*(img: ImageBuf, path: string) =
  ## Write 24-bit uncompressed BMP (opens in macOS Preview).
  ## Alpha is dropped, matching savePpm behavior.
  checkNotEmpty(img, "write BMP")
  let stride = bmpStride(img.width)
  let pixelSize = stride * img.height
  var hdr: seq[byte] = @[]
  hdr.add(byte('B')); hdr.add(byte('M'))
  putU32LE(hdr, uint32(54 + pixelSize)) # file size
  putU16LE(hdr, 0); putU16LE(hdr, 0) # reserved
  putU32LE(hdr, 54) # pixel offset
  putU32LE(hdr, 40) # BITMAPINFOHEADER size
  putI32LE(hdr, int32(img.width))
  putI32LE(hdr, int32(img.height)) # positive: bottom-up
  putU16LE(hdr, 1) # planes
  putU16LE(hdr, 24) # bits per pixel
  putU32LE(hdr, 0) # BI_RGB, no compression
  putU32LE(hdr, uint32(pixelSize))
  putI32LE(hdr, 2835) # h resolution, ~72 DPI
  putI32LE(hdr, 2835) # v resolution
  putU32LE(hdr, 0) # palette colors
  putU32LE(hdr, 0) # important colors
  var f = open(path, fmWrite)
  defer: close(f)
  discard f.writeBuffer(unsafeAddr hdr[0], hdr.len)
  var row = newSeq[byte](stride)
  for y in countdown(img.height - 1, 0):
    for x in 0 ..< img.width:
      let p = img.data[y * img.width + x]
      row[x * 3] = p.b
      row[x * 3 + 1] = p.g
      row[x * 3 + 2] = p.r
    for i in img.width * 3 ..< stride:
      row[i] = 0
    discard f.writeBuffer(unsafeAddr row[0], stride)
