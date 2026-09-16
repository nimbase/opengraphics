## Vector shape data: path records (`vsms`/`vmsk`) and fill content
## (`vscg`, e.g. a `SoCo` solid color).
##
## `tests/data/01.psd` layer 0 ("Rectangle 1") is a shape layer: its
## `vsms` block holds 7 path records (fill rule, initial fill, one
## closed 4-knot subpath) plus 2 trailing bytes, and `vscg` holds the
## `SoCo` fill descriptor. Both payloads stay preserved verbatim in
## `Layer.extraBlocks`; this module decodes usable geometry and color.
##
## Layout (clean-room reimplementation; structure checked against
## libpsd `src/path.c` `psd_get_path_record` / `psd_get_layer_vector_mask`
## for the record selectors and 8.24 fixed-point knots, and
## `src/solid_color.c` + `src/descriptor.c`
## `psd_stream_get_object_color` for the `SoCo` `RGBC` doubles):
##
##   vsms/vmsk: u32 version, u32 flags, then 26-byte path records:
##     selector 0/3: subpath length (u16 knot count, closed/open)
##     selector 1/2/4/5: bezier knot, linked when 1 or 4
##       (6 x s32 8.24 fixed: preceding vert/horiz, anchor vert/horiz,
##       leaving vert/horiz, document-normalized 0..1)
##     selector 6: fill rule (24 bytes ignored)
##     selector 7: clipboard (4 x 8.24 bounds + 8.24 resolution + 4 ignored)
##     selector 8: initial fill (u16 + 22 bytes ignored)
##     other selectors: 24 bytes skipped (forward-compatible)
##   vscg: 4-char content kind + kind payload. `SoCo` = u32 version
##     (16) + descriptor whose `Clr `/`Objc`/`RGBC` triple carries the
##     `Rd  `/`Grn `/`Bl  ` doubles (0..255). Other kinds (gradient,
##     pattern) are exposed as unknown with raw preserved.
##
## Deliberate v1 limits: no rasterization (vector-mask clipping in the
## renderer stays deferred), `vogk`/`vstk`/`vowv`/`shmd` descriptor
## blobs stay raw-only.

import std/options
import ./types
import ./reader
import ./layers

type
  PathKnot* = object
    ## One bezier knot. Coordinates are document-normalized (0..1);
    ## multiply by the document size for pixels.
    prevVert*, prevHoriz*: float64 ## control point of incoming segment
    anchorVert*, anchorHoriz*: float64
    nextVert*, nextHoriz*: float64 ## control point of outgoing segment
    linked*: bool

  SubPath* = object
    closed*: bool
    knots*: seq[PathKnot]

  Clipboard* = object
    top*, left*, bottom*, right*: float64
    resolution*: float64

  VectorMask* = object
    raw*: seq[byte]
    version*: int
    flags*: uint32
    initialFill*: int ## -1 when no selector-8 record was present
    clipboard*: Clipboard
    hasClipboard*: bool
    subpaths*: seq[SubPath]
    trailingRaw*: seq[byte] ## sub-26-byte tail (fixture has 2 bytes)

  FillKind* {.pure.} = enum
    SolidColor = 0
    Unknown = 1

  FillContent* = object
    raw*: seq[byte]
    kind*: FillKind
    kindKey*: string ## 4-char content tag (`SoCo`, `GrFl`, ...)
    red*, green*, blue*: float64 ## solid color, 0..255

proc fixed824ToFloat*(v: int32): float64 {.inline.} =
  float64(v) / 16777216.0

proc parseVectorMask*(data: seq[byte]): VectorMask =
  ## Parse one `vsms`/`vmsk` payload. Raises `PsdError` on truncation
  ## or a short knot run; unknown selectors are skipped.
  if data.len < 8:
    raise newException(PsdError, "short vector mask (" & $data.len &
      " bytes, need >= 8)")
  var r = initReader(data)
  let version = int(r.readU32BE())
  let flags = r.readU32BE()
  result = VectorMask(raw: data, version: version, flags: flags,
    initialFill: -1)
  var current = -1
  var expected = 0
  while r.remaining() >= 26:
    let sel = int(r.readU16BE())
    case sel
    of 0, 3:
      if current >= 0 and result.subpaths[current].knots.len != expected:
        raise newException(PsdError, "subpath knot count " &
          $result.subpaths[current].knots.len & " != declared " & $expected)
      let n = int(r.readU16BE())
      if n < 0 or n > 10_000:
        raise newException(PsdError, "implausible subpath knot count " & $n)
      result.subpaths.add(SubPath(closed: sel == 0, knots: @[]))
      current = result.subpaths.len - 1
      expected = n
      r.skip(22)
    of 1, 2, 4, 5:
      if current < 0:
        raise newException(PsdError, "bezier knot without subpath")
      let pv = fixed824ToFloat(r.readI32BE())
      let ph = fixed824ToFloat(r.readI32BE())
      let av = fixed824ToFloat(r.readI32BE())
      let ah = fixed824ToFloat(r.readI32BE())
      let nv = fixed824ToFloat(r.readI32BE())
      let nh = fixed824ToFloat(r.readI32BE())
      result.subpaths[current].knots.add(PathKnot(prevVert: pv,
        prevHoriz: ph, anchorVert: av, anchorHoriz: ah, nextVert: nv,
        nextHoriz: nh, linked: sel == 1 or sel == 4))
    of 6:
      r.skip(24) # fill rule record, content unused
    of 7:
      let t = fixed824ToFloat(r.readI32BE())
      let l = fixed824ToFloat(r.readI32BE())
      let b = fixed824ToFloat(r.readI32BE())
      let ri = fixed824ToFloat(r.readI32BE())
      let res = fixed824ToFloat(r.readI32BE())
      r.skip(4)
      result.clipboard = Clipboard(top: t, left: l, bottom: b, right: ri,
        resolution: res)
      result.hasClipboard = true
    of 8:
      result.initialFill = int(r.readU16BE())
      r.skip(22)
    else:
      r.skip(24) # future selector: records stay 26 bytes, keep aligned
  if current >= 0 and result.subpaths[current].knots.len != expected:
    raise newException(PsdError, "subpath knot count " &
      $result.subpaths[current].knots.len & " != declared " & $expected)
  if r.remaining() > 0:
    result.trailingRaw = r.readBytes(r.remaining())

proc subpathKnotCount*(data: seq[byte]): int =
  ## Knot total across subpaths; convenience for tests and callers.
  let vm = parseVectorMask(data)
  for s in vm.subpaths:
    result += s.knots.len

proc readF64BE(r: var BinReader): float64 =
  var bits: uint64 = 0
  for b in r.readBytes(8):
    bits = (bits shl 8) or uint64(b)
  cast[float64](bits)

proc parseFillContent*(data: seq[byte]): FillContent =
  ## Parse one `vscg` payload. `SoCo` decodes to RGB doubles; any
  ## other content tag returns `Unknown` with raw preserved.
  if data.len < 4:
    raise newException(PsdError, "short fill content (" & $data.len &
      " bytes)")
  let kindKey = cast[string](@[char(data[0]), char(data[1]),
    char(data[2]), char(data[3])])
  if kindKey != "SoCo":
    return FillContent(raw: data, kind: Unknown, kindKey: kindKey)
  if data.len < 8:
    raise newException(PsdError, "short SoCo header")
  var r = initReader(data[4 .. ^1])
  let version = int(r.readU32BE())
  if version != 16:
    raise newException(PsdError, "unsupported SoCo version " & $version)
  # Descriptor scan (tolerant like TySh): locate `RGBC`, then read the
  # Rd/Grn/Bl (key, `doub`, f64) triples in order.
  let tail = r.readBytes(r.remaining())
  var pos = -1
  for i in 0 ..< tail.len - 3:
    if tail[i] == byte('R') and tail[i + 1] == byte('G') and
        tail[i + 2] == byte('B') and tail[i + 3] == byte('C'):
      pos = i + 4
      break
  if pos < 0:
    raise newException(PsdError, "SoCo without RGBC color object")
  var br = initReader(tail[pos .. ^1])
  let nColors = int(br.readU32BE())
  if nColors != 3:
    raise newException(PsdError, "SoCo wants 3 colors, got " & $nColors)
  var comps: array[3, float64]
  const wantKeys = ["Rd  ", "Grn ", "Bl  "]
  for ci in 0 ..< 3:
    let keyLen = int(br.readU32BE())
    var key: string
    if keyLen == 0:
      key = br.readStr(4)
    else:
      if keyLen > 256:
        raise newException(PsdError, "SoCo key too long")
      var raw = br.readBytes(keyLen * 2)
      key = ""
      var k = 0
      while k + 1 < raw.len:
        let c = (int(raw[k]) shl 8) or int(raw[k + 1])
        if c == 0 or c > 127:
          break
        key.add(char(c))
        k += 2
    if key != wantKeys[ci]:
      raise newException(PsdError, "SoCo wants '" & wantKeys[ci] &
        "', got '" & key & "'")
    if br.readStr(4) != "doub":
      raise newException(PsdError, "SoCo '" & key & "' is not a double")
    comps[ci] = readF64BE(br)
  result = FillContent(raw: data, kind: SolidColor, kindKey: "SoCo",
    red: comps[0], green: comps[1], blue: comps[2])

proc vectorMask*(layer: Layer): Option[VectorMask] =
  ## Parsed `vsms` (or `vmsk`) path data, `none` when absent.
  var idx = findBlock(layer.extraBlocks, "vsms")
  if idx < 0:
    idx = findBlock(layer.extraBlocks, "vmsk")
  if idx < 0:
    return none(VectorMask)
  some(parseVectorMask(layer.extraBlocks[idx].data))

proc hasVectorMask*(layer: Layer): bool {.inline.} =
  findBlock(layer.extraBlocks, "vsms") >= 0 or
    findBlock(layer.extraBlocks, "vmsk") >= 0

proc fillContent*(layer: Layer): Option[FillContent] =
  ## Parsed `vscg` fill content, `none` when absent.
  let idx = findBlock(layer.extraBlocks, "vscg")
  if idx < 0:
    return none(FillContent)
  some(parseFillContent(layer.extraBlocks[idx].data))

proc hasFillContent*(layer: Layer): bool {.inline.} =
  findBlock(layer.extraBlocks, "vscg") >= 0
