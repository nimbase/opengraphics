## Patterns: the global `Patt` / `Pat2` / `Pat3` tagged blocks (8-, 16- and
## 32-bit documents) and standalone `.pat` files.
##
## Layout per the public Photoshop File Formats Specification, "Patterns" and
## "Virtual Memory Array List":
##
## ```text
## pattern  := version u32 (1), image mode u32, height i16, width i16,
##             name (Unicode string), unique id (Pascal string, unpadded),
##             [indexed: 256 x RGB palette], virtual memory array list
## VMA list := version u32 (3), length u32, rect (top, left, bottom, right i32),
##             channel count u32, then count + 2 arrays (user mask, sheet mask)
## array    := written u32 (0 = absent), length u32 (0 = absent), depth u32, rect,
##             depth u16, compression u8 (0 raw, 1 PackBits RLE), data
## ```
##
## In a tagged block each pattern is prefixed by its u32 length and padded to 4
## bytes; a `.pat` file is `8BPT`, a u16 version (1), a u32 count, then the
## patterns with no length prefixes.
##
## Photoshop writes the channel count as 24 and only marks the real channels as
## written, so the first written arrays are taken as the colour channels and
## the next one as transparency.

import std/options
import std/strutils

import ./compression
import ./error
import ./header
import ./io

const
  MaxPatternEdge* = 30_000
    ## Largest pattern edge accepted. Photoshop's own limit is far lower; this
    ## is only here to bound allocation from a corrupt length field.
  MaxPatternChannels* = 64
  MaxPatternNameUnits* = 65_536
  MaxPatFilePatterns* = 100_000
  PatternSlots* = 24
    ## Channel slots Photoshop reserves in a virtual memory array list.
  PatternBlockKey8* = "Patt"
  PatternBlockKey16* = "Pat2"
  PatternBlockKey32* = "Pat3"

type
  PsdPattern* = object
    ## One pattern tile with planar, big-endian samples.
    mode*: uint32
      ## PSD colour mode number: 1 gray, 2 indexed, 3 RGB, 4 CMYK,
      ## 7 multichannel, 8 duotone, 9 Lab.
    width*: uint32
    height*: uint32
    name*: string   ## without a trailing NUL; built-ins look like
                   ## `$$$/Patterns/...=Water`
    id*: string     ## unique id, usually a UUID
    palette*: Option[string]
      ## Indexed-colour palette: 768 bytes of RGB triplets.
    depth*: uint16  ## bits per sample: 1, 8, 16 or 32
    channels*: seq[string]
      ## Decoded colour planes, `width * height` samples each.
    alpha*: Option[string]
      ## Decoded transparency plane, when present.

proc modeChannels*(mode: uint32): int {.inline.} =
  ## Colour channels implied by a PSD colour mode.
  case mode
  of 3, 9: 3
  of 4: 4
  else: 1

proc patternBlockKey*(depth: uint16): string {.inline.} =
  ## Tagged-block key for patterns of a document at `depth` bits.
  case depth
  of 16: PatternBlockKey16
  of 32: PatternBlockKey32
  else: PatternBlockKey8

proc patternKey*(p: PsdPattern): string {.inline.} =
  patternBlockKey(p.depth)

# --- virtual memory array list ---------------------------------------------

proc readPattern(r: var Reader, limits: Limits): PsdPattern =
  ## One pattern record, starting at its version field.
  let version = r.readU32BE()
  if version != 1:
    invalid("pattern version " & $version)
  let mode = r.readU32BE()
  let headerH = r.readI16BE()
  let headerW = r.readI16BE()
  if headerW <= 0 or headerH <= 0:
    invalid("pattern header dimensions " & $headerW & "x" & $headerH)

  # `readUnicodeUnits` consumes its own u32 count, so do not pre-read one.
  let nameUnits = r.readUnicodeUnits()
  if nameUnits.len > MaxPatternNameUnits:
    limitExceeded("pattern name length " & $nameUnits.len)
  result.name = unicodeToString(nameUnits)
  # The unique id is a Pascal string with no padding.
  let idLen = int(r.readU8())
  result.id = r.bytes(idLen).clone

  if mode == 2:
    result.palette = some(r.bytes(768).clone)
    # Some writers follow the palette with four extra bytes.
    let tail = r.peekRest()
    if tail.len >= 4:
      # The value is not one of the two Photoshop wrote, so it is the pad.
      let known = [0'u8, 0'u8, 0'u8, 3'u8]
      var matches = true
      for i in 0 ..< 4:
        if tail.byteAt(i) != known[i]:
          matches = false
      if not matches:
        r.skip(4)

  let vmaVersion = r.readU32BE()
  if vmaVersion != 3:
    invalid("virtual memory array list version " & $vmaVersion)
  let bodyLen = int64(r.readU32BE())
  limits.checkSection(bodyLen, "virtual memory array list")
  var v = r.sub(bodyLen)

  let top = v.readI32BE()
  let left = v.readI32BE()
  let bottom = v.readI32BE()
  let right = v.readI32BE()
  let w = uint32(max(right - left, 0))
  let h = uint32(max(bottom - top, 0))
  if w.int64 > MaxPatternEdge.int64 or h.int64 > MaxPatternEdge.int64:
    limitExceeded("pattern size " & $w & "x" & $h)
  limits.checkDimensions(int(w), int(h), "pattern")

  let count = int64(v.readU32BE())
  if count > MaxPatternChannels.int64:
    limitExceeded("pattern channel count " & $count)

  var planes: seq[string] = @[]
  for _ in 0 ..< count + 2:
    if v.atEnd:
      break
    # written == 0 or length == 0 means the slot is absent.
    if v.readU32BE() == 0:
      continue
    let arrayLen = int64(v.readU32BE())
    if arrayLen == 0:
      continue
    if arrayLen < 23:
      invalid("short virtual memory array")
    let depth32 = v.readU32BE()
    let ct = v.readI32BE()
    let cl = v.readI32BE()
    let cb = v.readI32BE()
    let cr = v.readI32BE()
    let depth16 = v.readU16BE()
    let comp = v.readU8()
    let data = v.bytes(int(arrayLen) - 23)
    # The u16 depth is authoritative when it is one we understand.
    var depth = uint16(depth32)
    if depth16 in [1'u16, 8'u16, 16'u16, 32'u16]:
      depth = depth16
    if depth notin [1'u16, 8'u16, 16'u16, 32'u16]:
      invalid("pattern depth " & $depth)
    result.depth = depth

    let cw = max(cr - cl, 0)
    let ch = max(cb - ct, 0)
    let layout = PlaneLayout(planes: 1, width: cw, height: ch, depth: int(depth),
      version: Version.Psd)
    let compression = case comp
      of 0'u8: Raw
      of 1'u8: Rle
      else: Compression(kind: cUnknown, raw: uint16(comp))
    let plane = decodePlanes(compression, data, layout)

    # A channel rect smaller than the pattern rect is placed into a full plane.
    let bpp = max(int(depth) div 8, 1)
    if depth == 1 or (cw == int(w) and ch == int(h)):
      planes.add(plane)
    else:
      var full = newString(int(w) * int(h) * bpp)
      for y in 0 ..< ch:
        let ty = int64(y) + int64(ct) - int64(top)
        if ty < 0 or ty >= int64(h):
          continue
        for x in 0 ..< cw:
          let tx = int64(x) + int64(cl) - int64(left)
          if tx < 0 or tx >= int64(w):
            continue
          let src = (y * cw + x) * bpp
          let dst = (int(ty) * int(w) + int(tx)) * bpp
          for k in 0 ..< bpp:
            full[dst + k] = plane[src + k]
      planes.add(full)

  let nc = modeChannels(mode)
  if planes.len < nc:
    invalid("pattern has fewer channels than its colour mode (" &
      $planes.len & " < " & $nc & ")")
  if planes.len > nc:
    result.alpha = some(planes[nc])
  result.mode = mode
  result.width = w
  result.height = h
  result.channels = planes[0 ..< nc]

proc writePattern*(w: var Writer, p: PsdPattern) =
  ## Inverse of `readPattern`. Always writes depth-8 tiles with PackBits and
  ## the wider depths raw, which is what Photoshop does.
  if p.width > MaxPatternEdge.uint32 or p.height > MaxPatternEdge.uint32 or
      p.width > int32(high(int16)).uint32 or
      p.height > int32(high(int16)).uint32:
    limitExceeded("pattern size " & $p.width & "x" & $p.height)
  w.putU32(1)
  w.putU32(p.mode)
  w.putI16(int16(p.height))
  w.putI16(int16(p.width))
  # Photoshop terminates the name with a NUL unit counted in the length;
  # `unicodeToString` strips it again on the way back in.
  var nameUnits = toUtf16Units(p.name)
  nameUnits.add(0'u16)
  w.writeUnicodeUnits(nameUnits)
  let idLen = min(p.id.len, 255)
  w.putU8(uint8(idLen))
  if idLen > 0:
    w.put(p.id[0 ..< idLen])
  if p.mode == 2:
    var pal = if p.palette.isSome: p.palette.get() else: ""
    if pal.len < 768:
      pal.add(repeat('\0', 768 - pal.len))
    elif pal.len > 768:
      pal.setLen(768)
    w.put(pal)

  let rect = [0'i32, 0'i32, int32(p.height), int32(p.width)]
  var body = initWriter()
  for v in rect:
    body.putI32(v)
  body.putU32(uint32(PatternSlots))
  let layout = PlaneLayout(planes: 1, width: int(p.width), height: int(p.height),
    depth: int(p.depth), version: Version.Psd)

  proc writeArray(body: var Writer, plane: string, rect: array[4, int32],
      depth: uint16) =
    let comp = if depth == 8: 1'u8 else: 0'u8
    let data = if depth == 8:
      encodePlanes(Rle, plane, layout)
    else:
      encodePlanes(Raw, plane, layout)
    body.putU32(1) # written
    body.putU32(uint32(23 + data.len))
    body.putU32(uint32(depth))
    for v in rect:
      body.putI32(v)
    body.putU16(depth)
    body.putU8(comp)
    body.put(data)

  let nc = min(p.channels.len, PatternSlots)
  for i in 0 ..< nc:
    writeArray(body, p.channels[i], rect, p.depth)
  # Unused colour slots are marked absent.
  for _ in nc ..< PatternSlots:
    body.putU32(0)
  # Slot 24 is the user mask (transparency), slot 25 the sheet mask.
  if p.alpha.isSome:
    writeArray(body, p.alpha.get(), rect, p.depth)
  else:
    body.putU32(0)
  body.putU32(0)

  let bodyStr = body.toString()
  w.putU32(3)
  w.putU32(uint32(bodyStr.len))
  w.put(bodyStr)

# --- tagged blocks and .pat files -------------------------------------------

proc parsePatternBlock*(data: Span,
    limits = defaultLimits()): seq[PsdPattern] =
  ## Parse the data of a `Patt` / `Pat2` / `Pat3` global block.
  var r = initReader(data)
  while r.remaining() >= 4:
    let n = int64(r.readU32BE())
    if n == 0:
      break
    limits.checkSection(n, "pattern")
    var body = r.sub(n)
    result.add(readPattern(body, limits))
    # Each pattern is padded to a 4-byte boundary.
    let pad = (4 - (n mod 4)) mod 4
    if pad > 0 and int64(r.remaining()) >= pad:
      r.skip(int(pad))

proc writePatternBlock*(patterns: openArray[PsdPattern]): string =
  ## Serialize patterns as `Patt` / `Pat2` / `Pat3` block data.
  var w = initWriter()
  for p in patterns:
    var one = initWriter()
    writePattern(one, p)
    let str = one.toString()
    w.putU32(uint32(str.len))
    w.put(str)
    let pad = (4 - (str.len mod 4)) mod 4
    for _ in 0 ..< pad:
      w.putU8(0)
  w.toString()

proc parsePatFile*(data: string, limits = defaultLimits()): seq[PsdPattern] =
  ## Parse a `.pat` pattern file.
  var r = initReader(data)
  let sig = r.readStr4()
  if sig != "8BPT":
    badSignature("8BPT", sig, 0)
  discard r.readU16BE()
  let count = int64(r.readU32BE())
  if count > MaxPatFilePatterns.int64:
    limitExceeded("pattern file count " & $count)
  limits.checkCount(count, r.remaining.int64, 1'i64, "patterns")
  result = newSeq[PsdPattern](int(count))
  for i in 0 ..< int(count):
    result[i] = readPattern(r, limits)

proc writePatFile*(patterns: openArray[PsdPattern]): string =
  ## Write a `.pat` pattern file.
  var w = initWriter()
  w.putStr4("8BPT")
  w.putU16(1'u16)
  w.putU32(uint32(patterns.len))
  for p in patterns:
    writePattern(w, p)
  w.toString()

proc parsePatternBlock*(data: string,
    limits = defaultLimits()): seq[PsdPattern] =
  parsePatternBlock(toSpan(data), limits)
