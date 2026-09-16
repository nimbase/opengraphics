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
    ##   maxLayers: 100, maxSectionBytes: 64_000_000, maxBlocks: 1000).
    maxWidth*: int
    maxHeight*: int
    maxPixels*: int ## width*height cap per image (document, composite, layer)
    maxLayers*: int
    maxSectionBytes*: int ## cap per length-prefixed section or block
    ## (color-mode data, resources, layer/mask section, layer extra,
    ## tagged blocks, composite remainder)
    maxBlocks*: int ## cap on resource/tagged-block counts per section

proc defaultLimits*(): Limits =
  ## Spec-maximum dimensions with a pixel and layer-count safety net.
  Limits(maxWidth: 30000, maxHeight: 30000, maxPixels: 100_000_000,
    maxLayers: 1000, maxSectionBytes: 512_000_000, maxBlocks: 10_000)

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

proc checkSection*(limits: Limits, n: int, what: string) =
  ## Reject oversized length-prefixed sections/blocks before the
  ## payload is read. `n` comes straight off the wire, so the check
  ## runs before any allocation or skip.
  if n < 0:
    raise newException(PsdError, "invalid " & what & " length " & $n)
  if n > limits.maxSectionBytes:
    raise newException(PsdError, what & " length " & $n &
      " exceeds section limit " & $limits.maxSectionBytes)

proc checkSamples*(limits: Limits, w, h, channels: int, what: string) =
  ## Channel-aware volume cap: decoded bytes are w*h per channel, so
  ## a file claiming 56 channels must not slip past the pixel cap.
  if w <= 0 or h <= 0 or channels <= 0:
    return
  if int64(w) * int64(h) * int64(channels) > int64(limits.maxPixels):
    raise newException(PsdError, what & " volume " & $w & "x" & $h &
      "x" & $channels & "ch exceeds pixel limit " & $limits.maxPixels)

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
