## Legacy EPS-based `.ai` container reader.
##
## Pre-Illustrator-9 `.ai` files are Encapsulated PostScript: a `%!PS-Adobe`
## header, DSC comments, and a PostScript program. This module reads the
## container, not the program: bounding boxes, page count, the Illustrator
## format version marker, and an optional DOS EPS preview section.
## Interpreting the PostScript itself is explicitly out of scope and
## raises `AiError` through `readLegacyArtwork`, so callers can tell
## "understood the envelope" apart from "read the artwork".

import std/options
import std/strutils
import ../vector
import ./types

export vector

type
  EpsPreviewKind* = enum
    epkNone, epkTIFF, epkWMF

  LegacyEps* = object
    bbox*: VecRect ## preferred box: HiRes over regular
    hasBBox*: bool
    pages*: int    ## from %%Pages, 0 when absent
    aiFormatVersion*: int ## from %AI5_FileFormat, -1 when absent
    previewKind*: EpsPreviewKind
    previewBytes*: string ## raw preview section, empty when absent

proc epsFail(msg: string) {.noreturn.} =
  raise newException(AiError, "legacy EPS .ai: " & msg)

proc readU32LE(data: string, pos: int): uint32 =
  if pos < 0 or pos + 4 > data.len:
    epsFail("truncated binary header")
  uint32(ord(data[pos])) or (uint32(ord(data[pos+1])) shl 8) or
    (uint32(ord(data[pos+2])) shl 16) or (uint32(ord(data[pos+3])) shl 24)

proc boxOf(parts: seq[string]): tuple[ok: bool, r: VecRect] =
  if parts.len < 4: return (false, vecRect(0, 0, 0, 0))
  try:
    let nums = [parseFloat(parts[0]), parseFloat(parts[1]),
      parseFloat(parts[2]), parseFloat(parts[3])]
    for v in nums:
      if v != v or v == Inf or v == -Inf: return (false, vecRect(0,0,0,0))
    if nums[2] <= nums[0] or nums[3] <= nums[1]:
      return (false, vecRect(0, 0, 0, 0))
    (true, vecRect(nums[0], nums[1], nums[2], nums[3]))
  except ValueError:
    (false, vecRect(0, 0, 0, 0))

proc splitLines(data: string): seq[string] =
  ## DSC comments are line oriented; lone CR, LF, and CRLF all split.
  var cur = ""
  for c in data:
    if c == '\n' or c == '\r':
      result.add(cur)
      cur = ""
    else:
      cur.add(c)
  result.add(cur)

proc readLegacyEps*(data: string): LegacyEps =
  ## Parse the envelope of a legacy EPS-based `.ai` file. The PostScript
  ## program itself is never executed.
  if data.len < 2:
    epsFail("not a PostScript file (no %! header)")
  result = LegacyEps(aiFormatVersion: -1)
  var bbox: VecRect
  var hasBbox = false
  var hires: VecRect
  var hasHires = false
  var psStart = 0
  # A DOS EPS binary header relocates the PostScript section.
  if data.len >= 4 and data[0 .. 3] == "\xC5\xD0\xD3\xC6":
    if data.len < 30:
      epsFail("truncated DOS EPS binary header")
    psStart = int(readU32LE(data, 4))
    let psLen = int(readU32LE(data, 8))
    let wmfOff = int(readU32LE(data, 12))
    let wmfLen = int(readU32LE(data, 16))
    let tiffOff = int(readU32LE(data, 20))
    let tiffLen = int(readU32LE(data, 24))
    if psStart < 0 or psLen < 0 or psStart + psLen > data.len:
      epsFail("binary header points outside the file")
    if tiffLen > 0:
      if tiffOff < 0 or tiffOff + tiffLen > data.len:
        epsFail("TIFF preview points outside the file")
      result.previewKind = epkTIFF
      result.previewBytes = data[tiffOff ..< tiffOff + tiffLen]
    elif wmfLen > 0:
      if wmfOff < 0 or wmfOff + wmfLen > data.len:
        epsFail("WMF preview points outside the file")
      result.previewKind = epkWMF
      result.previewBytes = data[wmfOff ..< wmfOff + wmfLen]
  let ps = if psStart > 0: data[psStart .. ^1] else: data
  if ps.len < 2 or ps[0 .. 1] != "%!":
    epsFail("PostScript section has no %! header")
  for line in splitLines(ps):
    let t = line.strip()
    if t.startsWith("%%HiResBoundingBox:"):
      let v = t["%%HiResBoundingBox:".len .. ^1].strip()
      if v != "(atend)":
        let (ok, r) = boxOf(v.splitWhitespace())
        if ok:
          hires = r
          hasHires = true
    elif t.startsWith("%%BoundingBox:"):
      let v = t["%%BoundingBox:".len .. ^1].strip()
      if v != "(atend)":
        let (ok, r) = boxOf(v.splitWhitespace())
        if ok:
          bbox = r
          hasBbox = true
    elif t.startsWith("%%Pages:"):
      let parts = t["%%Pages:".len .. ^1].strip().splitWhitespace()
      if parts.len > 0:
        try: result.pages = parseInt(parts[0])
        except ValueError: discard
    elif t.startsWith("%AI5_FileFormat"):
      let v = t["%AI5_FileFormat".len .. ^1].strip()
      try: result.aiFormatVersion = parseInt(v.splitWhitespace()[0])
      except: discard
  # Note: the single linear scan already covers `(atend)` boxes,
  # which live in the trailer the scan walks through.
  if hasHires:
    result.bbox = hires
    result.hasBBox = true
  elif hasBbox:
    result.bbox = bbox
    result.hasBBox = true

proc legacyToVec*(leg: LegacyEps): VecDocument =
  ## The envelope as a vector document: one artboard from the bounding
  ## box, no artwork, and a warning saying why. Artwork needs the
  ## deferred PostScript interpreter.
  result = VecDocument()
  if not leg.hasBBox:
    raise newException(AiError,
      "legacy EPS .ai has no usable bounding box")
  result.artboards.add(VecArtboard(name: "", rect: leg.bbox))
  result.layers.add(VecLayer(name: "Layer 1", visible: true,
    locked: false))
  result.warn("legacy EPS artwork needs a PostScript interpreter; " &
    "only the envelope (bounding box, preview) was read")

proc readLegacyArtwork*(data: string): VecDocument =
  ## Refuse to interpret the program, loudly. Callers that only need
  ## the envelope use `readLegacyEps` plus `legacyToVec`.
  discard readLegacyEps(data)
  raise newException(AiError,
    "legacy EPS .ai programs are not interpreted; envelope only " &
    "(see readLegacyEps)")
