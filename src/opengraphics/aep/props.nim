## Property value decoding (v2: static values, names only for the rest).
##
## A property is a `tdmn` match name followed by a `LIST tdbs` holding
## `tdb4` metadata plus `cdat` (static) or `LIST list` (animated,
## keyframes are v3). Complex properties (orientation, shapes,
## gradients, markers) nest their values under other list types and are
## skipped here: only a directly following `LIST tdbs` is decoded.

import std/strutils
import ./types
import ./rifx
import ./reader
import ./items

export items

const
  GroupEnd* = "ADBE Group End"
  Tdb4MinLen* = 124

type
  Tdb4Info* = object
    components*: int
    isStatic*: bool
    isPosition*: bool
    kind*: PropKind
    isAnimated*: bool

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
  var minV, maxV = 0.0
  var haveMin, haveMax = false
  for k in node.children:
    if k.id == ListId and k.listType == "list":
      hasList = true
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
