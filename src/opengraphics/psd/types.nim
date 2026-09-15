## Shared types and errors for the PSD reader.
##
## v1 scope: PSD only (not PSB), 8-bit RGB/Grayscale, Raw + RLE + ZIP.
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

  Limits* = object
    ## Caps applied before allocating pixel buffers, so malicious or
    ## corrupt headers cannot force huge allocations. Checked up front
    ## in readPsdBytes / parseLayerInfo; violations raise PsdError.
    ## Tighten these when reading user-supplied files, e.g.
    ## Limits(maxWidth: 10000, maxHeight: 10000, maxPixels: 100_000_000,
    ##   maxLayers: 100).
    maxWidth*: int
    maxHeight*: int
    maxPixels*: int ## width*height cap per image (document, composite, layer)
    maxLayers*: int

proc defaultLimits*(): Limits =
  ## Spec-maximum dimensions with a pixel and layer-count safety net.
  Limits(maxWidth: 30000, maxHeight: 30000, maxPixels: 100_000_000,
    maxLayers: 1000)

proc checkDimensions*(limits: Limits, w, h: int, what: string) =
  ## Reject implausible sizes before any buffer is allocated.
  if w <= 0 or h <= 0:
    raise newException(PsdError, "invalid " & what & " dimensions " &
      $w & "x" & $h)
  if w > limits.maxWidth or h > limits.maxHeight:
    raise newException(PsdError, what & " dimensions " & $w & "x" & $h &
      " exceed limit " & $limits.maxWidth & "x" & $limits.maxHeight)
  if int64(w) * int64(h) > int64(limits.maxPixels):
    raise newException(PsdError, what & " size " & $w & "x" & $h &
      " exceeds pixel limit " & $limits.maxPixels)

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
