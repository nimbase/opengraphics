## Photoshop 6+ Type-tool object (`TySh`) parsing.
##
## `tests/data/01.psd` carries two text layers whose engine data is
## preserved verbatim in `Layer.extraBlocks` (key `"TySh"`, 10344 and
## 12248 bytes). This module decodes that payload into usable text,
## fonts, sizes and transform without touching the preserved bytes.
##
## Layout (clean-room reimplementation, checked against the fixture;
## libpsd's `type_tool.c` only covers legacy PS 5 `tySh`, so the
## reference here is the on-disk structure plus the generic OSType
## descriptor grammar in libpsd's `descriptor.c`):
##
##   u16 version (=1)
##   6 x f64 transform (xx, xy, yx, yy, tx, ty)
##   u16 textVersion (=50)
##   u32 descriptorVersion (=16)
##   descriptor: TxLr header + TEXT string + style items + EngineData
##   warp descriptor + rects (preserved, exposed via `warpRaw`)
##
## The descriptor is parsed tolerantly: `TEXT` (UTF-16BE) and
## `EngineData` (`tdta`) are located by key scan so unknown items
## cannot break text extraction. Font names/sizes come from the
## ASCII `EngineData` markup (`/Name (...)`, `/FontSize <float>`).

import std/options
import std/strutils
import ./types
import ./reader
import ./layers

type
  TextEngine* = object
    ## Decoded view over one `TySh` payload. `raw` is the verbatim
    ## block bytes; everything else is best-effort extraction.
    raw*: seq[byte]
    version*: int
    transform*: array[6, float64]
    textVersion*: int
    text*: string          ## TEXT field (UTF-16BE), `\r` normalized to `\n`
    engineText*: string    ## `/Editor /Text (...)` from EngineData
    fontNames*: seq[string]
    fontSizes*: seq[float]
    engineData*: string    ## ASCII EngineData markup (may be empty)
    warpRaw*: seq[byte]    ## warp descriptor + rects, preserved opaquely
    hasText*: bool

proc appendUtf8(s: var string, cp: int) =
  if cp < 0x80:
    s.add(chr(cp))
  elif cp < 0x800:
    s.add(chr(0xC0 or (cp shr 6)))
    s.add(chr(0x80 or (cp and 0x3F)))
  elif cp < 0x10000:
    s.add(chr(0xE0 or (cp shr 12)))
    s.add(chr(0x80 or ((cp shr 6) and 0x3F)))
    s.add(chr(0x80 or (cp and 0x3F)))
  else:
    s.add(chr(0xF0 or (cp shr 18)))
    s.add(chr(0x80 or ((cp shr 12) and 0x3F)))
    s.add(chr(0x80 or ((cp shr 6) and 0x3F)))
    s.add(chr(0x80 or (cp and 0x3F)))

proc decodeUtf16Be(s: openArray[byte]): string =
  ## Decode UTF-16BE with optional BOM. Unpaired surrogates -> `?`.
  var i = 0
  if s.len >= 2 and s[0] == 0xFE and s[1] == 0xFF:
    i = 2
  result = ""
  while i + 1 < s.len:
    let c = (int(s[i]) shl 8) or int(s[i + 1])
    i += 2
    if c == 0:
      break
    if c >= 0xD800 and c <= 0xDBFF:
      if i + 1 < s.len:
        let lo = (int(s[i]) shl 8) or int(s[i + 1])
        if lo >= 0xDC00 and lo <= 0xDFFF:
          i += 2
          appendUtf8(result, 0x10000 + ((c - 0xD800) shl 10) + (lo - 0xDC00))
          continue
      result.add('?')
    elif c >= 0xDC00 and c <= 0xDFFF:
      result.add('?')
    else:
      appendUtf8(result, c)

proc normalizeReturns(s: string): string =
  result = s.replace("\r\n", "\n").replace("\r", "\n")

proc findBytes(hay: openArray[byte], needle: string, start = 0): int =
  if needle.len == 0 or hay.len < needle.len:
    return -1
  var i = start
  while i + needle.len <= hay.len:
    var ok = true
    for j in 0 ..< needle.len:
      if hay[i + j] != byte(needle[j]):
        ok = false
        break
    if ok:
      return i
    inc i
  -1

proc readU32BeAt(b: openArray[byte], pos: int): int =
  (int(b[pos]) shl 24) or (int(b[pos + 1]) shl 16) or
    (int(b[pos + 2]) shl 8) or int(b[pos + 3])

proc findBytes(hay: string, needle: string, start = 0): int =
  if needle.len == 0 or hay.len < needle.len:
    return -1
  var i = max(start, 0)
  while i + needle.len <= hay.len:
    if hay[i ..< i + needle.len] == needle:
      return i
    inc i
  -1

proc extractParen(data: string, openPos: int): seq[byte] =
  ## String overload for EngineData markup scanning.
  var depth = 0
  var i = openPos
  while i < data.len:
    let c = data[i]
    if c == '\\' and i + 1 < data.len:
      i += 2
      continue
    if c == '(':
      inc depth
    elif c == ')':
      dec depth
      if depth == 0:
        result = newSeq[byte](i - openPos - 1)
        for j in 0 ..< result.len:
          result[j] = byte(data[openPos + 1 + j])
        return
    inc i
  @[]

proc decodeParenString(raw: seq[byte]): string =
  if raw.len >= 2 and raw[0] == 0xFE and raw[1] == 0xFF:
    decodeUtf16Be(raw)
  else:
    var s = newString(raw.len)
    for i, b in raw:
      s[i] = char(b)
    s

proc extractTextField(data: seq[byte]): string =
  ## First `TEXT` OSType + u32 char count + UTF-16BE.
  let idx = findBytes(data, "TEXT")
  if idx < 0 or idx + 8 > data.len:
    return ""
  let n = readU32BeAt(data, idx + 4)
  if n <= 0 or n > 100_000:
    return ""
  let start = idx + 8
  if start + n * 2 > data.len:
    return ""
  normalizeReturns(decodeUtf16Be(data[start ..< start + n * 2]))

proc extractEngineData(data: seq[byte]): string =
  let idx = findBytes(data, "EngineData")
  if idx < 0:
    return ""
  # `EngineData` + `tdta` + u32 length
  let tdta = findBytes(data, "tdta", idx)
  if tdta < 0 or tdta + 8 > data.len:
    return ""
  let n = readU32BeAt(data, tdta + 4)
  if n <= 0 or tdta + 8 + n > data.len:
    return ""
  let raw = data[tdta + 8 ..< tdta + 8 + n]
  var s = newString(raw.len)
  for i, b in raw:
    s[i] = char(b)
  s

proc extractEditorText(engineData: string): string =
  let ed = findBytes(engineData, "/Text (")
  if ed < 0:
    return ""
  let openPos = ed + "/Text ".len
  let raw = extractParen(engineData, openPos)
  normalizeReturns(decodeParenString(raw))

proc extractFontNames(engineData: string): seq[string] =
  ## Every `/Name (...)` inside `/FontSet [...]` and elsewhere.
  ## HarfBuzz-side note: names are PostScript/family names
  ## (e.g. `ArialMT`, `MyriadPro-Regular`); map to a local font
  ## program before shaping.
  result = @[]
  var i = 0
  while true:
    let idx = findBytes(engineData, "/Name (", i)
    if idx < 0:
      break
    let openPos = idx + "/Name ".len
    let raw = extractParen(engineData, openPos)
    let name = decodeParenString(raw).strip()
    if name.len > 0 and name.len < 256:
      result.add(name)
    i = openPos + raw.len + 2

proc extractFontSizes(engineData: string): seq[float] =
  result = @[]
  var i = 0
  const key = "/FontSize "
  while true:
    let idx = engineData.find(key, i)
    if idx < 0:
      break
    var j = idx + key.len
    var num = ""
    while j < engineData.len and engineData[j] in {'0'..'9', '.', '-', '+', 'e', 'E'}:
      num.add(engineData[j])
      inc j
    try:
      result.add(parseFloat(num))
    except ValueError:
      discard
    i = j

proc parseTySh*(data: seq[byte]): TextEngine =
  ## Parse one `TySh` tagged-block payload. Raises `PsdError` when
  ## the fixed header is truncated; descriptor gaps degrade to
  ## `hasText == false` rather than raising.
  if data.len < 54:
    raise newException(PsdError, "short TySh block (" & $data.len & " bytes)")
  var r = initReader(data)
  let version = int(r.readU16BE())
  if version != 1:
    raise newException(PsdError, "unsupported TySh version " & $version)
  var t: array[6, float64]
  for i in 0 ..< 6:
    r.require(8)
    var bits: uint64 = 0
    for b in r.readBytes(8):
      bits = (bits shl 8) or uint64(b)
    t[i] = cast[float64](bits)
  let textVersion = int(r.readU16BE())
  let descVersion = int(r.readU32BE())
  if descVersion != 16:
    raise newException(PsdError, "unsupported TySh descriptor version " &
      $descVersion)
  let tail = r.readBytes(r.remaining())
  let text = extractTextField(tail)
  let engine = extractEngineData(tail)
  let editorText = if engine.len > 0: extractEditorText(engine) else: ""
  # warp descriptor follows the EngineData string: locate end of the
  # `tdta` payload and preserve the rest opaquely.
  var warp: seq[byte] = @[]
  let tdtaIdx = findBytes(tail, "tdta")
  if tdtaIdx >= 0 and tdtaIdx + 8 <= tail.len:
    let n = readU32BeAt(tail, tdtaIdx + 4)
    let endPos = tdtaIdx + 8 + n
    if endPos >= 0 and endPos <= tail.len:
      warp = tail[endPos .. ^1]
  result = TextEngine(raw: data, version: version, transform: t,
    textVersion: textVersion, text: text, engineText: editorText,
    fontNames: if engine.len > 0: extractFontNames(engine) else: @[],
    fontSizes: if engine.len > 0: extractFontSizes(engine) else: @[],
    engineData: engine, warpRaw: warp, hasText: text.len > 0 or
      editorText.len > 0)

proc findTySh*(blocks: openarray[TaggedBlock]): int =
  for i, b in blocks:
    if b.key == "TySh":
      return i
  -1

proc isTextLayer*(layer: Layer): bool =
  ## True when the layer carries a `TySh` engine-data block.
  findTySh(layer.extraBlocks) >= 0

proc layerText*(layer: Layer): Option[TextEngine] =
  ## Parsed `TySh` for a text layer, `none` for non-text layers.
  let idx = findTySh(layer.extraBlocks)
  if idx < 0:
    return none(TextEngine)
  some(parseTySh(layer.extraBlocks[idx].data))

proc displayText*(t: TextEngine): string =
  ## Best available string: EngineData editor text, else TEXT field.
  if t.engineText.len > 0: t.engineText else: t.text
