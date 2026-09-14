## Folder item walk: Fold -> Item -> idta / Utf8 / cmta / Sfdr.
##
## Routes items by idta type (1 folder, 4 comp, 7 footage). Names come
## from the Utf8 following idta (`-_0_/-` means empty). The node is kept
## so comp.nim, layers.nim and footage parsers can read detail later.

import ./types
import ./rifx
import ./reader

const EmptyNameMarker* = "-_0_/-"

type
  ItemInfo* = object
    kind*: ItemKind
    id*: uint32
    name*: string
    comment*: string
    labelColor*: int
    node*: RifxChunk ## the LIST Item node (detail parsers read from this)

proc cleanName*(s: string): string =
  if s == EmptyNameMarker: "" else: s

proc utf8Text*(c: RifxChunk, limits: AepLimits): string =
  result = newString(c.data.len)
  for i, b in c.data:
    result[i] = char(b)
  if result.len > limits.maxNameBytes:
    result.setLen(limits.maxNameBytes)

proc parseIdta*(data: openArray[byte]): tuple[kind: ItemKind, id: uint32,
    label: int] =
  ## idta layout: type u16 @0, id u32 @16, label u8 @58. Longer chunks
  ## are tolerated (trailing bytes ignored).
  if data.len < 59:
    raise newException(AepError,
      "truncated idta (" & $data.len & " bytes, need 59)")
  let t = readU16BEAt(data, 0, "idta type")
  let id = readU32BEAt(data, 16, "idta id")
  (itemKindFromU16(t), id, int(data[58]))

proc parseItemNode*(node: RifxChunk,
    limits = defaultAepLimits()): ItemInfo =
  let di = node.findFirst("idta")
  if di < 0:
    raise newException(AepError, "Item without idta")
  let (kind, id, label) = parseIdta(node.children[di].data)
  var name = ""
  var comment = ""
  var seenName = false
  for k in node.children:
    if k.id == "Utf8" and not seenName:
      name = cleanName(utf8Text(k, limits))
      seenName = true
    elif k.id == "cmta" and comment.len == 0:
      comment = readString0(k.data, 0, min(k.data.len,
        limits.maxNameBytes), "cmta")
  ItemInfo(kind: kind, id: id, name: name, comment: comment,
    labelColor: label, node: node)

proc collectItems*(parent: RifxChunk, limits: AepLimits,
    acc: var seq[ItemInfo]) =
  ## Direct LIST Item children of parent (Sfdr or Fold level).
  for k in parent.children:
    if k.id == ListId and k.listType == "Item":
      if acc.len >= limits.maxItems:
        raise newException(AepError,
          "item count exceeds limit " & $limits.maxItems)
      let item = parseItemNode(k, limits)
      acc.add(item)
      if item.kind == ItemFolder:
        for sub in k.listByType("Sfdr"):
          collectItems(sub, limits, acc)

proc rootItems*(root: RifxRoot,
    limits = defaultAepLimits()): seq[ItemInfo] =
  ## All items under the top level LIST Fold, folders recursed.
  result = @[]
  let folds = rootListsByType(root, "Fold")
  if folds.len == 0:
    raise newException(AepError, "AEP project without LIST Fold")
  collectItems(folds[0], limits, result)
