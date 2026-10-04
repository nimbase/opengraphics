## Action descriptors: the keyed metadata blocks Photoshop uses for fills,
## smart objects, effects and type layers.
##
## A descriptor is the `SoCo` solid colour inside a `vscg`, the `SoLd` smart
## object data, the effects in an `lfx2` block, and much else. Layout, from
## Adobe's *Photoshop File Formats Specification*:
##
##   descriptor := u32 version (=16) + body
##   body       := u32 nameLen + name[nameLen UTF-16] +
##                 u32 classLen + class[classLen bytes, or 4 raw when 0] +
##                 u32 itemCount + item[itemCount]
##   item       := key + OSType[4] + value
##   key        := u32 len; len == 0 ? raw[4] : bytes[len]
##   Class      := name + classId
##
## All 18 OSType value keys are handled, along with all 7 reference-item
## types. Unlike tagged blocks, a descriptor is **not** lossless for input it
## does not recognise: an unknown OSType cannot be sized, so the stream could
## not be kept aligned and parsing fails rather than guessing. A caller that
## needs arbitrary bytes should keep `TaggedBlock.data` and retry.
##
## `bool` values read as "any non-zero is true" and are written back as 0 or
## 1, the one normalising round-trip case.

import std/options

import ./error
import ./io
import ./tagged

const
  ## Nesting cap. Deep enough for any real document.
  MaxDescriptorDepth* = 64
  DescriptorVersion* = 16'u32
  ## Smallest possible item: a 4-byte key, a 4-byte type, 1 byte of value.
  MinDescriptorItemBytes* = 9

type
  UnicodeString* = object
    ## UTF-16 code units, kept exactly as stored. Photoshop terminates names
    ## with a NUL unit; `toString` drops trailing NULs.
    units*: seq[uint16]

  DescIdKind* {.pure.} = enum
    ## `idCode` is the compact 4-byte form (written with a zero length);
    ## `idStr` is the explicit-length form. A stored explicit length of 4
    ## stays `idStr` so it round-trips unchanged.
    idCode, idStr

  DescId* = object
    case kind*: DescIdKind
    of idCode: code*: array[4, byte]
    of idStr: str*: string

  DescClass* = object
    name*: UnicodeString
    classId*: DescId

  ReferenceItemKind* {.pure.} = enum
    riProperty, riClass, riEnumerated, riOffset, riIdentifier, riIndex,
    riName

  ReferenceItem* = object
    case kind*: ReferenceItemKind
    of riProperty:
      propClass*: DescClass
      propKey*: DescId
    of riClass: clsClass*: DescClass
    of riEnumerated:
      enumClass*: DescClass
      typeId*: DescId
      valueId*: DescId
    of riOffset:
      offClass*: DescClass
      offset*: int32
    of riIdentifier: identifier*: uint32
    of riIndex: index*: uint32
    of riName:
      nameClass*: DescClass
      name*: UnicodeString

  ValueKind* {.pure.} = enum
    vReference, vDescriptor, vGlobalObject, vList, vDouble, vUnitFloat,
    vUnitFloats, vText, vEnumerated, vInteger, vLargeInteger, vBoolean,
    vClass, vGlobalClass, vAlias, vPath, vRawData, vObjectArray

  Value* = object
    case kind*: ValueKind
    of vReference: reference*: seq[ReferenceItem]
    of vDescriptor: descriptor*: Descriptor
    of vGlobalObject: globalObject*: Descriptor
    of vList: items*: seq[Value]
    of vDouble: double*: float64
    of vUnitFloat:
      floatUnit*: array[4, byte]
      floatUnitValue*: float64
    of vUnitFloats:
      floatsUnit*: array[4, byte]
      floatsUnitValues*: seq[float64]
    of vText: text*: UnicodeString
    of vEnumerated:
      typeId*: DescId
      valueId*: DescId
    of vInteger: integer*: int32
    of vLargeInteger: large*: int64
    of vBoolean: boolean*: bool
    of vClass: valueClass*: DescClass
    of vGlobalClass: globalClass*: DescClass
    of vAlias: alias*: Span
    of vPath: path*: Span
    of vRawData: rawData*: Span
    of vObjectArray:
      arrayPrefix*: uint32
      arrayBody*: Descriptor

  DescItem* = object
    key*: DescId
    value*: Value

  Descriptor* = object
    name*: UnicodeString
    classId*: DescId
    items*: seq[DescItem]

  VersionedDescriptor* = object
    version*: uint32
    descriptor*: Descriptor

proc newUnicodeString*(s: string, terminate = false): UnicodeString =
  result.units = toUtf16Units(s)
  if terminate:
    result.units.add(0'u16)

proc toString*(u: UnicodeString): string {.inline.} =
  unicodeToString(u.units)

proc newId*(s: string): DescId =
  if s.len == 4:
    var c: array[4, byte]
    for i in 0 ..< 4:
      c[i] = byte(ord(s[i]))
    DescId(kind: idCode, code: c)
  else:
    DescId(kind: idStr, str: s)

proc asString*(i: DescId): string {.inline.} =
  case i.kind
  of idCode:
    result = newString(4)
    for k in 0 ..< 4:
      result[k] = char(ord(i.code[k]))
  of idStr:
    result = i.str

proc equals*(i: DescId, s: string): bool {.inline.} = i.asString() == s

proc unitBytes*(s: string): array[4, byte] {.inline.} =
  for i in 0 ..< 4:
    result[i] = if i < s.len: byte(ord(s[i])) else: byte(ord(' '))

# --- constructors -----------------------------------------------------------

proc spanValue*(s: string): Span {.inline.} =
  ## A window over freshly made bytes, for the synthesised-value constructors
  ## below and for tests. Parsed values keep a window into the file instead.
  Span(src: newStringSource(s), start: 0, stop: s.len)

proc emptyClass*(classId = ""): DescClass {.inline.} =
  DescClass(name: newUnicodeString(""), classId: newId(classId))

proc newDescriptor*(classId: string): Descriptor =
  Descriptor(name: newUnicodeString(""), classId: newId(classId), items: @[])

proc add*(d: var Descriptor, key: string, value: Value): Descriptor =
  ## Append an item in place. Returns self, so a `var` chain works.
  d.items.add(DescItem(key: newId(key), value: value))
  d

proc with*(d: Descriptor, key: string, value: Value): Descriptor =
  ## Functional append, for chaining off a fresh descriptor:
  ## `newDescriptor("null").with("a", intValue(1)).with("b", ...)`.
  result = d
  result.items.add(DescItem(key: newId(key), value: value))

proc textValue*(s: string, terminate = false): Value =
  Value(kind: vText, text: newUnicodeString(s, terminate))

proc doubleValue*(v: float64): Value = Value(kind: vDouble, double: v)
proc intValue*(v: int32): Value = Value(kind: vInteger, integer: v)
proc longValue*(v: int64): Value = Value(kind: vLargeInteger, large: v)
proc boolValue*(v: bool): Value = Value(kind: vBoolean, boolean: v)
proc enumValue*(t, v: string): Value =
  Value(kind: vEnumerated, typeId: newId(t), valueId: newId(v))
proc unitFloatValue*(unit: string, v: float64): Value =
  Value(kind: vUnitFloat, floatUnit: unitBytes(unit),
    floatUnitValue: v)
proc classValue*(classId: string): Value =
  Value(kind: vClass, valueClass: emptyClass(classId))
proc globalClassValue*(classId: string): Value =
  Value(kind: vGlobalClass, globalClass: emptyClass(classId))
proc rawDataValue*(s: string): Value = Value(kind: vRawData, rawData: spanValue(s))
proc pathValue*(s: string): Value = Value(kind: vPath, path: spanValue(s))
proc aliasValue*(s: string): Value = Value(kind: vAlias, alias: spanValue(s))
proc descriptorValue*(d: Descriptor): Value =
  Value(kind: vDescriptor, descriptor: d)
proc globalObjectValue*(d: Descriptor): Value =
  Value(kind: vGlobalObject, globalObject: d)

proc listValue*(items: seq[Value]): Value = Value(kind: vList, items: items)

proc unitFloatsValue*(unit: string, values: seq[float64]): Value =
  Value(kind: vUnitFloats, floatsUnit: unitBytes(unit),
    floatsUnitValues: values)

proc objectArrayValue*(prefix: uint32, body: Descriptor): Value =
  Value(kind: vObjectArray, arrayPrefix: prefix, arrayBody: body)

proc referenceValue*(items: seq[ReferenceItem]): Value =
  Value(kind: vReference, reference: items)

# --- accessors --------------------------------------------------------------

proc get*(d: Descriptor, key: string): Option[Value] =
  ## First item with `key`, compared by raw identifier bytes.
  for it in d.items:
    if it.key.equals(key):
      return some(it.value)
  none(Value)

proc has*(d: Descriptor, key: string): bool {.inline.} =
  d.get(key).isSome

proc getText*(d: Descriptor, key: string, default = ""): string =
  let v = d.get(key)
  if v.isNone:
    return default
  let val = v.get()
  if val.kind != vText:
    return default
  val.text.toString()

proc getInt*(d: Descriptor, key: string, default = 0'i32): int32 =
  let v = d.get(key)
  if v.isNone:
    return default
  let val = v.get()
  if val.kind != vInteger:
    return default
  val.integer

proc getBool*(d: Descriptor, key: string, default = false): bool =
  let v = d.get(key)
  if v.isNone:
    return default
  let val = v.get()
  if val.kind != vBoolean:
    return default
  val.boolean

proc getDouble*(d: Descriptor, key: string, default = 0.0): float64 =
  let v = d.get(key)
  if v.isNone:
    return default
  let val = v.get()
  if val.kind != vDouble:
    return default
  val.double

proc getDescriptor*(d: Descriptor, key: string): Option[Descriptor] =
  let v = d.get(key)
  if v.isNone:
    return none(Descriptor)
  let val = v.get()
  if val.kind == vDescriptor:
    return some(val.descriptor)
  if val.kind == vGlobalObject:
    return some(val.globalObject)
  none(Descriptor)

proc getDoubles*(d: Descriptor, key: string): seq[float64] =
  ## A `VlLs` of `doub`, or empty when absent or mistyped.
  let v = d.get(key)
  if v.isNone:
    return @[]
  let val = v.get()
  if val.kind != vList:
    return @[]
  for item in val.items:
    if item.kind != vDouble:
      return @[]
    result.add(item.double)

proc getUnitFloat*(d: Descriptor,
    key: string): Option[tuple[unit: string, value: float64]] =
  let v = d.get(key)
  if v.isNone:
    return none(tuple[unit: string, value: float64])
  let val = v.get()
  if val.kind != vUnitFloat:
    return none(tuple[unit: string, value: float64])
  var unit = newString(4)
  for i in 0 ..< 4:
    unit[i] = char(ord(val.floatUnit[i]))
  some((unit, val.floatUnitValue))

# --- reading ----------------------------------------------------------------

proc readUnicodeString*(r: var Reader): UnicodeString =
  let n = int64(r.readU32BE())
  if n < 0 or n > r.remaining.int64 div 2:
    eof(int(n * 2 - r.remaining), r.pos)
  var units = newSeq[uint16](int(n))
  for i in 0 ..< int(n):
    units[i] = r.readU16BE()
  UnicodeString(units: units)

proc readId*(r: var Reader): DescId =
  let n = int64(r.readU32BE())
  if n == 0:
    result = DescId(kind: idCode, code: r.readArray4())
  elif n > 0 and n <= 4096:
    result = DescId(kind: idStr, str: r.bytes(int(n)).clone)
  else:
    invalid("descriptor id length " & $n)

proc readClass*(r: var Reader): DescClass =
  DescClass(name: readUnicodeString(r), classId: readId(r))

proc readValue*(r: var Reader, typ: string, depth: int,
    limits: Limits): Value

proc readDescriptorBody*(r: var Reader, depth: int,
    limits: Limits): Descriptor =
  if depth > MaxDescriptorDepth:
    limitExceeded("descriptor nesting deeper than " & $MaxDescriptorDepth)
  result.name = readUnicodeString(r)
  result.classId = readId(r)
  let count = int64(r.readU32BE())
  limits.checkCount(count, r.remaining, MinDescriptorItemBytes,
    "descriptor item")
  var items: seq[DescItem] = @[]
  for _ in 0 ..< int(count):
    let key = readId(r)
    let typ = r.readStr4()
    items.add(DescItem(key: key, value: readValue(r, typ, depth + 1, limits)))
  result.items = items

proc readReference*(r: var Reader, depth: int,
    limits: Limits): ReferenceItem =
  let typ = r.readStr4()
  case typ
  of "prop":
    let cls = readClass(r)
    result = ReferenceItem(kind: riProperty, propClass: cls,
      propKey: readId(r))
  of "Clss":
    result = ReferenceItem(kind: riClass, clsClass: readClass(r))
  of "Enmr":
    let cls = readClass(r)
    let t = readId(r)
    let v = readId(r)
    result = ReferenceItem(kind: riEnumerated, enumClass: cls, typeId: t,
      valueId: v)
  of "rele":
    let cls = readClass(r)
    let off = r.readI32BE()
    result = ReferenceItem(kind: riOffset, offClass: cls, offset: off)
  of "Idnt":
    result = ReferenceItem(kind: riIdentifier, identifier: r.readU32BE())
  of "indx":
    result = ReferenceItem(kind: riIndex, index: r.readU32BE())
  of "name":
    let cls = readClass(r)
    let nm = readUnicodeString(r)
    result = ReferenceItem(kind: riName, nameClass: cls, name: nm)
  else:
    unsupported("descriptor reference item type '" & typ & "'")

proc readCounted*(r: var Reader, what: string, limits: Limits,
    minItem: int64): int =
  let n = int64(r.readU32BE())
  limits.checkCount(n, r.remaining, minItem, what)
  int(n)

proc readRaw*(r: var Reader): Span =
  let n = int64(r.readU32BE())
  if n < 0 or n > r.remaining:
    eof(int(n - r.remaining), r.pos)
  r.bytes(int(n))

proc readValue*(r: var Reader, typ: string, depth: int,
    limits: Limits): Value =
  if depth > MaxDescriptorDepth:
    limitExceeded("descriptor nesting deeper than " & $MaxDescriptorDepth)
  case typ
  of "obj ":
    let n = readCounted(r, "descriptor reference", limits, 8)
    var items: seq[ReferenceItem] = @[]
    for _ in 0 ..< n:
      items.add(readReference(r, depth, limits))
    result = referenceValue(items)
  of "Objc":
    result = descriptorValue(readDescriptorBody(r, depth, limits))
  of "GlbO":
    result = globalObjectValue(readDescriptorBody(r, depth, limits))
  of "VlLs":
    let n = readCounted(r, "descriptor list", limits, 4)
    var items: seq[Value] = @[]
    for _ in 0 ..< n:
      let et = r.readStr4()
      items.add(readValue(r, et, depth, limits))
    result = listValue(items)
  of "doub":
    result = doubleValue(r.readF64BE())
  of "UntF":
    let unit = r.readArray4()
    result = unitFloatValue("", 0.0)
    result.floatUnit = unit
    result.floatUnitValue = r.readF64BE()
  of "UnFl":
    let unit = r.readArray4()
    let n = readCounted(r, "unit-float list", limits, 8)
    var vals: seq[float64] = @[]
    for _ in 0 ..< n:
      vals.add(r.readF64BE())
    result = unitFloatsValue("", vals)
    result.floatsUnit = unit
  of "TEXT":
    # keep the units exactly as stored, including any trailing NUL, so the
    # value round-trips; `toString` is what drops NULs
    result = Value(kind: vText, text: readUnicodeString(r))
  of "enum":
    let t = readId(r)
    let v = readId(r)
    result = enumValue(t.asString(), v.asString())
  of "long":
    result = intValue(r.readI32BE())
  of "comp":
    result = longValue(r.readI64BE())
  of "bool":
    result = boolValue(r.readU8() != 0)
  of "type":
    result = Value(kind: vClass)
    result.valueClass = readClass(r)
  of "GlbC":
    result = Value(kind: vGlobalClass)
    result.globalClass = readClass(r)
  of "alis":
    result = Value(kind: vAlias, alias: readRaw(r))
  of "Pth ":
    result = Value(kind: vPath, path: readRaw(r))
  of "tdta":
    result = Value(kind: vRawData, rawData: readRaw(r))
  of "ObAr":
    # undocumented; read as a u32 prefix followed by a descriptor-shaped
    # body, following ag-psd
    let prefix = r.readU32BE()
    result = objectArrayValue(prefix, readDescriptorBody(r, depth, limits))
  else:
    unsupported("descriptor OSType '" & typ & "'")

# --- writing ----------------------------------------------------------------

proc writeUnicodeString*(w: var Writer, u: UnicodeString) =
  w.writeUnicodeUnits(u.units)

proc writeId*(w: var Writer, id: DescId) =
  case id.kind
  of idCode:
    w.putU32(0)
    w.putArray4(id.code)
  of idStr:
    w.putU32(uint32(id.str.len))
    w.put(id.str)

proc writeClass*(w: var Writer, c: DescClass) =
  w.writeUnicodeString(c.name)
  w.writeId(c.classId)

proc writeReference*(w: var Writer, item: ReferenceItem) =
  case item.kind
  of riProperty:
    w.putStr4("prop"); w.writeClass(item.propClass); w.writeId(item.propKey)
  of riClass:
    w.putStr4("Clss"); w.writeClass(item.clsClass)
  of riEnumerated:
    w.putStr4("Enmr"); w.writeClass(item.enumClass)
    w.writeId(item.typeId); w.writeId(item.valueId)
  of riOffset:
    w.putStr4("rele"); w.writeClass(item.offClass); w.putI32(item.offset)
  of riIdentifier:
    w.putStr4("Idnt"); w.putU32(item.identifier)
  of riIndex:
    w.putStr4("indx"); w.putU32(item.index)
  of riName:
    w.putStr4("name"); w.writeClass(item.nameClass)
    w.writeUnicodeString(item.name)

proc writeDescriptorBody*(w: var Writer, d: Descriptor,
    depth = 0)

proc writeValue*(w: var Writer, v: Value, depth = 0) =
  if depth > MaxDescriptorDepth:
    limitExceeded("descriptor nesting deeper than " & $MaxDescriptorDepth)
  case v.kind
  of vReference:
    w.putStr4("obj ")
    w.putU32(uint32(v.reference.len))
    for item in v.reference:
      writeReference(w, item)
  of vDescriptor:
    w.putStr4("Objc"); writeDescriptorBody(w, v.descriptor, depth + 1)
  of vGlobalObject:
    w.putStr4("GlbO"); writeDescriptorBody(w, v.globalObject, depth + 1)
  of vList:
    w.putStr4("VlLs")
    w.putU32(uint32(v.items.len))
    for item in v.items:
      writeValue(w, item, depth + 1)
  of vDouble:
    w.putStr4("doub"); w.putF64(v.double)
  of vUnitFloat:
    w.putStr4("UntF"); w.putArray4(v.floatUnit); w.putF64(v.floatUnitValue)
  of vUnitFloats:
    w.putStr4("UnFl")
    w.putArray4(v.floatsUnit)
    w.putU32(uint32(v.floatsUnitValues.len))
    for f in v.floatsUnitValues:
      w.putF64(f)
  of vText:
    w.putStr4("TEXT"); w.writeUnicodeString(v.text)
  of vEnumerated:
    w.putStr4("enum"); w.writeId(v.typeId); w.writeId(v.valueId)
  of vInteger:
    w.putStr4("long"); w.putI32(v.integer)
  of vLargeInteger:
    w.putStr4("comp"); w.putI64(v.large)
  of vBoolean:
    # normalised to 0 or 1
    w.putStr4("bool"); w.putU8(if v.boolean: 1'u8 else: 0'u8)
  of vClass:
    w.putStr4("type"); w.writeClass(v.valueClass)
  of vGlobalClass:
    w.putStr4("GlbC"); w.writeClass(v.globalClass)
  of vAlias:
    w.putStr4("alis"); w.putU32(uint32(v.alias.len)); w.put(v.alias)
  of vPath:
    w.putStr4("Pth "); w.putU32(uint32(v.path.len)); w.put(v.path)
  of vRawData:
    w.putStr4("tdta"); w.putU32(uint32(v.rawData.len)); w.put(v.rawData)
  of vObjectArray:
    w.putStr4("ObAr"); w.putU32(v.arrayPrefix)
    writeDescriptorBody(w, v.arrayBody, depth + 1)

proc writeDescriptorBody*(w: var Writer, d: Descriptor, depth = 0) =
  if depth > MaxDescriptorDepth:
    limitExceeded("descriptor nesting deeper than " & $MaxDescriptorDepth)
  w.writeUnicodeString(d.name)
  w.writeId(d.classId)
  w.putU32(uint32(d.items.len))
  for it in d.items:
    w.writeId(it.key)
    writeValue(w, it.value, depth + 1)

# --- entry points -----------------------------------------------------------

proc parseDescriptor*(data: string, limits = defaultLimits()): Descriptor =
  ## Parse a bare descriptor body with no version prefix. Trailing bytes are
  ## rejected so a mis-sized block is caught here.
  var r = initReader(data)
  result = readDescriptorBody(r, 0, limits)
  if not r.atEnd():
    invalid("descriptor has " & $r.remaining & " trailing bytes")

proc parsePrefixDescriptor*(data: Span, limits = defaultLimits()):
    tuple[descriptor: VersionedDescriptor, consumed: int] =
  ## Parse a versioned descriptor and report how many bytes it used, so the
  ## caller can continue with whatever follows.
  var r = initReader(data)
  let version = r.readU32BE()
  if version != DescriptorVersion:
    invalid("descriptor version " & $version & ", expected " &
      $DescriptorVersion)
  result.descriptor = VersionedDescriptor(version: version,
    descriptor: readDescriptorBody(r, 0, limits))
  # relative to the span, not to the source: callers compare it against the
  # span's own length, which is only zero-based when start is zero
  result.consumed = r.offset

proc parsePrefixDescriptor*(data: string,
    limits = defaultLimits()): tuple[descriptor: VersionedDescriptor, consumed: int] =
  ## The same over freshly written bytes, for round-tripping a descriptor we
  ## serialised ourselves.
  parsePrefixDescriptor(spanValue(data), limits)

proc parseVersionedDescriptor*(data: Span,
    limits = defaultLimits()): VersionedDescriptor =
  let p = parsePrefixDescriptor(data, limits)
  if p.consumed != data.len:
    invalid("versioned descriptor has " & $(data.len - p.consumed) &
      " trailing bytes")
  p.descriptor

proc parseVersionedDescriptor*(data: string,
    limits = defaultLimits()): VersionedDescriptor =
  ## The same over freshly written bytes, for round-tripping a descriptor we
  ## serialised ourselves.
  parseVersionedDescriptor(spanValue(data), limits)

proc toBytes*(d: Descriptor): string =
  var w = initWriter()
  writeDescriptorBody(w, d)
  w.toString()

proc toBytes*(vd: VersionedDescriptor): string =
  var w = initWriter()
  w.putU32(vd.version)
  writeDescriptorBody(w, vd.descriptor)
  w.toString()

proc fromBytes*(d: Descriptor, limits = defaultLimits()): Descriptor =
  parseDescriptor(toBytes(d), limits)

proc fromBytes*(vd: VersionedDescriptor,
    limits = defaultLimits()): VersionedDescriptor =
  parseVersionedDescriptor(toBytes(vd), limits)

proc newVersioned*(d: Descriptor): VersionedDescriptor {.inline.} =
  VersionedDescriptor(version: DescriptorVersion, descriptor: d)

# --- descriptor-bearing tagged blocks ---------------------------------------

const
  ## `lfx2`, `lrFX` and `lmfx` carry effects as "8BIM" + version + body, and
  ## `SoCo` and `vogk` carry theirs as a 4-byte content key + version + body.
  DescriptorPrefixLen* = 4
  ## `SoLd` and `SoLE` carry an extra version of their own before the
  ## descriptor, so their prefix is eight bytes.
  PlacedBlockPrefixLen* = 8

proc parseBlockDescriptor*(data: Span, prefixLen = DescriptorPrefixLen,
    limits = defaultLimits()): VersionedDescriptor =
  ## The descriptor embedded in a tagged block, after its leading signature
  ## or content key. Trailing bytes are tolerated: a block may carry more
  ## after its descriptor.
  if data.len < prefixLen + 4:
    invalid("block holds no descriptor (" & $data.len & " bytes)")
  parsePrefixDescriptor(data.slice(prefixLen, data.len), limits).descriptor

proc tryBlockDescriptor*(b: TaggedBlock,
    prefixLen = DescriptorPrefixLen,
    limits = defaultLimits()): Option[VersionedDescriptor] =
  ## The same, but `none` rather than an exception for a block that has no
  ## descriptor or whose descriptor we cannot model.
  try:
    some(parseBlockDescriptor(b.data, prefixLen, limits))
  except PsdError:
    none(VersionedDescriptor)

proc tryDescriptor*(data: Span, prefixLen = DescriptorPrefixLen,
    limits = defaultLimits()): Option[VersionedDescriptor] =
  ## `tryBlockDescriptor` without needing a `TaggedBlock` to hand.
  try:
    some(parseBlockDescriptor(data, prefixLen, limits))
  except PsdError:
    none(VersionedDescriptor)

proc parseDescriptorPrefix*(data: Span, limits = defaultLimits()):
    tuple[descriptor: Descriptor, consumed: int] =
  ## A bare descriptor body, reporting how many bytes it used. `TySh` needs
  ## this: its descriptor is followed by the warp data, which is not part of
  ## the descriptor.
  var r = initReader(data)
  result.descriptor = readDescriptorBody(r, 0, limits)
  result.consumed = r.offset

proc tryBareDescriptor*(data: Span,
    limits = defaultLimits()): Option[Descriptor] =
  ## A descriptor body with no version of its own. `TySh` is the case that
  ## needs this: its `u32` version field sits in the block header, so the
  ## bytes after it are a bare `TxLr` body. A trailing warp section is
  ## tolerated.
  try:
    some(parseDescriptorPrefix(data, limits).descriptor)
  except PsdError:
    none(Descriptor)
