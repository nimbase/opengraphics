## Pixel buffers for the builder, keyed by colour mode and bit depth.
##
## Samples are interleaved and include alpha. CMYK values are *ink amounts*
## (0 = no ink, full = maximum ink); PSD stores them inverted, so the builder
## inverts on the way in and callers never deal with the storage form.
##
## A buffer's own mode and depth must match the document being built. `init` and
## friends size the buffer from a width and height so the length arithmetic
## cannot be got wrong by hand.

import ./error
import ./header

type
  PixelKind* {.pure.} = enum
    ## One variant per (colour mode, depth) pair the builder supports.
    pkRgba8, pkRgba16, pkGrayA8, pkGrayA16, pkCmyka8, pkCmyka16

  PixelData* = object
    ## Interleaved samples with trailing alpha.
    case kind*: PixelKind
    of pkRgba8: rgba8*: seq[uint8]
    of pkRgba16: rgba16*: seq[uint16]
    of pkGrayA8: grayA8*: seq[uint8]
    of pkGrayA16: grayA16*: seq[uint16]
    of pkCmyka8: cmyka8*: seq[uint8]
    of pkCmyka16: cmyka16*: seq[uint16]

proc initRgba8*(w, h: int): PixelData {.inline.} =
  PixelData(kind: pkRgba8, rgba8: newSeq[uint8](w * h * 4))

proc initRgba16*(w, h: int): PixelData {.inline.} =
  PixelData(kind: pkRgba16, rgba16: newSeq[uint16](w * h * 4))

proc initGrayA8*(w, h: int): PixelData {.inline.} =
  PixelData(kind: pkGrayA8, grayA8: newSeq[uint8](w * h * 2))

proc initGrayA16*(w, h: int): PixelData {.inline.} =
  PixelData(kind: pkGrayA16, grayA16: newSeq[uint16](w * h * 2))

proc initCmyka8*(w, h: int): PixelData {.inline.} =
  PixelData(kind: pkCmyka8, cmyka8: newSeq[uint8](w * h * 5))

proc initCmyka16*(w, h: int): PixelData {.inline.} =
  PixelData(kind: pkCmyka16, cmyka16: newSeq[uint16](w * h * 5))

proc samplesPerPixel*(p: PixelData): int =
  ## Samples per pixel including alpha.
  case p.kind
  of pkRgba8, pkRgba16: 4
  of pkGrayA8, pkGrayA16: 2
  of pkCmyka8, pkCmyka16: 5

proc colorMode*(p: PixelData): ColorMode =
  ## The colour mode this buffer implies.
  case p.kind
  of pkRgba8, pkRgba16: ColorMode(kind: cmRgb)
  of pkGrayA8, pkGrayA16: ColorMode(kind: cmGrayscale)
  of pkCmyka8, pkCmyka16: ColorMode(kind: cmCmyk)

proc depth*(p: PixelData): int =
  ## Bits per sample: 8 or 16.
  case p.kind
  of pkRgba8, pkGrayA8, pkCmyka8: 8
  of pkRgba16, pkGrayA16, pkCmyka16: 16

proc sampleCount*(p: PixelData): int =
  ## Total samples held, across all components. Only the variant matching
  ## `kind` is readable, so this cannot touch an inactive field.
  case p.kind
  of pkRgba8: p.rgba8.len
  of pkGrayA8: p.grayA8.len
  of pkCmyka8: p.cmyka8.len
  of pkRgba16: p.rgba16.len
  of pkGrayA16: p.grayA16.len
  of pkCmyka16: p.cmyka16.len

proc isEmpty*(p: PixelData): bool {.inline.} = p.sampleCount() == 0

proc colorChannels*(mode: ColorMode): int =
  ## Colour planes this mode stores, excluding alpha. Raises for a mode the
  ## builder cannot represent.
  case mode.kind
  of cmRgb: result = 3
  of cmGrayscale: result = 1
  of cmCmyk: result = 4
  else:
    unsupported("builder colour mode " & $mode.kind)

proc plane*(p: PixelData, component: int, pixelCount: int): string =
  ## Planar big-endian samples for interleaved `component` (0-based, alpha is
  ## the last component), stored as PSD keeps them, so CMYK ink is inverted.
  let spp = p.samplesPerPixel()
  if spp == 0 or pixelCount <= 0:
    return ""
  # Only the four ink components are stored inverted; alpha is not ink.
  let invert = p.colorMode().kind == cmCmyk and component < 4
  result = newString(pixelCount * (p.depth() div 8))
  case p.kind
  of pkRgba8:
    for i in 0 ..< pixelCount:
      let s = p.rgba8[i * spp + component]
      result[i] = char(if invert: 255'u8 - s else: s)
  of pkGrayA8:
    for i in 0 ..< pixelCount:
      let s = p.grayA8[i * spp + component]
      result[i] = char(if invert: 255'u8 - s else: s)
  of pkCmyka8:
    for i in 0 ..< pixelCount:
      let s = p.cmyka8[i * spp + component]
      result[i] = char(if invert: 255'u8 - s else: s)
  of pkRgba16:
    for i in 0 ..< pixelCount:
      let s = if invert: 0xFFFF'u16 - p.rgba16[i * spp + component]
              else: p.rgba16[i * spp + component]
      result[i * 2] = char(byte(s shr 8))
      result[i * 2 + 1] = char(byte(s and 0xFF'u16))
  of pkGrayA16:
    for i in 0 ..< pixelCount:
      let s = if invert: 0xFFFF'u16 - p.grayA16[i * spp + component]
              else: p.grayA16[i * spp + component]
      result[i * 2] = char(byte(s shr 8))
      result[i * 2 + 1] = char(byte(s and 0xFF'u16))
  of pkCmyka16:
    for i in 0 ..< pixelCount:
      let s = if invert: 0xFFFF'u16 - p.cmyka16[i * spp + component]
              else: p.cmyka16[i * spp + component]
      result[i * 2] = char(byte(s shr 8))
      result[i * 2 + 1] = char(byte(s and 0xFF'u16))

proc alphaIsOpaque*(p: PixelData, pixelCount: int): bool =
  ## Whether every alpha sample is at full coverage, in which case the merged
  ## image can drop its alpha plane.
  let spp = p.samplesPerPixel()
  if spp == 0:
    return true
  let last = spp - 1
  case p.kind
  of pkRgba8:
    for i in 0 ..< pixelCount:
      if p.rgba8[i * spp + last] != 255'u8: return false
    true
  of pkGrayA8:
    for i in 0 ..< pixelCount:
      if p.grayA8[i * spp + last] != 255'u8: return false
    true
  of pkCmyka8:
    for i in 0 ..< pixelCount:
      if p.cmyka8[i * spp + last] != 255'u8: return false
    true
  of pkRgba16:
    for i in 0 ..< pixelCount:
      if p.rgba16[i * spp + last] != 0xFFFF'u16: return false
    true
  of pkGrayA16:
    for i in 0 ..< pixelCount:
      if p.grayA16[i * spp + last] != 0xFFFF'u16: return false
    true
  of pkCmyka16:
    for i in 0 ..< pixelCount:
      if p.cmyka16[i * spp + last] != 0xFFFF'u16: return false
    true

proc checkPixels*(p: PixelData, width, height: int, mode: ColorMode,
    depth: int) =
  ## Raise unless `p` matches the document's mode and depth and holds exactly
  ## one sample per component per pixel.
  if p.colorMode().kind != mode.kind:
    invalid("pixel buffer is " & $p.colorMode().kind & " but the document is " &
      $mode.kind)
  if p.depth() != depth:
    invalid("pixel buffer is " & $p.depth() & "-bit but the document is " &
      $depth & "-bit")
  let expected = width * height * p.samplesPerPixel()
  if p.sampleCount() != expected:
    invalid("pixel buffer holds " & $p.sampleCount() & " samples, expected " &
      $expected & " for " & $width & "x" & $height)