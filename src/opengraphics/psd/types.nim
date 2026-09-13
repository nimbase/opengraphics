## Shared types and errors for the PSD reader.
##
## v1 scope: PSD only (not PSB), 8-bit RGB/Grayscale, Raw + RLE.
## Unknown sections are preserved as raw bytes so a future writer
## can round-trip them.

type
  PsdError* = object of CatchableError

  ColorMode* {.pure.} = enum
    Bitmap = 0
    Grayscale = 1
    Indexed = 2
    Rgb = 3
    Cmyk = 4
    Multichannel = 7
    Duotone = 8
    Lab = 9
    Unknown = -1

  Compression* {.pure.} = enum
    Raw = 0
    Rle = 1
    ZipNoPrediction = 2
    ZipPrediction = 3
    Unknown = -1

  ReadOptions* = object
    ## Toggles to skip expensive or unneeded sections.
    skipLayerImageData*: bool
    skipCompositeImageData*: bool
    skipThumbnail*: bool

proc colorModeFromU16*(v: uint16): ColorMode =
  case v
  of 0: Bitmap
  of 1: Grayscale
  of 2: Indexed
  of 3: Rgb
  of 4: Cmyk
  of 7: Multichannel
  of 8: Duotone
  of 9: Lab
  else: Unknown

proc compressionFromU16*(v: uint16): Compression =
  case v
  of 0: Raw
  of 1: Rle
  of 2: ZipNoPrediction
  of 3: ZipPrediction
  else: Unknown
