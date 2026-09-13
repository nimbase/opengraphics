## 26-byte file header.

import ./types
import ./reader

type
  Header* = object
    channels*: int
    height*: int
    width*: int
    depth*: int
    colorMode*: ColorMode

const
  PsdSignature* = "8BPS"
  PsdVersion* = 1

proc parseHeader*(r: var BinReader): Header =
  let sig = r.readStr(4)
  if sig != PsdSignature:
    raise newException(PsdError, "bad PSD signature: " & $sig)
  let version = r.readU16BE()
  if version != PsdVersion:
    raise newException(PsdError,
      "unsupported PSD version " & $version & " (want 1; PSB version 2 is out of scope for v1)")
  r.skip(6) # reserved, must be zero
  let channels = int(r.readU16BE())
  let height = int(r.readU32BE())
  let width = int(r.readU32BE())
  let depth = int(r.readU16BE())
  let modeRaw = r.readU16BE()
  let mode = colorModeFromU16(modeRaw)
  if channels < 1 or channels > 56:
    raise newException(PsdError, "invalid channel count " & $channels)
  if height < 1 or height > 30000 or width < 1 or width > 30000:
    raise newException(PsdError, "invalid dimensions " & $width & "x" & $height)
  if depth notin [1, 8, 16, 32]:
    raise newException(PsdError, "unsupported depth " & $depth)
  result = Header(channels: channels, height: height, width: width,
    depth: depth, colorMode: mode)
