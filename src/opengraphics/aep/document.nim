## High-level AEP document API (v1: project inventory).

import ./types
import ./rifx
import ./detect
import ./items
import ./comp
import ./layers
import ./props

export types
export props

type
  AepComp* = object
    info*: CompInfo
    layers*: seq[LayerInfo]
    viewLayers*: int ## DLay/CLay/SLay/SecL entries (not content)
    node*: RifxChunk ## comp Item node (lazy property decoding reads it)

  AepDocument* = object
    formType*: string
    exprLang*: string
    hasXmp*: bool
    comps*: seq[AepComp]
    footage*: seq[FootageInfo]
    itemCount*: int

proc compCount*(d: AepDocument): int {.inline.} = d.comps.len

proc readAepBytes*(data: openArray[byte],
    limits = defaultAepLimits()): AepDocument =
  let root = checkAep(data, limits)
  var detLang = ""
  for ex in rootListsByType(root, "ExEn"):
    for u in ex.childrenById("Utf8"):
      if u.data.len > 0:
        var s = newString(u.data.len)
        for i, b in u.data:
          s[i] = char(b)
        detLang = s
  let items = rootItems(root, limits)
  var doc = AepDocument(formType: root.formType, exprLang: detLang,
    hasXmp: root.xmpTail.len > 0, itemCount: items.len)
  for it in items:
    case it.kind
    of ItemComp:
      let info = compOfItem(it.id, it.name, it.node)
      doc.comps.add(AepComp(info: info,
        layers: layersOfComp(it.node, limits),
        viewLayers: viewLayerCount(it.node), node: it.node))
    of ItemFootage:
      doc.footage.add(parseFootage(it.id, it.name, it.node))
    else:
      discard
  doc

proc readAepBytes*(data: string,
    limits = defaultAepLimits()): AepDocument =
  var buf = newSeq[byte](data.len)
  for i, c in data:
    buf[i] = byte(c)
  readAepBytes(buf, limits)

proc openAep*(path: string,
    limits = defaultAepLimits()): AepDocument =
  readAepBytes(readFile(path), limits)

proc layerNode*(comp: AepComp, layerId: uint32): RifxChunk =
  ## Layr node for one layer (property decoding starts here).
  for layr in comp.node.listByType("Layr"):
    let li = layr.findFirst("ldta")
    if li >= 0 and parseLdtaId(layr.children[li].data) == layerId:
      return layr
  raise newException(AepError, "layer not found: " & $layerId)

proc layerProperties*(comp: AepComp, layerId: uint32,
    groupPath: openArray[string],
    limits = defaultAepLimits()): seq[PropInfo] =
  ## Static values of one nested group, eg ["ADBE Transform Group"].
  ## Decoded on demand so inventory stays cheap.
  let layr = layerNode(comp, layerId)
  let g = findGroup(layerGroups(layr), groupPath, limits)
  groupProperties(g, limits)

proc layerTransform*(comp: AepComp, layerId: uint32,
    limits = defaultAepLimits()): seq[PropInfo] =
  layerProperties(comp, layerId, ["ADBE Transform Group"], limits)
