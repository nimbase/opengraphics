## Path records: the bezier geometry in a `vmsk` / `vsms` vector mask, in a
## shape layer's `vogk` origination data, and in the saved-path image
## resources (1025 for the work path, 2000-2997 for saved ones).
##
## A path is a flat run of 26-byte records: a two-byte selector followed by 24
## bytes. The selector says how to read those 24 bytes.
##
## Knots are stored as 8.24 fixed-point fractions of the document size, three
## point pairs per knot (the incoming control point, the anchor, and the
## outgoing one), vertical before horizontal in each pair. To get pixels,
## multiply by the document height and width respectively.
##
## Records are kept raw as well as interpreted: an unrecognised selector is
## preserved so a future version's data still round-trips.

import std/math
import std/options

import ./error
import ./file
import ./io
import ./resources

const
  ## Selector plus payload.
  PathRecordLen* = 26
  MaxPathRecords* = 4_000_000
  FixedPointScale* = 16_777_216.0 ## 2^24

type
  SelectorKind* {.pure.} = enum
    selClosedLength, selClosedKnotLinked, selClosedKnotUnlinked,
    selOpenLength, selOpenKnotLinked, selOpenKnotUnlinked, selFillRule,
    selClipboard, selInitialFill, selOther

  Selector* = object
    ## Which of the documented record types this is. `selOther` keeps an
    ## unrecognised code rather than rejecting it.
    case kind*: SelectorKind
    of selClosedLength: discard
    of selClosedKnotLinked: discard
    of selClosedKnotUnlinked: discard
    of selOpenLength: discard
    of selOpenKnotLinked: discard
    of selOpenKnotUnlinked: discard
    of selFillRule: discard
    of selClipboard: discard
    of selInitialFill: discard
    of selOther: raw*: uint16

  PathRecord* = object
    selector*: Selector
    data*: array[24, byte] ## exactly as stored


  PathData* = object
    records*: seq[PathRecord]

  Knot* = object
    linked*: bool
    ## Control point of the incoming segment, as a fraction of document size.
    preV*, preH*: float64
    anchorV*, anchorH*: float64
    ## Control point of the outgoing segment.
    postV*, postH*: float64

  SubPath* = object
    closed*: bool
    ## -1 combine-or, 0 exclude/xor, 2 subtract, 3 intersect
    operation*: int
    knots*: seq[Knot]

  VectorMaskBlock* = object
    version*: uint32
    flags*: uint32
    path*: PathData
    trailing*: Span
      ## Bytes after the last whole record. A 192-byte payload holds seven
      ## 26-byte records plus ten bytes that fit nothing, so they are kept
      ## rather than dropped, and written back verbatim.

const
  VectorFlagInvert* = 1'u32
  VectorFlagNotLinked* = 2'u32
  VectorFlagDisabled* = 4'u32

const
  PathOpExclude* = -1
    ## The subpath toggles coverage: where it overlaps an earlier subpath the
    ## result is empty. Stored as 0.
  PathOpAdd* = 0
    ## Union with what came before. Stored as 1, and Photoshop's default.
  PathOpSubtract* = 1
    ## Remove this subpath's area from the accumulated coverage. Stored as 2.
  PathOpIntersect* = 2
    ## Keep only the overlap. Stored as 3.

proc fixedToFloat*(v: int32): float64 {.inline.} =
  ## 8.24 signed fixed point to a fraction.
  float64(v) / FixedPointScale

proc floatToFixed*(v: float64): int32 =
  ## Fraction to 8.24 fixed point, saturating at the int32 bounds.
  let scaled = v * FixedPointScale
  if scaled >= float64(high(int32)):
    return high(int32)
  if scaled <= float64(low(int32)):
    return low(int32)
  int32(round(scaled))

proc selectorFromU16*(v: uint16): Selector =
  case v
  of 0'u16: Selector(kind: selClosedLength)
  of 1'u16: Selector(kind: selClosedKnotLinked)
  of 2'u16: Selector(kind: selClosedKnotUnlinked)
  of 3'u16: Selector(kind: selOpenLength)
  of 4'u16: Selector(kind: selOpenKnotLinked)
  of 5'u16: Selector(kind: selOpenKnotUnlinked)
  of 6'u16: Selector(kind: selFillRule)
  of 7'u16: Selector(kind: selClipboard)
  of 8'u16: Selector(kind: selInitialFill)
  else: Selector(kind: selOther, raw: v)

proc toU16*(s: Selector): uint16 {.inline.} =
  case s.kind
  of selClosedLength: 0'u16
  of selClosedKnotLinked: 1'u16
  of selClosedKnotUnlinked: 2'u16
  of selOpenLength: 3'u16
  of selOpenKnotLinked: 4'u16
  of selOpenKnotUnlinked: 5'u16
  of selFillRule: 6'u16
  of selClipboard: 7'u16
  of selInitialFill: 8'u16
  of selOther: s.raw

proc isLength*(s: Selector): bool {.inline.} =
  s.kind == selClosedLength or s.kind == selOpenLength

proc isKnot*(s: Selector): bool {.inline.} =
  s.kind == selClosedKnotLinked or s.kind == selClosedKnotUnlinked or
    s.kind == selOpenKnotLinked or s.kind == selOpenKnotUnlinked

proc u16At*(rec: PathRecord, at: int): uint16 {.inline.} =
  (uint16(rec.data[at]) shl 8) or uint16(rec.data[at + 1])

proc i32At*(rec: PathRecord, at: int): int32 {.inline.} =
  let v = (uint32(rec.data[at]) shl 24) or (uint32(rec.data[at + 1]) shl 16) or
    (uint32(rec.data[at + 2]) shl 8) or uint32(rec.data[at + 3])
  cast[int32](v)

proc parsePathData*(data: Span): PathData =
  ## Records run to the end of the input; a tail shorter than one record is
  ## ignored, since it cannot hold a record.
  let n = data.len div PathRecordLen
  if n > MaxPathRecords:
    limitExceeded("path record count " & $n & " exceeds " & $MaxPathRecords)
  result.records = newSeq[PathRecord](n)
  for i in 0 ..< n:
    let base = i * PathRecordLen
    let sel = selectorFromU16(
      (uint16(data.byteAt(base)) shl 8) or uint16(data.byteAt(base + 1)))
    var rec: PathRecord
    rec.selector = sel
    for k in 0 ..< 24:
      rec.data[k] = data.byteAt(base + 2 + k)
    result.records[i] = rec

proc writePathData*(p: PathData): string =
  var w = initWriter()
  for rec in p.records:
    w.putU16(rec.selector.toU16())
    for b in rec.data:
      w.putU8(b)
  w.toString()

proc initialFill*(p: PathData): bool =
  ## Whether an initial-fill record is present and non-zero.
  for rec in p.records:
    if rec.selector.kind == selInitialFill:
      return rec.u16At(0) != 0'u16
  false

proc subpaths*(p: PathData): seq[SubPath] =
  ## Interpret the records as subpaths. Deliberately lenient: a knot with no
  ## preceding length record starts a subpath rather than failing, matching
  ## how Photoshop tolerates hand-edited files.
  var current = -1
  for rec in p.records:
    if rec.selector.isLength():
      result.add(SubPath(closed: rec.selector.kind == selClosedLength,
        operation: int(rec.u16At(2)) - 1, knots: @[]))
      current = result.len - 1
    elif rec.selector.isKnot():
      if current < 0:
        result.add(SubPath(closed: false, operation: -1, knots: @[]))
        current = result.len - 1
      let sub = addr result[current].knots
      sub[].add(Knot(
        linked: rec.selector.kind in [selClosedKnotLinked, selOpenKnotLinked],
        preV: fixedToFloat(rec.i32At(4)), preH: fixedToFloat(rec.i32At(0)),
        anchorV: fixedToFloat(rec.i32At(12)),
        anchorH: fixedToFloat(rec.i32At(8)),
        postV: fixedToFloat(rec.i32At(20)),
        postH: fixedToFloat(rec.i32At(16))))

proc pathFromSubPaths*(subs: seq[SubPath], fill = false): PathData =
  ## Inverse of `subpaths`, for writing a path back out.
  if fill:
    var rec: PathRecord
    rec.selector = Selector(kind: selInitialFill)
    rec.data[0] = 1'u8
    result.records.add(rec)
  for sub in subs:
    var lenRec: PathRecord
    lenRec.selector = if sub.closed: Selector(kind: selClosedLength)
                      else: Selector(kind: selOpenLength)
    lenRec.data[0] = byte(sub.knots.len shr 8)
    lenRec.data[1] = byte(sub.knots.len and 0xFF)
    let op = sub.operation + 1
    lenRec.data[2] = byte(cast[int16](op).int shr 8)
    lenRec.data[3] = byte(cast[int16](op).int and 0xFF)
    result.records.add(lenRec)
    for k in sub.knots:
      var rec: PathRecord
      rec.selector =
        if sub.closed:
          (if k.linked: Selector(kind: selClosedKnotLinked)
           else: Selector(kind: selClosedKnotUnlinked))
        else:
          (if k.linked: Selector(kind: selOpenKnotLinked)
           else: Selector(kind: selOpenKnotUnlinked))
      proc put(at: int, v: float64) =
        let f = floatToFixed(v)
        rec.data[at] = byte(cast[uint32](f) shr 24)
        rec.data[at + 1] = byte(cast[uint32](f) shr 16)
        rec.data[at + 2] = byte(cast[uint32](f) shr 8)
        rec.data[at + 3] = byte(cast[uint32](f) and 0xFF)
      put(0, k.preH); put(4, k.preV)
      put(8, k.anchorH); put(12, k.anchorV)
      put(16, k.postH); put(20, k.postV)
      result.records.add(rec)

proc parseVectorMaskBlock*(data: Span): VectorMaskBlock =
  ## A `vmsk` / `vsms` payload: u32 version, u32 flags, then path records.
  if data.len < 8:
    invalid("vector mask needs at least 8 bytes, got " & $data.len)
  var r = initReader(data)
  result.version = r.readU32BE()
  result.flags = r.readU32BE()
  let rest = r.peekRest()
  result.path = parsePathData(rest)
  result.trailing = rest.slice(result.path.records.len * PathRecordLen,
    rest.len)

proc writeVectorMaskBlock*(b: VectorMaskBlock): string =
  var w = initWriter()
  w.putU32(b.version)
  w.putU32(b.flags)
  w.put(writePathData(b.path))
  w.put(b.trailing)
  w.toString()

proc isInverted*(b: VectorMaskBlock): bool {.inline.} =
  (b.flags and VectorFlagInvert) != 0

proc isDisabled*(b: VectorMaskBlock): bool {.inline.} =
  (b.flags and VectorFlagDisabled) != 0

proc isNotLinked*(b: VectorMaskBlock): bool {.inline.} =
  (b.flags and VectorFlagNotLinked) != 0

# --- saved and work paths as image resources -------------------------------
#
# Vector mask blocks (`vmsk` / `vsms`) and saved paths hold the same 26-byte
# record list, so they share everything above. The only difference is where the
# records live: a saved path is the whole payload of resource 2000-2997 (keyed
# by a path name in Photoshop's UI) and the work path is resource 1025.

const
  WorkPathId* = 1025
    ## Resource id of the work path, the path the pen tool is drawing on.

proc parsePathResource*(res: ImageResource): PathData =
  ## Records from a saved-path (2000-2997) or work-path (1025) resource.
  parsePathData(res.data)

proc savedPaths*(resources: openArray[ImageResource],
    limits = defaultLimits()): seq[tuple[id: int, name: string, path: PathData]] =
  ## Every saved path, in resource order. The `id` is the resource id itself,
  ## which is what Photoshop exposes as the path's numeric name.
  for res in resources:
    if not isPathResource(res.id):
      continue
    limits.checkSection(res.data.len.int64, "path resource")
    result.add((id: res.id, name: res.name, path: parsePathData(res.data)))

proc workPath*(resources: openArray[ImageResource]): Option[PathData] =
  ## The work path (1025), or `none` when the document has none.
  let res = getResource(resources, WorkPathId)
  if res.isNone:
    return none(PathData)
  some(parsePathData(res.get().data))

proc savedPaths*(f: PsdFile,
    limits = defaultLimits()): seq[tuple[id: int, name: string, path: PathData]] =
  ## Every saved path in the document.
  savedPaths(f.resources, limits)

proc workPath*(f: PsdFile): Option[PathData] {.inline.} =
  workPath(f.resources)

proc parsePathData*(data: string): PathData =
  parsePathData(toSpan(data))

proc parseVectorMaskBlock*(data: string): VectorMaskBlock =
  parseVectorMaskBlock(toSpan(data))
