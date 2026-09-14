## File kind detection for .aep files.
##
## Detection is by container signature, never the extension: a project
## is `RIFX` with form `Egg!`. Expression language comes from
## `LIST ExEn` and XMP presence from trailing bytes past the root chunk.

import ./types
import ./rifx

type
  AepDetection* = object
    isAep*: bool
    formType*: string
    exprLang*: string
    hasXmp*: bool

proc detectAep*(data: openArray[byte],
    limits = defaultAepLimits()): AepDetection =
  let root = readRifxBytes(data, limits)
  if root.formType != AepForm:
    return AepDetection(isAep: false, formType: root.formType)
  var lang = ""
  for ex in rootListsByType(root, "ExEn"):
    for u in ex.childrenById("Utf8"):
      if u.data.len > 0:
        var s = newString(u.data.len)
        for i, b in u.data:
          s[i] = char(b)
        if s.len > 0 and s.len <= limits.maxNameBytes:
          lang = s
  AepDetection(isAep: true, formType: root.formType, exprLang: lang,
    hasXmp: root.xmpTail.len > 0)

proc detectAep*(data: string,
    limits = defaultAepLimits()): AepDetection =
  var buf = newSeq[byte](data.len)
  for i, c in data:
    buf[i] = byte(c)
  detectAep(buf, limits)

proc checkAep*(data: openArray[byte],
    limits = defaultAepLimits()): RifxRoot =
  ## Parse and reject non project files with a clear error.
  let root = readRifxBytes(data, limits)
  if root.formType != AepForm:
    raise newException(AepError,
      "not an After Effects project (form " & root.formType & ")")
  root
