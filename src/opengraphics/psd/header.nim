## The 26-byte file header.
##
## Wire order, which is easy to get backwards:
##   signature "8BPS" (4) | version u16 | reserved[6] | channels u16 |
##   height u32 | width u32 | depth u16 | color mode u16
##
## Note **height precedes width**.
##
## `Version` is the only switch between PSD and PSB. PSB changes exactly three
## kinds of length to 64-bit: the layer-and-mask section, the layer info, and
## per-layer per-channel data, plus the 13 tagged-block keys in `PSB_LONG_KEYS`
## (see `tagged`) and u32 RLE row counts (see `compression`). Everything else
## stays 32-bit even in a PSB file, including color mode data and the image
## resource section.

import ./error
import ./io

type
  Version* {.pure.} = enum
    ## PSD (1) is the classic format; PSB (2) is the "large document format"
    ## that widens selected lengths to 64 bits.
    Psd = 1
    Psb = 2

  ColorModeKind* {.pure.} = enum
    cmBitmap, cmGrayscale, cmIndexed, cmRgb, cmCmyk, cmMultichannel,
    cmDuotone, cmLab, cmUnknown

  ColorMode* = object
    ## `Unknown` keeps the raw code so a file using a mode we do not model
    ## still round-trips byte for byte instead of being rejected.
    case kind*: ColorModeKind
    of cmBitmap: discard
    of cmGrayscale: discard
    of cmIndexed: discard
    of cmRgb: discard
    of cmCmyk: discard
    of cmMultichannel: discard
    of cmDuotone: discard
    of cmLab: discard
    of cmUnknown: raw*: uint16

  Header* = object
    version*: Version
    reserved*: array[6, byte]  ## preserved verbatim, not zeroed on parse
    channels*: int              ## 1..56, merged-image count including alpha
    height*: int
    width*: int
    depth*: int                 ## 1, 8, 16 or 32
    colorMode*: ColorMode

const
  PsdSignature* = "8BPS"
  MaxDimension* = 300_000
  MaxChannels* = 56

proc isPsb*(v: Version): bool {.inline.} = v == Version.Psb

## The enum values are the wire codes (1 = PSD, 2 = PSB).
proc toU16*(v: Version): uint16 {.inline.} = uint16(ord(v))

proc fromU16*(raw: uint16): Version =
  ## 1 is PSD, 2 is PSB. Anything else is rejected by `readHeader`.
  if raw == 2'u16: Version.Psb else: Version.Psd

proc colorModeFromU16*(v: uint16): ColorMode =
  case v
  of 0'u16: ColorMode(kind: cmBitmap)
  of 1'u16: ColorMode(kind: cmGrayscale)
  of 2'u16: ColorMode(kind: cmIndexed)
  of 3'u16: ColorMode(kind: cmRgb)
  of 4'u16: ColorMode(kind: cmCmyk)
  of 7'u16: ColorMode(kind: cmMultichannel)
  of 8'u16: ColorMode(kind: cmDuotone)
  of 9'u16: ColorMode(kind: cmLab)
  else: ColorMode(kind: cmUnknown, raw: v)

proc toU16*(m: ColorMode): uint16 {.inline.} =
  case m.kind
  of cmBitmap: 0'u16
  of cmGrayscale: 1'u16
  of cmIndexed: 2'u16
  of cmRgb: 3'u16
  of cmCmyk: 4'u16
  of cmMultichannel: 7'u16
  of cmDuotone: 8'u16
  of cmLab: 9'u16
  of cmUnknown: m.raw

proc colorChannelCount*(m: ColorMode): int =
  ## Colour planes this mode stores, excluding any alpha. Multichannel and
  ## unknown modes carry no defined mapping, so they report 0.
  case m.kind
  of cmBitmap, cmGrayscale, cmIndexed, cmDuotone: 1
  of cmRgb, cmLab: 3
  of cmCmyk: 4
  of cmMultichannel, cmUnknown: 0

proc isRgb*(m: ColorMode): bool {.inline.} = m.kind == cmRgb
proc isGray*(m: ColorMode): bool {.inline.} =
  m.kind == cmGrayscale or m.kind == cmBitmap or m.kind == cmDuotone
proc isIndexed*(m: ColorMode): bool {.inline.} = m.kind == cmIndexed

proc rowBytes*(width, depth: int): int {.inline.} =
  ## Bytes one scanline of `width` pixels occupies at `depth` bits. Depth 1
  ## packs eight pixels per byte; every other depth rounds up to whole bytes.
  if depth == 1:
    (width + 7) div 8
  else:
    width * max(depth div 8, 1)

proc rowBytes*(h: Header, width: int = -1): int {.inline.} =
  ## `width` defaults to the header width.
  rowBytes(if width < 0: h.width else: width, h.depth)

proc readHeader*(r: var Reader): Header =
  ## Parse and validate the 26-byte header. Raises `PsdError` with
  ## `InvalidSignature`, `UnsupportedVersion` or `Invalid` on bad input.
  let startPos = r.pos
  let sig = r.readStr4()
  if sig != PsdSignature:
    badSignature(PsdSignature, sig, startPos)
  let versionRaw = r.readU16BE()
  if versionRaw != 1'u16 and versionRaw != 2'u16:
    newPsdError(PsdErrorKind.UnsupportedVersion,
      "unsupported file version " & $versionRaw, startPos)
  let version = fromU16(versionRaw)
  result.version = version
  for i in 0 ..< 6:
    result.reserved[i] = r.readU8()
  result.channels = int(r.readU16BE())
  result.height = int(r.readU32BE())
  result.width = int(r.readU32BE())
  result.depth = int(r.readU16BE())
  result.colorMode = colorModeFromU16(r.readU16BE())

  if result.channels < 1 or result.channels > MaxChannels:
    invalid("channel count " & $result.channels & " out of range 1.." &
      $MaxChannels)
  if result.width > MaxDimension or result.height > MaxDimension:
    limitExceeded("image dimensions exceed " & $MaxDimension)
  if result.depth notin [1, 8, 16, 32]:
    invalid("unsupported bit depth " & $result.depth)

proc writeHeader*(w: var Writer, h: Header) =
  ## Inverse of `readHeader`. Preserves the six reserved bytes as read.
  w.putStr4(PsdSignature)
  w.putU16(h.version.toU16)
  w.putBytes(h.reserved)
  w.putU16(uint16(h.channels))
  w.putU32(uint32(h.height))
  w.putU32(uint32(h.width))
  w.putU16(uint16(h.depth))
  w.putU16(h.colorMode.toU16)

proc validate*(h: Header, colorModeDataLen: int = 0) =
  ## Extra model-level checks that need more than the header itself.
  ## Enforces the spec's 30 000-pixel ceiling for PSD (PSB may go wider) and
  ## requires an Indexed document to carry its 768-byte palette.
  if h.version == Version.Psd and
      (h.width > 30_000 or h.height > 30_000):
    limitExceeded("PSD dimensions exceed 30000; use PSB")
  if h.colorMode.isIndexed() and colorModeDataLen != 768:
    invalid("Indexed documents need a 768-byte palette, got " &
      $colorModeDataLen)
