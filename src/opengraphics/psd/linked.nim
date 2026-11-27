## Linked/embedded smart-object files (`lnk2`/`lnk3`/`lnkD` global blocks).
##
## Layout follows Adobe's "Linked Layer" section via
## `references/photocraft/crates/io/src/linked.rs` (clean-room: layouts only).
## Each block holds a sequence of `u64 length + item`, padded to 4. An item is
## `liFD` (embedded bytes), `liFE` (external) or `liFA` (alias): version,
## Pascal uuid, Unicode file name, file type, creator, `u64` data length,
## open-descriptor flag (+ versioned descriptor when set), then the payload.
##
## Read-only: `liFD` yields bytes; `liFE`/`liFA` yield identity without bytes.
## Nothing here rewrites a file; it only reads.

import std/options

import ./descriptor
import ./error
import ./file
import ./io

type
  LinkedKind* {.pure.} = enum
    lkEmbedded, lkExternal, lkAlias, lkUnknown

  LinkedFile* = object
    uuid*: string
    fileName*: string
    kind*: LinkedKind
    bytes*: Span ## empty unless `lkEmbedded`
    hasBytes*: bool

proc linkedKindFor*(t: string): LinkedKind =
  case t
  of "liFD": lkEmbedded
  of "liFE": lkExternal
  of "liFA": lkAlias
  else: lkUnknown

proc readPascalStr(r: var Reader): string =
  let n = int(r.readU8())
  let s = r.bytes(n).clone
  if (n + 1) mod 4 != 0:
    r.skip(4 - ((n + 1) mod 4))
  s

proc parseLinkedItem*(data: Span): Option[LinkedFile] =
  ## One `length`-framed item (without the leading u64).
  if data.len < 8: return none(LinkedFile)
  var r = initReader(data)
  try:
    let typ = r.readStr4()
    let kind = linkedKindFor(typ)
    discard r.readU32BE() # version
    let uuid = readPascalStr(r)
    let fname = unicodeToString(r.readUnicodeUnits())
    # file type (4) + creator (4) + u64 data length
    if r.remaining() < 16: return none(LinkedFile)
    discard r.readStr4()
    discard r.readStr4()
    let dataLen = int(r.readU64BE())
    if r.remaining() < 1: return none(LinkedFile)
    let hasDesc = r.readU8() != 0
    if hasDesc:
      # versioned descriptor follows; skip via prefix parse
      try:
        let vd = parseVersionedDescriptor(r.peekRest())
        r.skip(vd.toBytes().len)
      except PsdError:
        return none(LinkedFile)
    if kind == lkEmbedded:
      if dataLen > r.remaining(): return none(LinkedFile)
      let bytes = r.bytes(dataLen)
      some(LinkedFile(uuid: uuid, fileName: fname, kind: kind,
        bytes: bytes, hasBytes: true))
    else:
      some(LinkedFile(uuid: uuid, fileName: fname, kind: kind,
        bytes: emptySpan(), hasBytes: false))
  except PsdError:
    none(LinkedFile)

proc parseLinkedBlock*(data: Span): seq[LinkedFile] =
  ## All items in one `lnk2`/`lnk3`/`lnkD` payload. Malformed tails stop the
  ## scan rather than failing the file: later records are still attempted.
  result = @[]
  var r = initReader(data)
  while r.remaining() >= 8:
    let n =
      try: int(r.readU64BE())
      except PsdError: break
    if n < 0 or n > r.remaining(): break
    let item = r.bytes(n)
    # items are padded to 4
    let pad = (4 - (n mod 4)) mod 4
    if pad > 0 and pad <= r.remaining():
      try: r.skip(pad)
      except PsdError: discard
    let lf = parseLinkedItem(item)
    if lf.isSome: result.add(lf.get())

proc linkedFilesOf*(f: PsdFile): seq[LinkedFile] =
  for key in ["lnk2", "lnk3", "lnkD"]:
    let b = f.globalBlock(key)
    if b.isSome:
      for lf in parseLinkedBlock(b.get().data):
        result.add(lf)

proc findLinkedFile*(f: PsdFile, uuid: string): Option[LinkedFile] =
  if uuid.len == 0: return none(LinkedFile)
  for lf in linkedFilesOf(f):
    if lf.uuid == uuid: return some(lf)
  none(LinkedFile)

proc embeddedBytes*(f: PsdFile, uuid: string): Span =
  ## Embedded bytes for `uuid`, or an empty span when linked/external/absent.
  let lf = findLinkedFile(f, uuid)
  if lf.isSome and lf.get().hasBytes: lf.get().bytes
  else: emptySpan()
