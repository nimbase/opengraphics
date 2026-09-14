## Layer record decoder (`ldta`) plus footage helpers.
##
## ldta offsets from plans/aep-spec.md, validated against
## tests/data/01.aep (text layer 13 `Nim is awesome!`, cameras 2..8).
## Minimum length 152 (pre AE23); AE23 appends 4 bytes (matte layer id
## at 160) which is read when present. sspc and opti offsets validated
## the same way (sspc width at 32, height at 36).

import std/json
import ./types
import ./rifx
import ./reader

const LdtaMinLen* = 152

proc parseLdtaId*(data: openArray[byte]): uint32 =
  ## Layer id without a full decode (node lookup helper).
  if data.len < 4:
    raise newException(AepError, "truncated ldta id")
  readU32BEAt(data, 0, "ldta id")

proc parseLdta*(data: openArray[byte]): LayerInfo =
  if data.len < LdtaMinLen:
    raise newException(AepError,
      "truncated ldta (" & $data.len & " bytes, need " &
      $LdtaMinLen & ")")
  let id = readU32BEAt(data, 0, "ldta id")
  let stretchN = int(readU16BEAt(data, 10, "ldta stretch num"))
  let startT = int(readS16BEAt(data, 13, "ldta start"))
  let inR = int(readU16BEAt(data, 21, "ldta in"))
  let outR = int(readU16BEAt(data, 29, "ldta out"))
  let attr: array[3, byte] = [data[37], data[38], data[39]]
  let srcId = readU32BEAt(data, 40, "ldta source")
  let label = int(data[61])
  let name = readString0(data, 64, 32, "ldta name")
  let matte = int(data[107])
  let stretchD = int(readU16BEAt(data, 110, "ldta stretch den"))
  let kind = layerKindFromU8(data[131])
  let parent = readU32BEAt(data, 132, "ldta parent")
  var stretch = 1.0
  if stretchD != 0:
    stretch = float64(stretchN) / float64(stretchD)
  LayerInfo(id: id, name: name, kind: kind, sourceId: srcId,
    parentId: parent, labelColor: label, matteMode: matte,
    startTime: startT, inTime: inR, outTime: outR, stretch: stretch,
    isAdjustment: flagSet(attr, 1, 1), isNull: flagSet(attr, 1, 7),
    isGuide: flagSet(attr, 0, 1), isVisible: flagSet(attr, 2, 0),
    isLocked: flagSet(attr, 2, 5), isShy: flagSet(attr, 2, 6))

proc matteLayerId*(data: openArray[byte]): uint32 =
  ## AE23 matte layer id at 160, 0 when the chunk predates it.
  if data.len >= 164:
    return readU32BEAt(data, 160, "ldta matte layer")
  0

proc layerNodeName*(node: RifxChunk, fallback: string,
    limits: AepLimits): string =
  ## Prefer the Utf8 after ldta (renames update it, ldta bytes lag).
  for k in node.children:
    if k.id == "Utf8":
      var s = newString(k.data.len)
      for i, b in k.data:
        s[i] = char(b)
      if s.len > limits.maxNameBytes:
        s.setLen(limits.maxNameBytes)
      if s == "-_0_/-":
        return ""
      return s
  fallback

proc layersOfComp*(node: RifxChunk,
    limits = defaultAepLimits()): seq[LayerInfo] =
  ## Only LIST Layr entries. DLay/CLay/SLay/SecL are view layers and
  ## are not lottie content.
  result = @[]
  for layr in node.listByType("Layr"):
    if result.len >= limits.maxLayers:
      raise newException(AepError,
        "layer count exceeds limit " & $limits.maxLayers)
    let li = layr.findFirst("ldta")
    if li < 0:
      raise newException(AepError, "Layr without ldta")
    var info = parseLdta(layr.children[li].data)
    info.name = layerNodeName(layr, info.name, limits)
    result.add(info)

proc viewLayerCount*(node: RifxChunk): int =
  for k in node.children:
    if k.id == ListId and (k.listType == "DLay" or k.listType == "CLay" or
        k.listType == "SLay" or k.listType == "SecL"):
      inc result

proc parseSspc*(data: openArray[byte]): tuple[width, height: int] =
  ## sspc layout: width u16 @32, height u16 @36.
  if data.len < 38:
    return (0, 0)
  (int(readU16BEAt(data, 32, "sspc width")),
    int(readU16BEAt(data, 36, "sspc height")))

proc parseFootage*(id: uint32, name: string,
    node: RifxChunk): FootageInfo =
  var width, height = 0
  var assetType = ""
  var path = ""
  let pi = node.findFirst("Pin ")
  if pi >= 0:
    let pin = node.children[pi]
    let si = pin.findFirst("sspc")
    if si >= 0:
      (width, height) = parseSspc(pin.children[si].data)
    let oi = pin.findFirst("opti")
    if oi >= 0:
      let d = pin.children[oi].data
      if d.len >= 4:
        assetType = readFourCCAt(d, 0, "opti type")
    for als2 in pin.listByType("Als2"):
      let ai = als2.findFirst("alas")
      if ai >= 0:
        var s = newString(als2.children[ai].data.len)
        for i, b in als2.children[ai].data:
          s[i] = char(b)
        try:
          let j = parseJson(s)
          if j.hasKey("fullpath"):
            path = j["fullpath"].getStr()
        except JsonParsingError:
          discard
        break
  FootageInfo(id: id, name: name, width: width, height: height,
    assetType: assetType, filePath: path)
