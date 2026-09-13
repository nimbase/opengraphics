## Image Resources section: generic 8BIM block preservation
## plus selective decoding of resolution, thumbnail, and ICC profile.

import std/options
import ./types
import ./reader

type
  ResourceBlock* = object
    id*: uint16
    name*: string
    data*: seq[byte]

  ImageResources* = object
    blocks*: seq[ResourceBlock]

  ResolutionInfo* = object
    hRes*: int32
    hResUnit*: int16
    widthUnit*: int16
    vRes*: int32
    vResUnit*: int16
    heightUnit*: int16

  Thumbnail* = object
    ## Decoded thumbnail resource (ID 1036 RGB, or 1033 BGR).
    ## `jpeg` holds the raw JFIF bytes after the 28-byte header.
    ## v1 does not decode JPEG (stdlib only); consumers can save
    ## `jpeg` to a .jpg file directly.
    format*: uint32 # 1 = kJpegRGB
    width*, height*: int
    bitsPerPixel*: uint16
    planes*: uint16
    jpeg*: seq[byte]

proc parseResources*(r: var BinReader): ImageResources =
  let total = int(r.readU32BE())
  let sectionEnd = r.pos + total
  if total == 0:
    return ImageResources(blocks: @[])
  if sectionEnd > r.data.len:
    raise newException(PsdError, "truncated image resources section")
  var blocks: seq[ResourceBlock] = @[]
  while r.pos < sectionEnd:
    let sig = r.readStr(4)
    if sig != "8BIM" and sig != "8B64":
      raise newException(PsdError, "bad resource signature at " & $(r.pos - 4))
    let id = r.readU16BE()
    let name = r.readPascalStringEvenPadded()
    let size = int(r.readU32BE())
    let data = r.readBytes(size)
    if size mod 2 != 0:
      r.skip(1) # pad to even
    blocks.add(ResourceBlock(id: id, name: name, data: data))
  if r.pos != sectionEnd:
    raise newException(PsdError, "image resources length mismatch")
  result = ImageResources(blocks: blocks)

proc findResource*(res: ImageResources, id: uint16): int =
  for i, b in res.blocks:
    if b.id == id:
      return i
  return -1

proc parseResolution*(data: seq[byte]): ResolutionInfo =
  ## Resource ID 1005, 16 bytes.
  if data.len < 16:
    raise newException(PsdError, "short resolution info")
  var r = initReader(data)
  result = ResolutionInfo(
    hRes: r.readI32BE(),
    hResUnit: r.readI16BE(),
    widthUnit: r.readI16BE(),
    vRes: r.readI32BE(),
    vResUnit: r.readI16BE(),
    heightUnit: r.readI16BE(),
  )

const
  ThumbnailBgrId* = 1033'u16 ## Photoshop 4.0 BGR thumbnail
  ThumbnailRgbId* = 1036'u16 ## Photoshop 5.0+ RGB thumbnail
  IccProfileId* = 1039'u16
  IccUntaggedId* = 1040'u16

proc parseThumbnail*(data: seq[byte]): Thumbnail =
  ## Parse the 28-byte thumbnail header plus JFIF payload.
  if data.len < 28:
    raise newException(PsdError, "short thumbnail resource")
  var r = initReader(data)
  let format = r.readU32BE()
  let width = int(r.readU32BE())
  let height = int(r.readU32BE())
  discard r.readU32BE() # widthBytes (padded row size)
  discard r.readU32BE() # totalSize (uncompressed)
  let compSize = int(r.readU32BE())
  let bpp = r.readU16BE()
  let planes = r.readU16BE()
  let jpeg = r.readBytes(r.remaining())
  if jpeg.len != compSize:
    raise newException(PsdError, "thumbnail size mismatch")
  if width <= 0 or height <= 0 or width > 4096 or height > 4096:
    raise newException(PsdError, "implausible thumbnail dimensions")
  result = Thumbnail(format: format, width: width, height: height,
    bitsPerPixel: bpp, planes: planes, jpeg: jpeg)

proc getThumbnail*(res: ImageResources): Option[Thumbnail] =
  ## First RGB (1036) thumbnail, falling back to BGR (1033).
  ## Returns none when the file carries no thumbnail or its payload
  ## was skipped via ReadOptions.skipThumbnail.
  var idx = res.findResource(ThumbnailRgbId)
  if idx < 0:
    idx = res.findResource(ThumbnailBgrId)
  if idx < 0:
    return none(Thumbnail)
  if res.blocks[idx].data.len == 0:
    return none(Thumbnail)
  some(parseThumbnail(res.blocks[idx].data))

proc hasThumbnail*(res: ImageResources): bool =
  ## True when a usable thumbnail payload is present (1036 RGB,
  ## else 1033 BGR). False when absent or skipped via
  ## ReadOptions.skipThumbnail (payload cleared at read time).
  getThumbnail(res).isSome

proc saveThumbnailJpeg*(t: Thumbnail, path: string) =
  ## Write the embedded JFIF payload verbatim to a .jpg file.
  ## Opens in macOS Preview with no decoding step. Raises PsdError
  ## when the payload is empty.
  if t.jpeg.len == 0:
    raise newException(PsdError, "cannot write thumbnail: empty JPEG payload")
  var f = open(path, fmWrite)
  defer: close(f)
  var payload = t.jpeg
  discard f.writeBuffer(addr payload[0], payload.len)

proc saveThumbnailJpeg*(res: ImageResources, path: string) =
  ## Convenience overload: uses the file's own thumbnail (same
  ## 1036-then-1033 preference as getThumbnail). Raises PsdError
  ## when the file carries no thumbnail.
  let t = res.getThumbnail()
  if t.isNone:
    raise newException(PsdError, "cannot write thumbnail: file has none")
  saveThumbnailJpeg(t.get, path)

proc iccProfile*(res: ImageResources): seq[byte] =
  ## Raw ICC profile bytes (ID 1039, else 1040), or empty if absent.
  ## The first 4 bytes (big-endian) give the profile size and
  ## should equal result.len for a well-formed profile.
  var idx = res.findResource(IccProfileId)
  if idx < 0:
    idx = res.findResource(IccUntaggedId)
  if idx < 0:
    return @[]
  res.blocks[idx].data

proc hasIccProfile*(res: ImageResources): bool {.inline.} =
  res.findResource(IccProfileId) >= 0 or res.findResource(IccUntaggedId) >= 0
