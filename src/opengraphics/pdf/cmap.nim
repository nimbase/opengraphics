## Character maps and encodings (ISO 32000 §9.7, §9.6.6, Annex D).
##
## Byte tables for WinAnsi and MacRoman generated from Python's
## authoritative codecs (undefined entries are -1). ToUnicode CMaps
## parse bfchar/bfrange sections; destinations decode as UTF-16BE with
## surrogate support, so ligatures mapping to several scalars work.
## Glyph names resolve through a small common table plus uniXXXX and
## uXXXXXX patterns; anything else is unmapped (-1) rather than a
## guess, since a wrong character is worse than U+FFFD.

import std/strutils
import std/tables
import ./types
import ./lexer

const winAnsiTable*: array[256, int] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
  32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
  48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
  64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
  80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
  96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
  112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127,
  8364, -1, 8218, 402, 8222, 8230, 8224, 8225, 710, 8240, 352, 8249, 338, -1, 381, -1,
  -1, 8216, 8217, 8220, 8221, 8226, 8211, 8212, 732, 8482, 353, 8250, 339, -1, 382, 376,
  160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175,
  176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191,
  192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207,
  208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223,
  224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239,
  240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255,
]

const macRomanTable*: array[256, int] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
  32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
  48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
  64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
  80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
  96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
  112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127,
  196, 197, 199, 201, 209, 214, 220, 225, 224, 226, 228, 227, 229, 231, 233, 232,
  234, 235, 237, 236, 238, 239, 241, 243, 242, 244, 246, 245, 250, 249, 251, 252,
  8224, 176, 162, 163, 167, 8226, 182, 223, 174, 169, 8482, 180, 168, 8800, 198, 216,
  8734, 177, 8804, 8805, 165, 181, 8706, 8721, 8719, 960, 8747, 170, 186, 937, 230, 248,
  191, 161, 172, 8730, 402, 8776, 8710, 171, 187, 8230, 160, 192, 195, 213, 338, 339,
  8211, 8212, 8220, 8221, 8216, 8217, 247, 9674, 255, 376, 8260, 8364, 8249, 8250, 64257, 64258,
  8225, 183, 8218, 8222, 8240, 194, 202, 193, 203, 200, 205, 206, 207, 204, 211, 212,
  63743, 210, 218, 219, 217, 305, 710, 732, 175, 728, 729, 730, 184, 733, 731, 711,
]

type
  CMap* = object
    entries*: Table[int, string] ## source code -> UTF-8 text
    maxKeyLen*: int ## longest source code in bytes (1..4)

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: pdfFail("bad hex digit in CMap <" & $c & ">")

proc cmapHex(s: string): seq[byte] =
  ## Hex inside angle brackets, whitespace-tolerant.
  var hi = -1
  for c in s:
    if c in {' ', '\x09', '\x0A', '\x0C', '\x0D'}:
      continue
    let v = hexVal(c)
    if hi < 0:
      hi = v
    else:
      result.add(byte(hi * 16 + v))
      hi = -1
  if hi >= 0:
    result.add(byte(hi * 16))

proc utf16be(s: seq[byte]): string =
  ## Decode UTF-16BE with surrogate pairs into UTF-8.
  var i = 0
  while i + 1 < s.len:
    var cp = int(s[i]) * 256 + int(s[i + 1])
    i += 2
    if cp >= 0xD800 and cp <= 0xDBFF and i + 1 < s.len:
      let lo = int(s[i]) * 256 + int(s[i + 1])
      if lo >= 0xDC00 and lo <= 0xDFFF:
        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
        i += 2
    if cp < 0x80:
      result.add(char(cp))
    elif cp < 0x800:
      result.add(char(0xC0 or (cp shr 6)))
      result.add(char(0x80 or (cp and 0x3F)))
    elif cp < 0x10000:
      result.add(char(0xE0 or (cp shr 12)))
      result.add(char(0x80 or ((cp shr 6) and 0x3F)))
      result.add(char(0x80 or (cp and 0x3F)))
    else:
      result.add(char(0xF0 or (cp shr 18)))
      result.add(char(0x80 or ((cp shr 12) and 0x3F)))
      result.add(char(0x80 or ((cp shr 6) and 0x3F)))
      result.add(char(0x80 or (cp and 0x3F)))

proc codeInt(b: seq[byte]): int =
  for x in b:
    result = result * 256 + int(x)

proc splitTokens(line: string): seq[string] =
  ## Split a CMap content line into <hex>, [arrays] and bare words.
  var i = 0
  while i < line.len:
    if line[i] in {' ', '\x09', '\x0A', '\x0C', '\x0D'}:
      inc i
    elif line[i] == '<':
      var t = "<"
      inc i
      while i < line.len and line[i] != '>':
        t.add(line[i])
        inc i
      if i < line.len:
        t.add('>')
        inc i
      result.add(t)
    elif line[i] == '[':
      var t = "["
      inc i
      while i < line.len and line[i] != ']':
        if line[i] == '<':
          t.add('<')
          inc i
          while i < line.len and line[i] != '>':
            t.add(line[i])
            inc i
          if i < line.len:
            t.add('>')
            inc i
        else:
          t.add(line[i])
          inc i
      if i < line.len:
        t.add(']')
        inc i
      result.add(t)
    else:
      var t = ""
      while i < line.len and line[i] notin
          {' ', '\x09', '\x0A', '\x0C', '\x0D', '<', '[', '%'}:
        t.add(line[i])
        inc i
      if t.len > 0:
        result.add(t)

proc parseToUnicode*(data: string,
    limits = defaultPdfLimits()): CMap =
  ## Parse a /ToUnicode CMap stream (already filter-decoded).
  ## Understands bfchar and bfrange (single and array destinations).
  result = CMap(entries: initTable[int, string](), maxKeyLen: 1)
  var mode = 0 # 0 top, 1 bfchar, 2 bfrange
  for rawLine in data.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line[0] == '%':
      continue
    if "beginbfchar" in line:
      mode = 1
      continue
    if "beginbfrange" in line:
      mode = 2
      continue
    if "endbfchar" in line or "endbfrange" in line:
      mode = 0
      continue
    if mode == 0:
      continue
    let toks = splitTokens(line)
    if mode == 1 and toks.len >= 2 and toks[0][0] == '<' and
        toks[1][0] == '<':
      let src = cmapHex(toks[0][1 .. ^2])
      result.entries[codeInt(src)] = utf16be(cmapHex(toks[1][1 .. ^2]))
      result.maxKeyLen = max(result.maxKeyLen, src.len)
    elif mode == 2 and toks.len >= 3 and toks[0][0] == '<' and
        toks[1][0] == '<':
      let lo = cmapHex(toks[0][1 .. ^2])
      let hi = cmapHex(toks[1][1 .. ^2])
      result.maxKeyLen = max(result.maxKeyLen, max(lo.len, hi.len))
      if toks[2][0] == '[':
        let dsts = splitTokens(toks[2][1 .. ^2])
        var k = codeInt(lo)
        for d in dsts:
          if d.len >= 2 and d[0] == '<':
            result.entries[k] = utf16be(cmapHex(d[1 .. ^2]))
          inc k
          if k > codeInt(hi):
            break
      elif toks[2][0] == '<':
        let base = cmapHex(toks[2][1 .. ^2])
        if base.len == 0:
          pdfFail("bad bfrange destination in ToUnicode CMap")
        var v = codeInt(base)
        var k = codeInt(lo)
        while k <= codeInt(hi):
          var enc = newSeq[byte](base.len)
          var t = v
          for j in countdown(base.len - 1, 0):
            enc[j] = byte(t and 0xFF)
            t = t shr 8
          result.entries[k] = utf16be(enc)
          inc k
          inc v
    if result.entries.len > limits.maxObjects:
      pdfFail("ToUnicode CMap exceeds limit " & $limits.maxObjects &
        " entries")

proc glyphNameToUnicode*(name: string): int =
  ## Common Adobe glyph names plus uniXXXX/uXXXXXX. -1 when unknown.
  case name
  of "space": 32
  of "exclam": 33
  of "quotedbl": 34
  of "numbersign": 35
  of "dollar": 36
  of "percent": 37
  of "ampersand": 38
  of "quotesingle": 39
  of "parenleft": 40
  of "parenright": 41
  of "asterisk": 42
  of "plus": 43
  of "comma": 44
  of "hyphen", "minus": 45
  of "period": 46
  of "slash": 47
  of "zero": 48
  of "one": 49
  of "two": 50
  of "three": 51
  of "four": 52
  of "five": 53
  of "six": 54
  of "seven": 55
  of "eight": 56
  of "nine": 57
  of "colon": 58
  of "semicolon": 59
  of "less": 60
  of "equal": 61
  of "greater": 62
  of "question": 63
  of "at": 64
  of "bracketleft": 91
  of "backslash": 92
  of "bracketright": 93
  of "asciicircum": 94
  of "underscore": 95
  of "grave": 96
  of "braceleft": 123
  of "bar": 124
  of "braceright": 125
  of "asciitilde": 126
  of "quotedblleft": 8220
  of "quotedblright": 8221
  of "quoteleft": 8216
  of "quoteright": 8217
  of "endash": 8211
  of "emdash": 8212
  of "bullet": 8226
  of "ellipsis": 8230
  of "fi": 64257
  of "fl": 64258
  of "ff": 64256
  of "ffi": 64259
  of "ffl": 64260
  of "Agrave": 192
  of "Aacute": 193
  of "Acircumflex": 194
  of "Atilde": 195
  of "Adieresis": 196
  of "Aring": 197
  of "AE": 198
  of "Ccedilla": 199
  of "Egrave": 200
  of "Eacute": 201
  of "Ecircumflex": 202
  of "Edieresis": 203
  of "Igrave": 204
  of "Iacute": 205
  of "Icircumflex": 206
  of "Idieresis": 207
  of "Eth": 208
  of "Ntilde": 209
  of "Ograve": 210
  of "Oacute": 211
  of "Ocircumflex": 212
  of "Otilde": 213
  of "Odieresis": 214
  of "multiply": 215
  of "Oslash": 216
  of "Ugrave": 217
  of "Uacute": 218
  of "Ucircumflex": 219
  of "Udieresis": 220
  of "Yacute": 221
  of "Thorn": 222
  of "germandbls": 223
  of "agrave": 224
  of "aacute": 225
  of "acircumflex": 226
  of "atilde": 227
  of "adieresis": 228
  of "aring": 229
  of "ae": 230
  of "ccedilla": 231
  of "egrave": 232
  of "eacute": 233
  of "ecircumflex": 234
  of "edieresis": 235
  of "igrave": 236
  of "iacute": 237
  of "icircumflex": 238
  of "idieresis": 239
  of "eth": 240
  of "ntilde": 241
  of "ograve": 242
  of "oacute": 243
  of "ocircumflex": 244
  of "otilde": 245
  of "odieresis": 246
  of "divide": 247
  of "oslash": 248
  of "ugrave": 249
  of "uacute": 250
  of "ucircumflex": 251
  of "udieresis": 252
  of "yacute": 253
  of "thorn": 254
  of "ydieresis": 255
  of "dagger": 8224
  of "daggerdbl": 8225
  of "perthousand": 8240
  of "Scaron": 352
  of "scaron": 353
  of "OE": 338
  of "oe": 339
  of "Zcaron": 381
  of "zcaron": 382
  of "Ydieresis": 376
  of "guilsinglleft": 8249
  of "guilsingleright": 8250
  of "quotesinglbase": 8218
  of "quotedblbase": 8222
  of "trademark": 8482
  of "Euro": 8364
  of "dotlessi": 305
  else:
    if name.len == 7 and name[0 ..< 3] == "uni":
      try:
        return parseHexInt(name[3 .. ^1])
      except ValueError:
        return -1
    if name.len > 1 and name[0] == 'u':
      try:
        return parseHexInt(name[1 .. ^1])
      except ValueError:
        return -1
    if name.len == 1:
      return ord(name[0])
    -1
