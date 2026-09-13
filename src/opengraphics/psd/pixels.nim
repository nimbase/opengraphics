## Minimal non-premultiplied pixel buffer (stdlib only).
## A future pixie adapter can convert from ImageBuf without
## touching the decoders.

import std/strformat

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
  var f = open(path, fmWrite)
  defer: close(f)
  f.write(fmt"P6\n{img.width} {img.height}\n255\n")
  var raw = newString(img.width * img.height * 3)
  var k = 0
  for p in img.data:
    raw[k] = char(p.r); inc k
    raw[k] = char(p.g); inc k
    raw[k] = char(p.b); inc k
  f.write(raw)
