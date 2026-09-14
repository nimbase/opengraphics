## Property value decoding (v4: statics, lhd3/ldat keyframes,
## orientation).
##
## A property is a `tdmn` match name followed by a `LIST tdbs` holding
## `tdb4` metadata plus `cdat` (static) or `LIST list` (animated,
## keyframes decoded per the tdb4 kind). Orientation instead pairs
## `tdmn` with `LIST otst` (a `LIST tdbs` static triplet plus a
## `LIST otky` of timeless `otda` triplets). Other complex properties
## (shapes, gradients, markers) nest their values under other list
## types and are skipped here: only a directly following `LIST tdbs`
## or `LIST otst` is decoded, so `Gide`/`LRdr` keyframe lists elsewhere
## in the file never reach the decoder.

import std/strutils
import ./types
import ./rifx
import ./reader
import ./items

export items

const
  GroupEnd* = "ADBE Group End"
  Tdb4MinLen* = 124
  Lhd3MinLen* = 52

type
  Tdb4Info* = object
    components*: int
    isStatic*: bool
    isPosition*: bool
    kind*: PropKind
    isAnimated*: bool

  Lhd3Info* = object
    count*: int
    itemSize*: int
    itemType*: int

proc parseTdb4*(data: openArray[byte],
    limits = defaultAepLimits()): Tdb4Info =
  ## Offsets from plans/aep-spec.md, validated against tests/data/01.aep.
  ## Longer chunks are tolerated (trailing bytes ignored).
  if data.len < Tdb4MinLen:
    raise newException(AepError,
      "truncated tdb4 (" & $data.len & " bytes, need " &
      $Tdb4MinLen & ")")
  let components = int(readU16BEAt(data, 2, "tdb4 components"))
  if components < 0 or components > limits.maxComponents:
    raise newException(AepError, "tdb4 components " & $components &
      " exceeds limit " & $limits.maxComponents)
  let attr: array[2, byte] = [data[4], data[5]]
  let typeFlags: array[4, byte] =
    [data[56], data[57], data[58], data[59]]
  let kind =
    if flagSet(typeFlags, 3, 3): PropVector
    elif flagSet(typeFlags, 3, 2): PropInteger
    elif flagSet(typeFlags, 3, 0): PropColor
    elif flagSet(typeFlags, 1, 0): PropNoValue
    else: PropUnknown
  Tdb4Info(components: components, isStatic: flagSet(attr, 1, 0),
    isPosition: flagSet(attr, 1, 3), kind: kind, isAnimated: data[68] == 1)

proc parseLhd3*(data: openArray[byte]): Lhd3Info =
  ## Count is u16 at 10, item size u16 at 18, item type u8 at 23.
  ## Longer chunks are tolerated (trailing bytes ignored).
  if data.len < Lhd3MinLen:
    raise newException(AepError,
      "truncated lhd3 (" & $data.len & " bytes, need " &
      $Lhd3MinLen & ")")
  Lhd3Info(count: int(readU16BEAt(data, 10, "lhd3 count")),
    itemSize: int(readU16BEAt(data, 18, "lhd3 item size")),
    itemType: int(data[23]))

proc easeFromU8*(v: uint8): KeyframeEase =
  case v
  of 1: EaseLinear
  of 2: EaseEase
  of 3: EaseHold
  else: EaseUnknown

proc readF64s(data: openArray[byte], at, n: int,
    what: string): seq[float64] =
  result = newSeq[float64](n)
  for i in 0 ..< n:
    result[i] = readF64BEAt(data, at + i * 8, what)

proc parseKeyframes*(node: RifxChunk, t: Tdb4Info,
    limits = defaultAepLimits()): seq[Keyframe] =
  ## Decode the lhd3/ldat keyframes of a LIST list for one property.
  ## Item layouts follow plans/aep-spec.md; the expected item size is
  ## checked against the lhd3 table (1D 0x30, 2D 0x58, 2D pos 0x68,
  ## 3D 0x80, color 0x98, no-value 0x40) so misaligned data fails
  ## loudly instead of decoding garbage.
  if node.id != ListId or node.listType != "list":
    raise newException(AepError, "parseKeyframes needs a LIST list")
  let hi = node.findFirst("lhd3")
  if hi < 0:
    raise newException(AepError, "LIST list without lhd3")
  let lh = parseLhd3(node.children[hi].data)
  if lh.count < 0 or lh.count > limits.maxKeyframes:
    raise newException(AepError, "keyframe count " & $lh.count &
      " exceeds limit " & $limits.maxKeyframes)
  if lh.count == 0:
    return @[]
  let di = node.findFirst("ldat")
  if di < 0:
    raise newException(AepError, "LIST list without ldat")
  let d = node.children[di].data
  if d.len != lh.count * lh.itemSize:
    raise newException(AepError, "ldat length " & $d.len &
      " != count " & $lh.count & " * item size " & $lh.itemSize)
  let n = t.components
  var want = 0
  case t.kind
  of PropVector:
    want = if t.isPosition: 56 + 24 * n else: 8 + 40 * n
  of PropColor:
    want = 152
  of PropNoValue:
    want = 64
  of PropInteger, PropUnknown:
    raise newException(AepError,
      "animated properties of this kind are not supported")
  if lh.itemSize != want:
    raise newException(AepError, "keyframe item size " & $lh.itemSize &
      " != expected " & $want & " for this property")
  result = newSeq[Keyframe](lh.count)
  for k in 0 ..< lh.count:
    let base = k * lh.itemSize
    let attr = d[base + 7]
    var kf = Keyframe(time: int(readU16BEAt(d, base + 1, "keyframe time")),
      ease: easeFromU8(d[base + 5]), labelColor: int(d[base + 6]),
      continuousBezier: (attr and 0x08) != 0,
      autoBezier: (attr and 0x10) != 0, roving: (attr and 0x20) != 0)
    case t.kind
    of PropVector:
      if t.isPosition:
        kf.inSpeed = readF64s(d, base + 24, 1, "keyframe in speed")
        kf.inInfluence = readF64s(d, base + 32, 1, "keyframe in influence")
        kf.outSpeed = readF64s(d, base + 40, 1, "keyframe out speed")
        kf.outInfluence = readF64s(d, base + 48, 1,
          "keyframe out influence")
        kf.values = readF64s(d, base + 56, n, "keyframe value")
        kf.tanIn = readF64s(d, base + 56 + 8 * n, n,
          "keyframe tan in")
        kf.tanOut = readF64s(d, base + 56 + 16 * n, n,
          "keyframe tan out")
      else:
        kf.values = readF64s(d, base + 8, n, "keyframe value")
        kf.inSpeed = readF64s(d, base + 8 + 8 * n, n,
          "keyframe in speed")
        kf.inInfluence = readF64s(d, base + 8 + 16 * n, n,
          "keyframe in influence")
        kf.outSpeed = readF64s(d, base + 8 + 24 * n, n,
          "keyframe out speed")
        kf.outInfluence = readF64s(d, base + 8 + 32 * n, n,
          "keyframe out influence")
    of PropColor:
      kf.inSpeed = readF64s(d, base + 24, 1, "keyframe in speed")
      kf.inInfluence = readF64s(d, base + 32, 1, "keyframe in influence")
      kf.outSpeed = readF64s(d, base + 40, 1, "keyframe out speed")
      kf.outInfluence = readF64s(d, base + 48, 1,
        "keyframe out influence")
      kf.values = readF64s(d, base + 56, 4, "keyframe value")
      kf.extra = readF64s(d, base + 88, 8, "keyframe extra")
    of PropNoValue:
      kf.inSpeed = readF64s(d, base + 24, 1, "keyframe in speed")
      kf.inInfluence = readF64s(d, base + 32, 1, "keyframe in influence")
      kf.outSpeed = readF64s(d, base + 40, 1, "keyframe out speed")
      kf.outInfluence = readF64s(d, base + 48, 1,
        "keyframe out influence")
    of PropInteger, PropUnknown:
      discard
    result[k] = kf

proc parseTdsnName*(data: openArray[byte],
    limits = defaultAepLimits()): string =
  ## tdsn payload embeds a Utf8 chunk. Anything else yields "".
  if data.len < 8:
    return ""
  var fourcc = ""
  for i in 0 ..< 4:
    fourcc.add(char(data[i]))
  if fourcc != "Utf8":
    return ""
  let n = int(readU32BEAt(data, 4, "tdsn utf8 size"))
  if 8 + n > data.len or n > limits.maxNameBytes:
    raise newException(AepError, "tdsn Utf8 overruns payload")
  var s = newString(n)
  for i in 0 ..< n:
    s[i] = char(data[8 + i])
  cleanName(s)

proc matchNameOf*(c: RifxChunk, limits = defaultAepLimits()): string =
  var s = newString(c.data.len)
  for i, b in c.data:
    s[i] = char(b)
  s = stripTrailingNul(s)
  if s.len > limits.maxNameBytes:
    s.setLen(limits.maxNameBytes)
  s

proc parseTdbs*(node: RifxChunk,
    limits = defaultAepLimits()): PropValue =
  if node.id != ListId or node.listType != "tdbs":
    raise newException(AepError, "parseTdbs needs a LIST tdbs")
  let bi = node.findFirst("tdb4")
  if bi < 0:
    raise newException(AepError, "tdbs without tdb4")
  let t = parseTdb4(node.children[bi].data, limits)
  result = PropValue(kind: t.kind, components: t.components,
    isAnimated: t.isAnimated, isPosition: t.isPosition)
  var hasList = false
  var listIdx = -1
  var minV, maxV = 0.0
  var haveMin, haveMax = false
  for idx, k in node.children:
    if k.id == ListId and k.listType == "list":
      hasList = true
      if listIdx < 0:
        listIdx = idx
    elif k.id == "tdsn" and result.displayName.len == 0:
      result.displayName = parseTdsnName(k.data, limits)
    elif k.id == "Utf8" and not result.hasExpression:
      var s = newString(k.data.len)
      for i, b in k.data:
        s[i] = char(b)
      result.expression = s
      result.hasExpression = true
    elif k.id == "tdum" and not haveMin:
      minV = readF64BEAt(k.data, 0, "tdum")
      haveMin = true
    elif k.id == "tduM" and not haveMax:
      maxV = readF64BEAt(k.data, 0, "tduM")
      haveMax = true
  if haveMin and haveMax:
    result.minVal = minV
    result.maxVal = maxV
    result.hasMinMax = true
  if hasList:
    result.isAnimated = true
  if result.isAnimated:
    if listIdx >= 0:
      result.keyframes = parseKeyframes(node.children[listIdx], t, limits)
    return
  case t.kind
  of PropNoValue, PropUnknown:
    discard
  of PropInteger:
    let pi = node.findFirst("tdpi")
    if pi >= 0:
      result.hasLayerRef = true
      result.layerIndex = int(readU32BEAt(node.children[pi].data, 0,
        "tdpi"))
    let ps = node.findFirst("tdps")
    if ps >= 0 and node.children[ps].data.len >= 4:
      var u = readU32BEAt(node.children[ps].data, 0, "tdps")
      result.layerSource = cast[int32](u)
    let li = node.findFirst("tdli")
    if li >= 0:
      result.hasMaskRef = true
      result.maskIndex = int(readU32BEAt(node.children[li].data, 0,
        "tdli"))
  of PropVector, PropColor:
    let ci = node.findFirst("cdat")
    if ci < 0:
      raise newException(AepError, "static property without cdat")
    let d = node.children[ci].data
    if d.len < t.components * 8:
      raise newException(AepError, "truncated cdat (" & $d.len &
        " bytes, need " & $(t.components * 8) & ")")
    result.values = newSeq[float64](t.components)
    for i in 0 ..< t.components:
      result.values[i] = readF64BEAt(d, i * 8, "cdat value")

proc groupProperties*(group: RifxChunk,
    limits = defaultAepLimits()): seq[PropInfo] =
  ## Direct tdmn -> LIST tdbs pairs of one tdgp. Matches leading to
  ## subgroups or effects are skipped. Stops at ADBE Group End.
  if group.id != ListId or group.listType != "tdgp":
    raise newException(AepError, "groupProperties needs a LIST tdgp")
  result = @[]
  var i = 0
  while i < group.children.len:
    let k = group.children[i]
    if k.id != "tdmn":
      inc i
      continue
    let name = matchNameOf(k, limits)
    if name == GroupEnd:
      break
    if i + 1 < group.children.len:
      let nxt = group.children[i + 1]
      if nxt.id == ListId and nxt.listType == "tdbs":
        if result.len >= limits.maxPropsPerGroup:
          raise newException(AepError,
            "property count exceeds limit " & $limits.maxPropsPerGroup)
        result.add(PropInfo(matchName: name,
          value: parseTdbs(nxt, limits)))
        inc i
    inc i

proc childGroups*(group: RifxChunk,
    limits = defaultAepLimits()): seq[tuple[name: string, node: RifxChunk]] =
  ## tdmn -> LIST tdgp pairs of one tdgp (named subgroups).
  if group.id != ListId or group.listType != "tdgp":
    raise newException(AepError, "childGroups needs a LIST tdgp")
  result = @[]
  var i = 0
  while i < group.children.len:
    let k = group.children[i]
    if k.id != "tdmn":
      inc i
      continue
    let name = matchNameOf(k, limits)
    if name == GroupEnd:
      break
    if i + 1 < group.children.len:
      let nxt = group.children[i + 1]
      if nxt.id == ListId and nxt.listType == "tdgp":
        result.add((name, nxt))
        inc i
    inc i

proc findGroup*(roots: openArray[RifxChunk], path: openArray[string],
    limits = defaultAepLimits()): RifxChunk =
  ## Walk named subgroups from any of the root tdgps.
  for r in roots:
    if r.id == ListId and r.listType == "tdgp" and path.len > 0:
      var node = r
      var ok = true
      for depth in 0 ..< path.len:
        var found = false
        for (n, sub) in childGroups(node, limits):
          if n == path[depth]:
            node = sub
            found = true
            break
        if not found:
          ok = false
          break
      if ok:
        return node
  raise newException(AepError,
    "property group not found: " & path.join(" / "))

proc getProp*(props: openArray[PropInfo], name: string): PropValue =
  for p in props:
    if p.matchName == name:
      return p.value
  raise newException(AepError, "property not found: " & name)

proc layerGroups*(layr: RifxChunk): seq[RifxChunk] =
  ## Top level tdgp groups of a Layr node.
  layr.listByType("tdgp")

proc collectGroups*(node: RifxChunk): seq[RifxChunk] =
  ## Every LIST tdgp under a node, document order, any depth.
  result = @[]
  if node.id == ListId and node.listType == "tdgp":
    result.add(node)
  for k in node.children:
    if k.id == ListId:
      for sub in collectGroups(k):
        result.add(sub)

proc readTriple(data: openArray[byte], what: string): array[3, float64] =
  if data.len < 24:
    raise newException(AepError, "truncated " & what & " (" &
      $data.len & " bytes, need 24)")
  [readF64BEAt(data, 0, what), readF64BEAt(data, 8, what),
    readF64BEAt(data, 16, what)]

proc parseOtst*(node: RifxChunk, matchName: string,
    limits = defaultAepLimits()): OrientationInfo =
  ## Decode a LIST otst: static triplet from the tdbs cdat, one frame
  ## triplet per otda in otky. Longer payloads tolerated, short ones
  ## raise. Offsets validated against tests/data/01.aep.
  if node.id != ListId or node.listType != "otst":
    raise newException(AepError, "parseOtst needs a LIST otst")
  let tdbs = node.listByType("tdbs")
  if tdbs.len == 0:
    raise newException(AepError, "otst without LIST tdbs")
  let t = tdbs[0]
  let ci = t.findFirst("cdat")
  if ci < 0:
    raise newException(AepError, "otst without cdat")
  result = OrientationInfo(matchName: matchName,
    staticValue: readTriple(t.children[ci].data, "otst cdat"))
  let si = t.findFirst("tdsn")
  if si >= 0:
    result.displayName = parseTdsnName(t.children[si].data, limits)
  for otky in node.listByType("otky"):
    for k in otky.children:
      if k.id != "otda":
        continue
      if result.frames.len >= limits.maxKeyframes:
        raise newException(AepError, "orientation frame count exceeds " &
          "limit " & $limits.maxKeyframes)
      result.frames.add(readTriple(k.data, "otda"))

proc orientationsIn*(group: RifxChunk,
    limits = defaultAepLimits()): seq[OrientationInfo] =
  ## Direct tdmn -> LIST otst pairs of one tdgp. Stops at Group End.
  if group.id != ListId or group.listType != "tdgp":
    raise newException(AepError, "orientationsIn needs a LIST tdgp")
  result = @[]
  var i = 0
  while i < group.children.len:
    let k = group.children[i]
    if k.id != "tdmn":
      inc i
      continue
    let name = matchNameOf(k, limits)
    if name == GroupEnd:
      break
    if i + 1 < group.children.len:
      let nxt = group.children[i + 1]
      if nxt.id == ListId and nxt.listType == "otst":
        result.add(parseOtst(nxt, name, limits))
        inc i
    inc i

proc matchNames*(group: RifxChunk,
    limits = defaultAepLimits()): seq[string] =
  ## Every tdmn in order up to ADBE Group End (names only).
  if group.id != ListId or group.listType != "tdgp":
    raise newException(AepError, "matchNames needs a LIST tdgp")
  result = @[]
  for k in group.children:
    if k.id != "tdmn":
      continue
    let s = matchNameOf(k, limits)
    result.add(s)
    if s == GroupEnd:
      break

proc hasMatch*(group: RifxChunk, name: string): bool =
  for m in matchNames(group):
    if m == name:
      return true
  false
