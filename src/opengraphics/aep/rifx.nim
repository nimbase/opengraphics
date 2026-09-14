## Internal spec-compliant RIFX container reader.
##
## Parses `RIFX` (big endian) with form `Egg!` into an owned chunk tree.
## Rules: FourCC + BE uint32 size + data, word aligned (odd sizes pad one
## byte not counted in size), LIST data is a 4 byte list type followed by
## subchunks bounded by size - 4. `LIST btdk` is stored opaque (COS data,
## not RIFF) and never recursed. Bytes past the root chunk are returned
## as `xmpTail`, not parsed.

import ./types

const
  RifxMagic* = "RIFX"
  AepForm* = "Egg!"
  ListId* = "LIST"
  BtdkList* = "btdk"

type
  RifxChunk* = object
    id*: string ## FourCC, eg LIST, Layr, cdta
    size*: uint32 ## data size as stored (excludes header and pad)
    listType*: string ## set when id == LIST, eg Item, Layr, Fold
    data*: seq[byte] ## payload for leaf chunks, empty for parsed LISTs
    children*: seq[RifxChunk] ## parsed subchunks for LISTs
    opaque*: bool ## true for btdk (kept raw, never recursed)

  RifxRoot* = object
    formType*: string ## Egg! for AEP projects
    children*: seq[RifxChunk]
    xmpTail*: string ## trailing bytes after the root chunk (XMP XML)

proc readU32BE(data: openArray[byte], pos: int): uint32 =
  (uint32(data[pos]) shl 24) or (uint32(data[pos + 1]) shl 16) or
    (uint32(data[pos + 2]) shl 8) or uint32(data[pos + 3])

proc readFourCC(data: openArray[byte], pos: int): string =
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = char(data[pos + i])

proc parseChunks(data: openArray[byte], first: int, last: int, depth: int,
    limits: AepLimits, count: var int): seq[RifxChunk] =
  ## Parse [first, last) into chunks. Bounds are exact: a child may never
  ## extend past its parent end.
  if depth > limits.maxDepth:
    raise newException(AepError,
      "RIFX depth exceeds limit " & $limits.maxDepth)
  result = @[]
  var pos = first
  while pos < last:
    if last - pos < 8:
      raise newException(AepError,
        "truncated RIFX chunk header at offset " & $pos)
    let id = readFourCC(data, pos)
    let size = readU32BE(data, pos + 4)
    if size > uint32(limits.maxChunkBytes):
      raise newException(AepError, "RIFX chunk " & id & " size " & $size &
        " exceeds limit " & $limits.maxChunkBytes)
    let sizeI = int(size)
    if pos + 8 + sizeI > last:
      raise newException(AepError, "RIFX chunk " & id & " at offset " &
        $pos & " overruns parent end")
    inc count
    if count > limits.maxChunks:
      raise newException(AepError,
        "RIFX chunk count exceeds limit " & $limits.maxChunks)
    if id == ListId:
      if sizeI < 4:
        raise newException(AepError,
          "LIST chunk at offset " & $pos & " smaller than list type")
      let listType = readFourCC(data, pos + 8)
      var node = RifxChunk(id: id, size: size, listType: listType,
        opaque: listType == BtdkList)
      if listType == BtdkList:
        node.data = @(data[pos + 8 ..< pos + 8 + sizeI])
      else:
        node.children = parseChunks(data, pos + 12, pos + 8 + sizeI,
          depth + 1, limits, count)
      result.add(node)
    else:
      result.add(RifxChunk(id: id, size: size,
        data: @(data[pos + 8 ..< pos + 8 + sizeI])))
    pos += 8 + sizeI + (sizeI and 1)

proc readRifxBytes*(data: openArray[byte],
    limits = defaultAepLimits()): RifxRoot =
  if data.len < 12:
    raise newException(AepError,
      "too short for RIFX header (" & $data.len & " bytes)")
  let magic = readFourCC(data, 0)
  if magic != RifxMagic:
    raise newException(AepError,
      "not a RIFX file (found " & magic & ")")
  let size = readU32BE(data, 4)
  if size > uint32(limits.maxChunkBytes):
    raise newException(AepError,
      "RIFX root size exceeds limit " & $limits.maxChunkBytes)
  let formType = readFourCC(data, 8)
  let sizeI = int(size)
  if 8 + sizeI > data.len:
    raise newException(AepError, "truncated RIFX root: declares " &
      $(8 + sizeI) & " bytes, file has " & $data.len)
  var count = 0
  let kids = parseChunks(data, 12, 8 + sizeI, 1, limits, count)
  var tail = ""
  let tailStart = 8 + sizeI + (sizeI and 1)
  if tailStart < data.len:
    tail = newString(data.len - tailStart)
    for i in 0 ..< tail.len:
      tail[i] = char(data[tailStart + i])
  RifxRoot(formType: formType, children: kids, xmpTail: tail)

proc readRifxBytes*(data: string,
    limits = defaultAepLimits()): RifxRoot =
  var buf = newSeq[byte](data.len)
  for i, c in data:
    buf[i] = byte(c)
  readRifxBytes(buf, limits)

proc childrenById*(c: RifxChunk, id: string): seq[RifxChunk] =
  result = @[]
  for k in c.children:
    if k.id == id:
      result.add(k)

proc listByType*(c: RifxChunk, listType: string): seq[RifxChunk] =
  result = @[]
  for k in c.children:
    if k.id == ListId and k.listType == listType:
      result.add(k)

proc rootListsByType*(r: RifxRoot, listType: string): seq[RifxChunk] =
  result = @[]
  for k in r.children:
    if k.id == ListId and k.listType == listType:
      result.add(k)

proc findFirst*(c: RifxChunk, id: string): int =
  for i, k in c.children:
    if k.id == id:
      return i
  return -1
