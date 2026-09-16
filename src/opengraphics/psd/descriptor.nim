## Generic Photoshop descriptor reader (OSType descriptor grammar).
##
## Descriptors carry keyed metadata in `SoCo` fills, `SoLd` smart
## objects, `vogk`/`vstk` shape data and elsewhere. Layout (clean-room
## reimplementation; item grammar checked against libpsd
## `src/solid_color.c` + `src/descriptor.c`
## `psd_stream_get_object_color`, extended to nested objects, lists,
## unit floats and enums from on-disk `SoLd` bytes):
##
##   descriptor := u32 version (=16) + object
##   object     := u32 nameLen + name[nameLen*2 UTF-16] +
##                 u32 classLen + class[classLen ASCII, or 4 raw bytes
##                 when 0] + u32 itemCount + item[itemCount]
##   item       := key + OSType[4] + value
##   key        := u32 len; len==0 ? raw[4] : ASCII[len]
##   value(TEXT) := u32 nchars + UTF-16BE[nchars]
##   value(long) := i32
##   value(doub) := f64
##   value(UntF) := OSType[4] unit + f64
##   value(enum) := u32 tlen + ASCII[tlen] + u32 vlen + ASCII[vlen]
##   value(bool) := u8
##   value(Objc) := object (recursive)
##   value(VlLs) := u32 count + (OSType[4] + value)*count
##   other types := preserved as raw value bytes (kind kept, no decode)
##
## v1 limits: nesting depth capped at 32, item/list counts at
## `Limits.maxBlocks`; unknown value types are preserved, not decoded.

import ./types
import ./reader

const MaxDescDepth = 32

type
  DescValueKind* {.pure.} = enum
    Text = 0
    Long = 1
    Double = 2
    UnitFloat = 3
    Enum = 4
    Bool = 5
    Object = 6
    List = 7
    Raw = 8

  DescValue* = object
    case kind*: DescValueKind
    of Text: text*: string
    of Long: num*: int32
    of Double: f*: float64
    of UnitFloat:
      unit*: string
      uf*: float64
    of Enum:
      enumType*: string
      enumValue*: string
    of Bool: b*: bool
    of Object: obj*: DescObject
    of List: items*: seq[DescValue]
    of Raw:
      rawType*: string
      raw*: seq[byte]

  DescItem* = object
    key*: string
    value*: DescValue

  DescObject* = object
    name*: string
    classId*: string
    items*: seq[DescItem]

proc readKey(r: var BinReader): string =
  ## Length-prefixed ASCII key (0 length = 4 raw bytes).
  let n = int(r.readU32BE())
  if n == 0:
    r.readStr(4)
  else:
    if n <= 0 or n > 256:
      raise newException(PsdError, "bad descriptor key length " & $n)
    r.readStr(n)

proc readUnicodeName(r: var BinReader): string =
  ## u32 char count + UTF-16BE, ASCII-folded (names are identifiers).
  let n = int(r.readU32BE())
  if n < 0 or n > 4096:
    raise newException(PsdError, "bad descriptor name length " & $n)
  result = ""
  for _ in 0 ..< n:
    let c = r.readU16BE()
    if c == 0:
      break
    result.add(if c < 128: char(c) else: '?')

proc readF64BE(r: var BinReader): float64 =
  var bits: uint64 = 0
  for b in r.readBytes(8):
    bits = (bits shl 8) or uint64(b)
  cast[float64](bits)

proc readDescValue(r: var BinReader, typ: string, depth: int,
    limits: Limits): DescValue

proc readDescObject(r: var BinReader, depth: int,
    limits: Limits): DescObject =
  if depth > MaxDescDepth:
    raise newException(PsdError, "descriptor nesting too deep")
  let name = readUnicodeName(r)
  let classLen = int(r.readU32BE())
  let classId =
    if classLen == 0: r.readStr(4)
    else:
      if classLen <= 0 or classLen > 256:
        raise newException(PsdError, "bad descriptor class length " &
          $classLen)
      r.readStr(classLen)
  let count = int(r.readU32BE())
  if count < 0 or count > limits.maxBlocks:
    raise newException(PsdError, "descriptor item count " & $count &
      " exceeds limit " & $limits.maxBlocks)
  result = DescObject(name: name, classId: classId, items: @[])
  for _ in 0 ..< count:
    let key = readKey(r)
    let typ = r.readStr(4)
    result.items.add(DescItem(key: key,
      value: readDescValue(r, typ, depth + 1, limits)))

proc readDescValue(r: var BinReader, typ: string, depth: int,
    limits: Limits): DescValue =
  case typ
  of "TEXT":
    DescValue(kind: Text, text: readUnicodeName(r))
  of "long":
    DescValue(kind: Long, num: r.readI32BE())
  of "doub":
    DescValue(kind: Double, f: readF64BE(r))
  of "bool":
    DescValue(kind: Bool, b: r.readU8() != 0)
  of "UntF":
    let unit = r.readStr(4)
    DescValue(kind: UnitFloat, unit: unit, uf: readF64BE(r))
  of "enum":
    # Value is two keys under the standard convention: u32 length
    # (0 = 4 raw bytes, else ASCII), e.g. `9 warpStyle 8 warpNone`
    # or `0 Ornt 0 Hrzn`.
    let t = readKey(r)
    let v = readKey(r)
    DescValue(kind: Enum, enumType: t, enumValue: v)
  of "Objc":
    DescValue(kind: Object, obj: readDescObject(r, depth, limits))
  of "VlLs":
    let n = int(r.readU32BE())
    if n < 0 or n > limits.maxBlocks:
      raise newException(PsdError, "descriptor list length " & $n &
        " exceeds limit " & $limits.maxBlocks)
    var items: seq[DescValue] = @[]
    for _ in 0 ..< n:
      let et = r.readStr(4)
      items.add(readDescValue(r, et, depth, limits))
    DescValue(kind: List, items: items)
  else:
    # Unknown value type: cannot size it, so the stream cannot stay
    # aligned. Fail loudly rather than misparse the rest.
    raise newException(PsdError,
      "unsupported descriptor value type '" & typ & "'")

proc parseDescriptor*(data: seq[byte],
    limits = defaultLimits()): DescObject =
  ## Parse one descriptor (u32 version 16 + object). Raises `PsdError`
  ## on truncation, bad version, or over-limit counts.
  if data.len < 4:
    raise newException(PsdError, "short descriptor (" & $data.len &
      " bytes)")
  var r = initReader(data)
  let version = int(r.readU32BE())
  if version != 16:
    raise newException(PsdError, "unsupported descriptor version " &
      $version)
  result = readDescObject(r, 0, limits)

proc findItem*(obj: DescObject, key: string): int =
  for i, it in obj.items:
    if it.key == key:
      return i
  -1

proc getText*(obj: DescObject, key: string): string =
  ## TEXT value for `key`, or "" when absent/wrong type.
  let i = obj.findItem(key)
  if i < 0 or obj.items[i].value.kind != Text:
    return ""
  obj.items[i].value.text

proc getLong*(obj: DescObject, key: string, default = 0'i32): int32 =
  let i = obj.findItem(key)
  if i < 0 or obj.items[i].value.kind != Long:
    return default
  obj.items[i].value.num

proc getDoubles*(obj: DescObject, key: string): seq[float64] =
  ## VlLs-of-doub value for `key`, or empty when absent/mistyped.
  let i = obj.findItem(key)
  if i < 0 or obj.items[i].value.kind != List:
    return @[]
  for v in obj.items[i].value.items:
    if v.kind != Double:
      return @[]
    result.add(v.f)

proc getObject*(obj: DescObject, key: string): tuple[ok: bool, o: DescObject] =
  let i = obj.findItem(key)
  if i < 0 or obj.items[i].value.kind != Object:
    return (false, DescObject())
  (true, obj.items[i].value.obj)

proc getUnitFloat*(obj: DescObject, key: string): tuple[ok: bool,
    unit: string, v: float64] =
  let i = obj.findItem(key)
  if i < 0 or obj.items[i].value.kind != UnitFloat:
    return (false, "", 0.0)
  let v = obj.items[i].value
  (true, v.unit, v.uf)
