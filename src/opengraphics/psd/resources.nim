## Image resources: the key/value blocks between the color mode data and the
## layer and mask section.
##
## Each block is `signature`, a u16 id, a Pascal name padded to 2, a u32
## length, that many bytes, then one pad byte when the length was odd. The
## signature is normally `8BIM`, but four legacy alternatives are accepted
## (`MeSa`, `AgHg`, `PHUT`, `DCSR`) and preserved.
##
## The section length and every resource length stay 32-bit even in PSB.
##
## Most ids are preserved raw. The ones this module types are listed in
## `ResourceData`; `parsed` returns `none` for any other id (1025 work path,
## 1050 slices, 2000-2997 saved paths, 2999 print flags) so the caller can
## read them itself.

import std/options

import ./error
import ./io

export span

type
  ImageResource* = object
    signature*: string ## "8BIM", "MeSa", "AgHg", "PHUT" or "DCSR"
    id*: int
    name*: string  ## Pascal name, usually empty
    data*: Span   ## exactly the bytes the length field covered, as a window

  ResolutionInfo* = object
    ## Resource 1005. Resolutions are 16.16 fixed point.
    hResFixed*: uint32
    hResUnit*: uint16 ## 1 pixels per inch, 2 pixels per cm
    widthUnit*: uint16 ## 1 in, 2 cm, 3 pt, 4 pica, 5 column
    vResFixed*: uint32
    vResUnit*: uint16
    heightUnit*: uint16

  VersionInfo* = object
    ## Resource 1057. `hasRealMergedData` false means the stored merged image
    ## is only a placeholder.
    version*: uint32
    hasRealMergedData*: bool
    writer*: string
    reader*: string
    fileVersion*: uint32

  ResourceDataKind* {.pure.} = enum
    rdResolutionInfo, rdLayerState, rdLayerGroupInfo, rdThumbnailPs4,
    rdThumbnail, rdGlobalAngle, rdIccProfile, rdGlobalAltitude,
    rdVersionInfo, rdExif, rdXmp, rdSlices

  ResourceData* = object
    case kind*: ResourceDataKind
    of rdResolutionInfo: resolution*: ResolutionInfo
    of rdLayerState: layerState*: uint16
    of rdLayerGroupInfo: groupIds*: seq[uint16]
    of rdThumbnailPs4, rdThumbnail: thumbnail*: Span
      ## raw: a 28-byte header plus a JFIF (1036) or BGR (1033) payload
    of rdGlobalAngle: angle*: int32
    of rdIccProfile, rdExif, rdXmp: raw*: Span
    of rdGlobalAltitude: altitude*: int32
    of rdVersionInfo: versionInfo*: VersionInfo
    of rdSlices: slices*: string ## parsed by `slices.nim`

const
  ResolutionInfoId* = 1005
  LayerStateId* = 1024
  LayerGroupInfoId* = 1026
  ThumbnailPs4Id* = 1033 ## Photoshop 4.0, BGR
  ThumbnailId* = 1036    ## Photoshop 5.0+, JFIF
  GlobalAngleId* = 1037
  IccProfileId* = 1039
  IccUntaggedId* = 1040 ## accepted as a fallback for 1039
  GlobalAltitudeId* = 1049
  SlicesId* = 1050
  VersionInfoId* = 1057
  ExifId* = 1058
  XmpId* = 1060
  ## Saved paths live at 2000-2997; the work path is 1025.
  PathFirstId* = 2000
  PathLastId* = 2997

  KnownSignatures* = ["8BIM", "MeSa", "AgHg", "PHUT", "DCSR"]

proc isResourceSignature*(s: string): bool {.inline.} =
  s in KnownSignatures

proc newImageResource*(id: int, data: string): ImageResource {.inline.} =
  ## A resource over synthesised bytes; parsed ones keep a window into the file.
  ImageResource(signature: "8BIM", id: id, name: "",
    data: Span(src: newStringSource(data), start: 0, stop: data.len))

proc newImageResource*(id: int, data: Span): ImageResource {.inline.} =
  ImageResource(signature: "8BIM", id: id, name: "", data: data)

proc hRes*(r: ResolutionInfo): float64 {.inline.} =
  float64(r.hResFixed) / 65536.0

proc vRes*(r: ResolutionInfo): float64 {.inline.} =
  float64(r.vResFixed) / 65536.0

proc resolutionFromDpi*(dpi: float64): ResolutionInfo =
  ## All units set to 1 (per inch) with the value in 16.16 fixed point.
  let clamped = min(max(dpi * 65536.0, 0.0), float64(high(uint32)))
  let fixed = uint32(clamped)
  ResolutionInfo(hResFixed: fixed, hResUnit: 1, widthUnit: 1,
    vResFixed: fixed, vResUnit: 1, heightUnit: 1)

proc readResolution*(data: Span): ResolutionInfo =
  if data.len < 16:
    invalid("resolution info needs 16 bytes, got " & $data.len)
  var r = initReader(data)
  result.hResFixed = r.readU32BE()
  result.hResUnit = r.readU16BE()
  result.widthUnit = r.readU16BE()
  result.vResFixed = r.readU32BE()
  result.vResUnit = r.readU16BE()
  result.heightUnit = r.readU16BE()

proc writeResolution*(w: var Writer, r: ResolutionInfo) =
  w.putU32(r.hResFixed)
  w.putU16(r.hResUnit)
  w.putU16(r.widthUnit)
  w.putU32(r.vResFixed)
  w.putU16(r.vResUnit)
  w.putU16(r.heightUnit)

proc readVersionInfo*(data: Span): VersionInfo =
  if data.len < 5:
    invalid("version info is too short (" & $data.len & " bytes)")
  var r = initReader(data)
  result.version = r.readU32BE()
  result.hasRealMergedData = r.readU8() != 0
  result.writer = unicodeToString(r.readUnicodeUnits())
  result.reader = unicodeToString(r.readUnicodeUnits())
  if r.remaining() >= 4:
    result.fileVersion = r.readU32BE()

proc writeVersionInfo*(w: var Writer, v: VersionInfo) =
  w.putU32(v.version)
  w.putU8(if v.hasRealMergedData: 1'u8 else: 0'u8)
  w.writeUnicode(v.writer)
  w.writeUnicode(v.reader)
  w.putU32(v.fileVersion)

proc writeVersionInfoResource*(w: var Writer, hasRealMergedData: bool) =
  w.writeVersionInfo(VersionInfo(version: 1,
    hasRealMergedData: hasRealMergedData,
    writer: "Adobe Photoshop", reader: "Adobe Photoshop CS6",
    fileVersion: 1))

proc versionInfoResource*(hasRealMergedData: bool): ImageResource =
  ## The 1057 block Photoshop writes, used to flag a placeholder composite.
  var w = initWriter()
  w.writeVersionInfoResource(hasRealMergedData)
  newImageResource(VersionInfoId, w.toString())


proc parsed*(res: ImageResource): Option[ResourceData] =
  ## Typed view for the ids this module models; `none` for everything else.
  var r = initReader(res.data)
  try:
    case res.id
    of ResolutionInfoId:
      if res.data.len < 16:
        return none(ResourceData)
      some(ResourceData(kind: rdResolutionInfo, resolution: readResolution(res.data)))
    of LayerStateId:
      if res.data.len < 2:
        return none(ResourceData)
      some(ResourceData(kind: rdLayerState, layerState: r.readU16BE()))
    of LayerGroupInfoId:
      if res.data.len mod 2 != 0:
        return none(ResourceData)
      var ids: seq[uint16] = @[]
      while r.remaining() >= 2:
        ids.add(r.readU16BE())
      some(ResourceData(kind: rdLayerGroupInfo, groupIds: ids))
    of ThumbnailPs4Id:
      some(ResourceData(kind: rdThumbnailPs4, thumbnail: res.data))
    of ThumbnailId:
      some(ResourceData(kind: rdThumbnail, thumbnail: res.data))
    of GlobalAngleId:
      if res.data.len < 4:
        return none(ResourceData)
      some(ResourceData(kind: rdGlobalAngle, angle: r.readI32BE()))
    of IccProfileId:
      some(ResourceData(kind: rdIccProfile, raw: res.data))
    of GlobalAltitudeId:
      if res.data.len < 4:
        return none(ResourceData)
      some(ResourceData(kind: rdGlobalAltitude, altitude: r.readI32BE()))
    of VersionInfoId:
      if res.data.len < 5:
        return none(ResourceData)
      some(ResourceData(kind: rdVersionInfo,
        versionInfo: readVersionInfo(res.data)))
    of ExifId:
      some(ResourceData(kind: rdExif, raw: res.data))
    of XmpId:
      some(ResourceData(kind: rdXmp, raw: res.data))
    else:
      none(ResourceData)
  except PsdError:
    none(ResourceData)

proc xmpText*(res: ImageResource): Option[string] =
  ## Resource 1060 as UTF-8 text, when it is valid UTF-8. One copy, made here
  ## rather than at parse time, because most callers never ask for it.
  if res.id != XmpId:
    return none(string)
  let text = res.data.clone
  if not isValidUtf8(text):
    return none(string)
  some(text)

proc readResource*(r: var Reader): ImageResource =
  ## One block. Raises `InvalidSignature` for an unknown signature and
  ## `UnexpectedEof` when the declared length overruns the section.
  let sigPos = r.pos
  let sig = r.readStr4()
  if not isResourceSignature(sig):
    badSignature("8BIM", sig, sigPos)
  result.signature = sig
  result.id = int(r.readU16BE())
  result.name = r.readPascal(2)
  let n = int64(r.readU32BE())
  if n > r.remaining:
    eof(int(n - r.remaining), r.pos)
  result.data = r.bytes(int(n))
  if (n and 1) != 0:
    r.skip(1) # pad to an even byte count

proc writeResource*(w: var Writer, res: ImageResource) =
  ## Inverse of `readResource`. The pad byte is always zero; see the plan's
  ## byte-exactness caveats.
  w.putStr4(res.signature)
  w.putU16(uint16(res.id))
  w.writePascal(res.name, 2)
  w.putU32(uint32(res.data.len))
  w.put(res.data)
  if (res.data.len and 1) != 0:
    w.putU8(0)

proc readResourceSection*(r: var Reader,
    limits = defaultLimits()): seq[ImageResource] =
  ## The whole section: a u32 length, then blocks to the end. The length
  ## field is mandatory, so a file that stops before it is truncated.
  ##
  ## The block count is capped by `limits.maxBlocks`. Each block costs at least
  ## 12 bytes, so without this a long section could expand into millions of
  ## empty records.
  result = @[]
  let n = r.lenField(false)
  if n == 0:
    return
  if n > r.remaining:
    eof(int(n - r.remaining), r.pos)
  var body = r.sub(n)
  while body.remaining() >= 8:
    if result.len >= limits.maxBlocks:
      limitExceeded("image resource count " & $result.len & " reaches limit " &
        $limits.maxBlocks)
    result.add(readResource(body))

proc writeResourceSection*(w: var Writer,
    resources: openArray[ImageResource]) =
  ## Inverse of `readResourceSection`. Always a 32-bit length, even in PSB.
  let at = w.beginLen(false)
  for res in resources:
    writeResource(w, res)
  w.endLen(at, false)

proc findResource*(resources: openArray[ImageResource], id: int): int =
  ## Index of the first resource with `id`, or -1.
  for i, res in resources:
    if res.id == id:
      return i
  -1

proc getResource*(resources: openArray[ImageResource],
    id: int): Option[ImageResource] =
  let i = findResource(resources, id)
  if i < 0: none(ImageResource) else: some(resources[i])

proc iccProfile*(resources: openArray[ImageResource]): string =
  ## Raw ICC bytes (1039, else 1040), or "" when absent.
  var i = findResource(resources, IccProfileId)
  if i < 0:
    i = findResource(resources, IccUntaggedId)
  if i < 0:
    return ""
  resources[i].data.clone

proc resolution*(resources: openArray[ImageResource]): Option[ResolutionInfo] =
  let res = getResource(resources, ResolutionInfoId)
  if res.isNone:
    return none(ResolutionInfo)
  try:
    some(readResolution(res.get().data))
  except PsdError:
    none(ResolutionInfo)

proc versionInfo*(resources: openArray[ImageResource]): Option[VersionInfo] =
  let res = getResource(resources, VersionInfoId)
  if res.isNone:
    return none(VersionInfo)
  try:
    some(readVersionInfo(res.get().data))
  except PsdError:
    none(VersionInfo)

proc hasRealMergedData*(resources: openArray[ImageResource]): bool =
  ## Whether the stored merged image is real rather than a placeholder.
  ## Absent 1057 means true: only the flag marks a placeholder.
  let v = versionInfo(resources)
  if v.isNone:
    return true
  v.get().hasRealMergedData

proc isPathResource*(id: int): bool {.inline.} =
  ## Saved-path resources occupy 2000 through 2997.
  id >= PathFirstId and id <= PathLastId

proc readResolution*(data: string): ResolutionInfo =
  readResolution(toSpan(data))

proc readVersionInfo*(data: string): VersionInfo =
  readVersionInfo(toSpan(data))
