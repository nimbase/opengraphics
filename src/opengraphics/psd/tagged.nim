## Tagged blocks: the key/value chunks inside a layer record, the layer info
## section and a layer-and-mask section's global area.
##
## A block is `signature "8BIM" | "8B64"`, a 4-byte key, a length, that many
## bytes, then padding. The spec says the length is "rounded up to an even
## byte count", but in practice writers disagree: some include padding in the
## length and append it after the data, and some pad to 2 and some to 4.
##
## Rather than pick one convention, the parser *measures* the padding that
## actually follows each block: the smallest k <= 3 after which the next
## signature or the end of the region appears. That padding is stored unless
## it matches the canonical zero-pad, in which case `padding` is `none`. That
## is what makes `read(b).write == b` hold for unmodified files.
##
## There is no key-to-parser dispatch table. Preservation is total (raw data
## plus exact padding) and typed access is an opt-in overlay via `parsed`,
## mirroring the reference.

import std/options
import std/sequtils

import ./error
import ./header
import ./io

type
  SectionTypeKind* {.pure.} = enum
    stOther, stOpenFolder, stClosedFolder, stBoundingDivider, stUnknown

  SectionType* = object
    ## `Other` (0) is a normal layer; 1 and 2 are the folder records that open
    ## and close a group; 3 is the bounding divider that marks a group's span.
    ## An unrecognised code keeps its raw value so it round-trips.
    case kind*: SectionTypeKind
    of stOther: discard
    of stOpenFolder: discard
    of stClosedFolder: discard
    of stBoundingDivider: discard
    of stUnknown: raw*: uint32

  SectionDivider* = object
    kind*: SectionType
    blendMode*: string
      ## 4-char key; empty when the block was too short to carry one
    hasBlendMode*: bool
    subType*: uint32 ## 0 normal, 1 scene group
    hasSubType*: bool

  BlockDataKind* {.pure.} = enum
    bdUnicodeName, bdSectionDivider, bdLayerId, bdNameSource,
    bdBlendClippedAsGroup, bdBlendInteriorElements, bdKnockout,
    bdProtection, bdSheetColor, bdFillOpacity, bdMetadataSetting

  BlockData* = object
    case kind*: BlockDataKind
    of bdUnicodeName: name*: string
    of bdSectionDivider: divider*: SectionDivider
    of bdLayerId: layerId*: uint32
    of bdNameSource: source*: string
    of bdBlendClippedAsGroup, bdBlendInteriorElements: flag*: bool
    of bdKnockout: knockout*: uint8
    of bdProtection: protection*: uint32
    of bdSheetColor: color*: uint16
    of bdFillOpacity: fillOpacity*: uint8
    of bdMetadataSetting: metadata*: Span ## raw; see metadata.nim

  TaggedBlock* = object
    signature*: string ## "8BIM" or "8B64", preserved as read
    key*: string
    data*: Span       ## exactly the bytes the length field covered, as a window
                      ## into the file: no copy, so a file with thousands of
                      ## blocks costs 24 bytes per block rather than the sum of
                      ## its payloads
    padding*: Option[Span]
      ## `none` means "zero-pad to even", and the parser yields `none`
      ## whenever the file used that default, so the model stays canonical.
      ## `some` of an empty seq records the pathological case of a
      ## misaligned block with no padding at all, which must round-trip too.

const
  ## Blocks whose length is 64-bit in PSB. Every other key stays 32-bit.
  PsbLongKeys* = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn",
    "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"]

proc usesLongLength*(version: Version, key: string): bool =
  version.isPsb() and key in PsbLongKeys

proc sectionTypeFromU32*(v: uint32): SectionType =
  case v
  of 0'u32: SectionType(kind: stOther)
  of 1'u32: SectionType(kind: stOpenFolder)
  of 2'u32: SectionType(kind: stClosedFolder)
  of 3'u32: SectionType(kind: stBoundingDivider)
  else: SectionType(kind: stUnknown, raw: v)

proc toU32*(s: SectionType): uint32 {.inline.} =
  case s.kind
  of stOther: 0'u32
  of stOpenFolder: 1'u32
  of stClosedFolder: 2'u32
  of stBoundingDivider: 3'u32
  of stUnknown: s.raw

proc isFolder*(s: SectionType): bool {.inline.} =
  s.kind == stOpenFolder or s.kind == stClosedFolder

proc isDivider*(s: SectionType): bool {.inline.} =
  s.kind == stBoundingDivider

proc sectionType*(d: SectionDivider): SectionType {.inline.} =
  ## Unwrap the divider's section type. Named because callers reach for this
  ## constantly and the raw `kind` field is itself a `SectionType`.
  d.kind

proc newTaggedBlock*(key: string, data: Span): TaggedBlock {.inline.} =
  ## A block over existing bytes. Zero-copy when `data` came from a file.
  TaggedBlock(signature: "8BIM", key: key, data: data,
    padding: none(Span))

proc newTaggedBlock*(key, data: string): TaggedBlock =
  ## A block over synthesised bytes. The payload becomes its own one-byte-heap
  ## source, so callers that build blocks do not have to manage a `Source`.
  TaggedBlock(signature: "8BIM", key: key,
    data: Span(src: newStringSource(data), start: 0, stop: data.len),
    padding: none(Span))

proc unicodeNameBlock*(name: string): TaggedBlock =
  ## An `luni` block. Photoshop pads the payload to a multiple of 4.
  var units = toUtf16Units(name)
  units.add(0'u16) # Photoshop terminates with a NUL unit
  var w = initWriter()
  w.writeUnicodeUnits(units)
  # pad to a multiple of 4
  while (w.len() and 3) != 0:
    w.putU8(0)
  newTaggedBlock("luni", w.toString())

proc sectionDividerBlock*(kind: SectionType, blendMode = "",
    subType = none(uint32)): TaggedBlock =
  ## An `lsct` block. The payload is 4 bytes for the kind alone, 12 when a
  ## blend mode follows, and 16 when a sub-type is present as well, which are
  ## exactly the thresholds `parseSectionDivider` probes for.
  var w = initWriter()
  w.putU32(kind.toU32())
  if blendMode.len == 4:
    w.putStr4("8BIM")
    w.putStr4(blendMode)
    if subType.isSome:
      w.putU32(subType.get())
  newTaggedBlock("lsct", w.toString())

proc layerIdBlock*(id: uint32): TaggedBlock =
  var w = initWriter()
  w.putU32(id)
  newTaggedBlock("lyid", w.toString())

proc nameSourceBlock*(source: string): TaggedBlock =
  newTaggedBlock("lnsr", source)

proc boolBlock*(key: string, v: bool): TaggedBlock =
  ## The 4-byte `v,0,0,0` shape Photoshop uses for clbl and infx.
  var w = initWriter()
  w.putU8(if v: 1'u8 else: 0'u8)
  for _ in 1 ..< 4:
    w.putU8(0)
  newTaggedBlock(key, w.toString())

proc knockoutBlock*(v: uint8): TaggedBlock =
  var w = initWriter()
  w.putU8(v)
  for _ in 1 ..< 4:
    w.putU8(0)
  newTaggedBlock("knko", w.toString())

proc protectionBlock*(flags: uint32): TaggedBlock =
  var w = initWriter()
  w.putU32(flags)
  newTaggedBlock("lspf", w.toString())

proc sheetColorBlock*(color: uint16): TaggedBlock =
  ## The 8-byte shape Photoshop uses: a u16 followed by six zero bytes.
  var w = initWriter()
  w.putU16(color)
  for _ in 0 ..< 6:
    w.putU8(0)
  newTaggedBlock("lclr", w.toString())

proc fillOpacityBlock*(v: uint8): TaggedBlock =
  var w = initWriter()
  w.putU8(v)
  for _ in 1 ..< 4:
    w.putU8(0)
  newTaggedBlock("iOpa", w.toString())

proc parseSectionDivider*(data: Span): SectionDivider =
  ## 4 bytes kind, then optionally an `8BIM` signature plus a blend key, then
  ## optionally a sub-type.
  if data.len < 4:
    invalid("section divider needs at least 4 bytes, got " & $data.len)
  var r = initReader(data)
  result.kind = sectionTypeFromU32(r.readU32BE())
  if r.remaining() >= 8:
    let sig = r.readStr4()
    if sig != "8BIM":
      badSignature("8BIM", sig, r.pos - 4)
    result.blendMode = r.readStr4()
    result.hasBlendMode = true
  if r.remaining() >= 4:
    result.subType = r.readU32BE()
    result.hasSubType = true

proc parsed*(b: TaggedBlock): Option[BlockData] =
  ## Typed view of the keys this layer models. `none` means the key is
  ## preserved but not interpreted (effects, type layers, smart objects,
  ## vector masks, adjustment layers); `some` carries either the value or,
  ## for a malformed payload, nothing, so the caller can fall back to `data`.
  var r = initReader(b.data)
  case b.key
  of "luni":
    if b.data.len < 4:
      return none(BlockData)
    some(BlockData(kind: bdUnicodeName, name: unicodeToString(r.readUnicodeUnits())))
  of "lsct", "lsdk":
    var d: BlockData
    try:
      d = BlockData(kind: bdSectionDivider, divider: parseSectionDivider(b.data))
    except PsdError:
      return none(BlockData)
    some(d)
  of "lyid":
    if b.data.len < 4:
      return none(BlockData)
    some(BlockData(kind: bdLayerId, layerId: r.readU32BE()))
  of "lnsr":
    if b.data.len < 4:
      return none(BlockData)
    some(BlockData(kind: bdNameSource, source: r.readStr4()))
  of "clbl", "infx":
    if b.data.len < 1:
      return none(BlockData)
    let v = r.readU8() != 0
    if b.key == "clbl":
      some(BlockData(kind: bdBlendClippedAsGroup, flag: v))
    else:
      some(BlockData(kind: bdBlendInteriorElements, flag: v))
  of "knko":
    if b.data.len < 1:
      return none(BlockData)
    some(BlockData(kind: bdKnockout, knockout: r.readU8()))
  of "lspf":
    if b.data.len < 4:
      return none(BlockData)
    some(BlockData(kind: bdProtection, protection: r.readU32BE()))
  of "lclr":
    if b.data.len < 2:
      return none(BlockData)
    some(BlockData(kind: bdSheetColor, color: r.readU16BE()))
  of "iOpa":
    if b.data.len < 1:
      return none(BlockData)
    some(BlockData(kind: bdFillOpacity, fillOpacity: r.readU8()))
  of "shmd":
    some(BlockData(kind: bdMetadataSetting, metadata: b.data))
  else:
    none(BlockData)

proc isSig*(s: string): bool {.inline.} =
  s == "8BIM" or s == "8B64"

proc readBlocks*(r: var Reader, version: Version,
    limits = defaultLimits()): tuple[blocks: seq[TaggedBlock], trailing: Span] =
  ## Read blocks until the view is exhausted. Bytes that do not begin a block
  ## are returned as `trailing` rather than guessed at.
  ##
  ## The block count is capped by `limits.maxBlocks`; each block costs at least
  ## 12 bytes, so the cap is what stops a long region expanding into millions
  ## of empty records.
  result.blocks = @[]
  while true:
    let rest = r.remaining
    if rest < 12:
      result.trailing = r.peekRest()
      return
    if not (r.matchesAt(0, "8BIM") or r.matchesAt(0, "8B64")):
      result.trailing = r.peekRest()
      return
    if result.blocks.len >= limits.maxBlocks:
      limitExceeded("tagged block count " & $result.blocks.len &
        " reaches limit " & $limits.maxBlocks)
    let sig = r.readStr4()
    let key = r.readStr4()
    let n = r.lenField(usesLongLength(version, key))
    if n > r.remaining:
      eof(int(n - r.remaining), r.pos)
    let data = r.bytes(int(n))
    # measure the padding that actually follows: the smallest k <= 3 after
    # which the next signature or the end of the region appears
    var padLen = 0
    for k in 0 .. 3:
      let avail = r.remaining - k
      if avail < 0:
        break
      if avail == 0 or (avail >= 4 and
          (r.matchesAt(k, "8BIM") or r.matchesAt(k, "8B64"))):
        padLen = k
        break
    let padBytes = r.bytes(padLen) # consumes them; no separate skip needed
    # the canonical padding is zero bytes to an even length; only a deviation
    # needs storing
    var padding: Option[Span] = none(Span)
    var nonZero = false
    for i in 0 ..< padLen:
      if padBytes.byteAt(i) != 0'u8:
        nonZero = true
    if padLen != data.len mod 2 or nonZero:
      padding = some(padBytes)
    result.blocks.add(TaggedBlock(signature: sig, key: key, data: data,
      padding: padding))

proc writeBlocks*(w: var Writer, blocks: openArray[TaggedBlock],
    version: Version) =
  ## Inverse of `readBlocks`: re-emit each block's stored padding verbatim,
  ## or the canonical zero-pad when `padding` is `nil`.
  for b in blocks:
    w.putStr4(b.signature)
    w.putStr4(b.key)
    w.putLen(int64(b.data.len), usesLongLength(version, b.key))
    w.put(b.data)
    if b.padding.isSome:
      w.put(b.padding.get())
    elif (b.data.len and 1) != 0:
      w.putU8(0)

proc encodedLen*(b: TaggedBlock, version: Version): int {.inline.} =
  ## Size this block will occupy on the wire.
  8 + (if usesLongLength(version, b.key): 8 else: 4) + b.data.len +
    (if b.padding.isSome: b.padding.get().len else: (b.data.len and 1))

proc findBlock*(blocks: openArray[TaggedBlock], key: string): int =
  ## Index of the first block with `key`, or -1.
  for i, b in blocks:
    if b.key == key:
      return i
  -1

proc getBlock*(blocks: openArray[TaggedBlock], key: string): Option[TaggedBlock] =
  let i = findBlock(blocks, key)
  if i < 0: none(TaggedBlock) else: some(blocks[i])
