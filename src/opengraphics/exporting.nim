## High-level image export through the pure-Nim image package.
##
## One format enum plus options shared by every module: PSD composites
## (ImageBuf) convert to ExportPixels and encode or save. JPEG, PNG and
## WebP encode to memory; every implemented format saves to a path,
## dispatched by file extension. Alpha flattens over white for JPEG
## (and GIF, whose palette carries no alpha); image errors surface as
## ExportError.
##
## HEIF, AVIF and JXL have no pure-Nim encoders upstream (stubs), so
## saving to those formats fails loudly naming the gap instead of
## silently producing nothing. TIFF and GIF encode to memory upstream
## but the API keeps them path-only, like before.

import std/strutils

import image/buffer
import image/color
import image/dynamic
import image/error
import image/codecs/jpeg
import image/codecs/png
import image/codecs/tiff
import image/codecs/gif
import image/codecs/webp
import ./psd/pixels

type
  ExportError* = object of CatchableError

  ImageFormat* = enum
    fmtJpeg, fmtPng, fmtWebP, fmtTiff, fmtGif, fmtHeif, fmtAvif, fmtJxl

  ExportOptions* = object
    jpegQuality*: range[0..100] = 90
    pngCompression*: range[0..9] = 6 ## accepted, currently unused: the
      ## upstream PNG encoder picks its own filtering
    webpQuality*: range[0..100] = 90

  ExportPixels* = object
    width*: int
    height*: int
    bands*: int ## 1 gray, 3 rgb, 4 rgb+alpha (8-bit)
    data*: string

proc exportFail(msg: string) {.noreturn.} =
  raise newException(ExportError, msg)

proc formatForExt*(ext: string): ImageFormat =
  ## Map a file extension (with or without dot, any case) to a format.
  case ext.toLowerAscii().strip(chars = {'.'})
  of "jpg", "jpeg": fmtJpeg
  of "png": fmtPng
  of "webp": fmtWebP
  of "tif", "tiff": fmtTiff
  of "gif": fmtGif
  of "heif", "heic": fmtHeif
  of "avif": fmtAvif
  of "jxl": fmtJxl
  else: exportFail("unsupported image extension '." & ext &
      "' (want jpg, png, webp, tif, gif, heif, avif or jxl)")

proc formatForPath*(path: string): ImageFormat =
  let dot = path.rfind('.')
  if dot < 0:
    exportFail("cannot infer image format from '" & path &
      "' (no extension)")
  formatForExt(path[dot + 1 .. ^1])

proc toExportPixels*(img: ImageBuf): ExportPixels =
  if img.isEmpty():
    exportFail("cannot export an empty image")
  result = ExportPixels(width: img.width, height: img.height, bands: 4,
    data: newString(img.width * img.height * 4))
  for i, p in img.data:
    result.data[4 * i] = char(p.r)
    result.data[4 * i + 1] = char(p.g)
    result.data[4 * i + 2] = char(p.b)
    result.data[4 * i + 3] = char(p.a)

proc flattenWhite(px: ExportPixels): ExportPixels =
  ## Drop alpha over a white background (for formats without alpha).
  if px.bands != 2 and px.bands != 4:
    return px
  let comps = px.bands - 1
  result = ExportPixels(width: px.width, height: px.height,
    bands: comps, data: newString(px.width * px.height * comps))
  for i in 0 ..< px.width * px.height:
    let a = int(byte(px.data[i * px.bands + comps]))
    for c in 0 ..< comps:
      let v = int(byte(px.data[i * px.bands + c]))
      result.data[i * comps + c] = char(v * a div 255 +
        255 * (255 - a) div 255)

proc toDynamic(px: ExportPixels): DynamicImage =
  ## ExportPixels to an image-package dynamic image (RGBA8 or RGB8).
  if px.width <= 0 or px.height <= 0 or
      px.data.len != px.width * px.height * px.bands:
    exportFail("export pixel size mismatch")
  if px.bands == 4:
    var pixels = newSeq[color.Rgba[uint8]](px.width * px.height)
    for i in 0 ..< pixels.len:
      pixels[i] = color.Rgba[uint8](data: [byte(px.data[4 * i]),
        byte(px.data[4 * i + 1]), byte(px.data[4 * i + 2]),
        byte(px.data[4 * i + 3])])
    let r = fromRaw(uint32(px.width), uint32(px.height), move(pixels))
    if not r.ok:
      exportFail("export pixel size mismatch")
    DynamicImage(kind: dkRgba8, rgba8: r.img)
  elif px.bands == 3:
    var pixels = newSeq[color.Rgb[uint8]](px.width * px.height)
    for i in 0 ..< pixels.len:
      pixels[i] = color.Rgb[uint8](data: [byte(px.data[3 * i]),
        byte(px.data[3 * i + 1]), byte(px.data[3 * i + 2])])
    let r = fromRaw(uint32(px.width), uint32(px.height), move(pixels))
    if not r.ok:
      exportFail("export pixel size mismatch")
    DynamicImage(kind: dkRgb8, rgb8: r.img)
  else:
    exportFail("export needs 3 or 4 bands, got " & $px.bands)

proc toBytes(data: seq[uint8]): string =
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc encodeLossy(px: ExportPixels, format: ImageFormat,
    opts: ExportOptions): string =
  ## JPEG/PNG/WebP to bytes; anything else names saveImage, like before.
  let img =
    if format == fmtJpeg: toDynamic(flattenWhite(px))
    else: toDynamic(px)
  let encoded =
    case format
    of fmtJpeg: encodeJpeg(img, opts.jpegQuality)
    of fmtPng: encodePng(img)
    of fmtWebP: encodeWebpLossy(img.toRgba8(), opts.webpQuality)
    else: exportFail("format " & $format &
        " has no memory encoder (use saveImage with a path)")
  if not encoded.isOk:
    exportFail("image encode failed (" & encoded.err.msg & ")")
  toBytes(encoded.value)

proc encodeImage*(px: ExportPixels, format: ImageFormat,
    opts = ExportOptions()): string =
  ## Encode to JPEG, PNG or WebP bytes. Other formats need a path
  ## (use saveImage); conversions without a memory encoder fail loudly.
  encodeLossy(px, format, opts)

proc encodeImage*(img: ImageBuf, format: ImageFormat,
    opts = ExportOptions()): string =
  encodeImage(img.toExportPixels(), format, opts)

const GifPaletteSteps = 6
  ## Uniform 6x6x6 color cube for GIF export (216 colors). No quantizer
  ## upstream, so the save path maps to the nearest cube entry; alpha
  ## is flattened over white first, like JPEG.

proc gifIndices(px: ExportPixels): seq[uint8] =
  ## Flattened pixels to palette indices into the 216-color cube.
  let flat = flattenWhite(px)
  result = newSeq[uint8](flat.width * flat.height)
  for i in 0 ..< result.len:
    let r = int(byte(flat.data[3 * i]))
    let g = int(byte(flat.data[3 * i + 1]))
    let b = int(byte(flat.data[3 * i + 2]))
    result[i] = uint8((r * (GifPaletteSteps - 1) div 255) *
      GifPaletteSteps * GifPaletteSteps +
      (g * (GifPaletteSteps - 1) div 255) * GifPaletteSteps +
      (b * (GifPaletteSteps - 1) div 255))

proc gifPalette(): seq[tuple[r, g, b: uint8]] =
  for r in 0 ..< GifPaletteSteps:
    for g in 0 ..< GifPaletteSteps:
      for b in 0 ..< GifPaletteSteps:
        result.add((uint8(r * 255 div (GifPaletteSteps - 1)),
          uint8(g * 255 div (GifPaletteSteps - 1)),
          uint8(b * 255 div (GifPaletteSteps - 1))))

proc saveImage*(px: ExportPixels, path: string,
    opts = ExportOptions()) =
  ## Save to path, dispatching on the file extension. JPEG honors
  ## jpegQuality, WebP honors webpQuality; HEIF, AVIF and JXL have no
  ## pure-Nim encoder and fail loudly.
  if px.width <= 0 or px.height <= 0:
    exportFail("cannot export an empty image")
  if px.width > 65535 or px.height > 65535:
    exportFail("image is too large for GIF dimensions")
  let format = formatForPath(path)
  let bytes =
    case format
    of fmtJpeg, fmtPng, fmtWebP:
      encodeLossy(px, format, opts)
    of fmtTiff:
      let enc = encodeTiff(toDynamic(px))
      if not enc.isOk:
        exportFail("image encode failed (" & enc.err.msg & ")")
      toBytes(enc.value)
    of fmtGif:
      let gif = encodeGif(@[gifIndices(px)], uint16(px.width),
        uint16(px.height), gifPalette())
      var gifBytes = newString(gif.len)
      if gif.len > 0:
        copyMem(addr gifBytes[0], unsafeAddr gif[0], gif.len)
      gifBytes
    of fmtHeif, fmtAvif, fmtJxl:
      exportFail("format " & $format &
        " has no pure-Nim encoder (heif/avif/jxl encoding is not " &
        "implemented upstream)")
  writeFile(path, bytes)

proc saveImage*(img: ImageBuf, path: string,
    opts = ExportOptions()) =
  saveImage(img.toExportPixels(), path, opts)
