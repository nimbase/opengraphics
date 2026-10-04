## The `shmd` (metadata setting) layer block: a list of keyed sub-blocks, such
## as `cmls` (layer comp state, a versioned descriptor), `cust` (compositor
## info) and `mlst` (layer metadata).
##
## Layout (Adobe PSD spec, "Metadata setting"): a u32 count, then per item the
## signature `8BIM`, a 4-byte key, a copy-on-sheet-duplication byte, 3 padding
## bytes, a u32 length and the data.
##
## Photoshop pads item data to an even length, and that padding is counted in
## the stored length rather than added afterwards. Keeping the data verbatim
## therefore makes this module exactly round-trippable: `write(parse(b)) == b`.
## `newMetadataItem` is the only place that adds the pad.

import std/options

import ./descriptor
import ./error
import ./io
import ./layers
import ./tagged

const
  ShmdKey* = "shmd"
    ## The tagged-block key this module parses.

  MetadataItemHeaderBytes* = 16
    ## Signature (4) + key (4) + copy flag (1) + 3 reserved + u32 length.

type
  MetadataItem* = object
    ## One `shmd` sub-block.
    signature*: array[4, byte]
      ## Usually `8BIM`; kept so non-standard signatures survive a round trip.
    key*: array[4, byte]
      ## Item key, e.g. `cmls`.
    copy*: bool
      ## "Copy on sheet duplication".
    reserved*: array[3, byte]
      ## The three bytes after the copy flag. Zero in Photoshop files; kept
      ## so a file that uses them still round-trips.
    data*: Span
      ## Item payload, including any pad counted in the stored length.

proc fourBytes(s: string): array[4, byte] =
  ## Right-padded or truncated to exactly four bytes.
  for i in 0 ..< min(4, s.len):
    result[i] = byte(ord(s[i]) and 0xFF)

proc newMetadataItem*(key: string, data: string): MetadataItem =
  ## A new item with the usual `8BIM` signature. `data` is zero-padded to an
  ## even length the way Photoshop writes it, so `writeShmd` reproduces what
  ## Photoshop would have produced.
  var padded = data
  if (padded.len and 1) != 0:
    padded.add(char(0))
  result.signature = fourBytes("8BIM")
  result.key = fourBytes(key)
  result.data = spanOf(padded)

proc keyString*(item: MetadataItem): string {.inline.} =
  ## The item key as text.
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = char(item.key[i])

proc parseShmd*(data: Span, limits = defaultLimits()): seq[MetadataItem] =
  ## Parse `shmd` block data. Raises `PsdError` when the count does not fit in
  ## what is left, when an item is truncated, or when bytes remain after the
  ## declared number of items.
  var r = initReader(data)
  let count = int64(r.readU32BE())
  limits.checkCount(count, r.remaining.int64, MetadataItemHeaderBytes.int64,
    "metadata items")
  result = newSeq[MetadataItem](int(count))
  for i in 0 ..< int(count):
    result[i].signature = r.readArray4()
    result[i].key = r.readArray4()
    result[i].copy = r.readU8() != 0
    let reserved3 = r.bytes(3)
    result[i].reserved = [reserved3.byteAt(0), reserved3.byteAt(1),
                          reserved3.byteAt(2)]
    let n = r.readU32BE()
    result[i].data = r.bytes(int(n))
  if r.remaining() != 0:
    invalid("trailing bytes after metadata items: " & $r.remaining())

proc writeShmd*(items: openArray[MetadataItem]): string =
  ## Serialize `shmd` block data. Item data is written verbatim, including the
  ## pad byte that counted toward its stored length.
  var w = initWriter()
  w.putU32(uint32(items.len))
  for item in items:
    w.putArray4(item.signature)
    w.putArray4(item.key)
    w.putU8(if item.copy: 1'u8 else: 0'u8)
    w.putBytes(item.reserved)
    w.putU32(uint32(item.data.len))
    w.put(item.data)
  w.toString()
# --- wiring -----------------------------------------------------------------

proc metadataOf*(layer: LayerRecord,
    limits = defaultLimits()): Option[seq[MetadataItem]] =
  ## The layer's `shmd` items, or `none` when the block is absent or does not
  ## parse. Typically this is the `cmls` layer-comp-state entry.
  let b = getBlock(layer.blocks, ShmdKey)
  if b.isNone:
    return none(seq[MetadataItem])
  try:
    some(parseShmd(b.get().data, limits))
  except PsdError:
    none(seq[MetadataItem])

proc hasMetadata*(layer: LayerRecord): bool {.inline.} =
  getBlock(layer.blocks, ShmdKey).isSome

proc compositorInfo*(data: Span,
    limits = defaultLimits()): Option[VersionedDescriptor] =
  ## The `cust` item parsed as a compositor-info descriptor.
  ##
  ## The item is a versioned descriptor followed by a pad byte: Photoshop pads
  ## the stored length to an even number but writes the pad *outside* the
  ## descriptor, so a strict parse sees one trailing byte. Parse a prefix and
  ## keep the remainder rather than rejecting the item.
  try:
    some(parsePrefixDescriptor(data, limits).descriptor)
  except PsdError:
    none(VersionedDescriptor)

proc compositorInfoOf*(layer: LayerRecord,
    limits = defaultLimits()): Option[VersionedDescriptor] =
  ## The layer's `cust` compositor info, or `none` when absent.
  let items = metadataOf(layer, limits)
  if items.isNone:
    return none(VersionedDescriptor)
  for item in items.get():
    if item.keyString() == "cust":
      return compositorInfo(item.data, limits)
  none(VersionedDescriptor)

proc parseShmd*(data: string, limits = defaultLimits()): seq[MetadataItem] =
  parseShmd(toSpan(data), limits)

proc compositorInfo*(data: string,
    limits = defaultLimits()): Option[VersionedDescriptor] =
  compositorInfo(toSpan(data), limits)
