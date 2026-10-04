## Fills and strokes on shape layers.
##
## A shape layer does not store its appearance directly. The pixels are already
## in the layer's image data; what the file records is a *description* of how to
## regenerate them: an origination descriptor (`vogk`) saying what kind of fill
## the shape has and where its box is, a stroke descriptor (`vstk`) saying how
## the outline is drawn, and whatever colour or gradient or pattern those refer
## to. Nothing here interprets or re-renders any of that. It turns the
## descriptors into named accessors so callers can ask what a shape layer is
## instead of walking a descriptor tree by hand.
##
## The layer-level accessors are keyed on `vogk` / `vstk` because those are the
## keys Photoshop writes for vector shape layers. `GdFl` / `PtFl` are the same
## idea expressed differently, for fill-only layers that have no shape path;
## `descriptorForKey` handles those by name.
##
## `vogk` needs `parseOriginationDescriptor` rather than the generic entry point
## because of its `u32 1` marker. See `OriginationWrapperVersion`.

import std/options

import ./descriptor
import ./error
import ./layers
import ./span
import ./tagged

type
  FillKind* {.pure.} = enum
    ## What a shape layer's fill actually is, per `keyOriginType`.
    fkNone,      ## no origination descriptor, so no fill description
    fkSolidColor, ## a single colour
    fkGradient,  ## a gradient
    fkPattern    ## a tiled pattern

  UnitQuad* = object
    ## A rectangle in descriptor units, as `unitRect` stores it.
    ##
    ## The keys are `Top `, `Left`, `Btom` and `Rght`, and every one of them is a
    ## trap. Descriptor keys are a fixed four bytes, so the short ones are
    ## space-padded: the first is `"Top "` *with a trailing space*, not `"Top"`.
    ## And two of the four are misspellings, `Btom` and `Rght`, never `Bottom`
    ## or `Right`. Every one of these fails as a plain missing key, returning a
    ## zero rather than an error, so a box silently comes out as 0,0,0,0.
    top*: float64
    left*: float64
    bottom*: float64
    right*: float64

  Transform2x3* = object
    ## The 2x3 affine matrix from a `Trnf` descriptor: the first row scales and
    ## shears, the second does the same for y, and `tx`/`ty` translate.
    xx*: float64
    xy*: float64
    yx*: float64
    yy*: float64
    tx*: float64
    ty*: float64

  Stroke* = object
    ## The parts of a `vstk` descriptor that describe the outline itself.
    ## Deliberately not the whole descriptor: blend mode and opacity live here
    ## too but are applied by the compositor, not by the stroke definition, and
    ## quietly reimplementing them here would be a second, divergent code path.
    enabled*: bool
    lineWidth*: float64   ## in the descriptor's own unit, see `strokeWidthUnit`
    miterLimit*: float64
    capType*: string      ## `strokeStyleLineCapType`, e.g. `strokeStyleButtCap`
    joinType*: string     ## `strokeStyleLineJoinType`
    content*: Option[Descriptor] ## `strokeStyleContent`: a nested fill

const
  ## `keyOriginType` values, as written by Photoshop.
  OriginTypeSolidColor* = 1'i32
  OriginTypeGradient* = 2'i32
  OriginTypePattern* = 3'i32

  StrokeWidthUnit* = "#Pxl"
    ## `strokeStyleLineWidth` is almost always in pixels. The unit is carried in
    ## the descriptor rather than assumed, so this is only the value seen in
    ## practice; `strokeWidthUnit` reports the real one.

proc fillKindOf*(originType: int32): FillKind =
  ## `keyOriginType` to a typed value. Unknown values become `fkNone` rather than
  ## guessing: Photoshop has added fill types over time and a new number is more
  ## likely to be something we cannot render than a variant we can.
  case originType
  of OriginTypeSolidColor: fkSolidColor
  of OriginTypeGradient: fkGradient
  of OriginTypePattern: fkPattern
  else: fkNone

proc blockData*(l: LayerRecord, key: string): Option[Span] =
  ## The payload of a tagged block on this layer, by key.
  for b in l.blocks:
    if b.key == key: return some(b.data)
  none(Span)

proc parseDescriptorBlock*(l: LayerRecord, key: string): Option[Descriptor] =
  ## Parse a descriptor-bearing tagged block by key, choosing the right entry
  ## point for the key.
  ##
  ## Returns `none` for a missing block *and* for one whose payload does not
  ## parse. A malformed fill should not take a document down, and the caller
  ## cannot do anything useful with a half-parsed descriptor.
  let data = blockData(l, key)
  if data.isNone: return none(Descriptor)
  try:
    if key == "vogk":
      return some(parseOriginationDescriptor(data.get()).descriptor)
    some(parseVersionedDescriptor(data.get()).descriptor)
  except PsdError:
    none(Descriptor)

proc originationDescriptor*(l: LayerRecord): Option[Descriptor] =
  ## `vogk`, the descriptor describing this layer's fill.
  parseDescriptorBlock(l, "vogk")

proc strokeDescriptor*(l: LayerRecord): Option[Descriptor] =
  ## `vstk`, the descriptor describing this layer's outline.
  parseDescriptorBlock(l, "vstk")

proc contentDescriptor*(l: LayerRecord): Option[Descriptor] =
  ## The origination descriptor's `keyDescriptorList` element.
  ##
  ## `vogk` is a wrapper holding a *list*, even when there is exactly one entry,
  ## which is how a layer can carry more than one fill. Every accessor here
  ## reaches through that list, because reading `vogk` as if the list were the
  ## descriptor itself yields an empty descriptor with no error.
  let d = originationDescriptor(l)
  if d.isNone: return none(Descriptor)
  let lst = d.get().get("keyDescriptorList")
  if lst.isNone or lst.get().kind != vList: return none(Descriptor)
  for v in lst.get().items:
    if v.kind == vDescriptor: return some(v.descriptor)
    if v.kind == vGlobalObject: return some(v.globalObject)
  none(Descriptor)

proc fillKind*(l: LayerRecord): FillKind =
  ## The kind of fill a shape layer describes. `fkNone` for layers with no
  ## origination data, which is most layers.
  # keyOriginType lives inside the keyDescriptorList entry, not on the vogk
  # wrapper. Reading it off the wrapper yields 0, which is not a fill type, and
  # so every shape layer would report no fill at all.
  let c = contentDescriptor(l)
  if c.isNone: return fkNone
  fillKindOf(c.get().getInt("keyOriginType"))

proc originationBoundingBox*(l: LayerRecord): Option[UnitQuad] =
  ## `keyOriginShapeBBox`: the shape's box in `#Pxl` units.
  ##
  ## This is the shape's own geometry and need not match the layer's rect: the
  ## layer rect also has to cover the stroke, and Photoshop pads it. Comparing
  ## the two is a useful sanity check on a document rather than assuming they
  ## agree.
  let c = contentDescriptor(l)
  if c.isNone: return none(UnitQuad)
  let bb = c.get().getDescriptor("keyOriginShapeBBox")
  if bb.isNone: return none(UnitQuad)
  let d = bb.get()
  # Each of the four is a separate optional unit float, so a box missing one
  # edge is reported as no box rather than as a box with a silent zero.
  let top = d.getUnitFloat("Top ")  # trailing space: keys are 4 bytes
  let left = d.getUnitFloat("Left")
  let bottom = d.getUnitFloat("Btom")
  let right = d.getUnitFloat("Rght")
  if top.isNone or left.isNone or bottom.isNone or right.isNone:
    return none(UnitQuad)
  some(UnitQuad(
    top: top.get().value, left: left.get().value,
    bottom: bottom.get().value, right: right.get().value))

proc originationTransform*(l: LayerRecord): Option[Transform2x3] =
  ## `Trnf`: the transform applied to the shape's path.
  let c = contentDescriptor(l)
  if c.isNone: return none(Transform2x3)
  let t = c.get().getDescriptor("Trnf")
  if t.isNone: return none(Transform2x3)
  let d = t.get()
  if d.classId.asString() != "Trnf": return none(Transform2x3)
  some(Transform2x3(
    xx: d.getDouble("xx", 1.0), xy: d.getDouble("xy", 0.0),
    yx: d.getDouble("yx", 0.0), yy: d.getDouble("yy", 1.0),
    tx: d.getDouble("tx", 0.0), ty: d.getDouble("ty", 0.0)))

proc strokeWidthUnit*(l: LayerRecord): string =
  ## The unit `strokeStyleLineWidth` is expressed in.
  let s = strokeDescriptor(l)
  if s.isNone: return ""
  let v = s.get().get("strokeStyleLineWidth")
  if v.isNone or v.get().kind != vUnitFloat: return ""
  result = newString(4)
  for i in 0 .. 3: result[i] = char(v.get().floatUnit[i])

proc enumIdOf(d: Descriptor, key: string): string =
  ## The value half of an `enum`-typed item, or "" if it is absent or another
  ## type. Only the value is useful; the type half is almost always the key's
  ## own name spelled differently.
  let v = d.get(key)
  if v.isNone or v.get().kind != vEnumerated: return ""
  v.get().valueId.asString()

proc stroke*(l: LayerRecord): Option[Stroke] =
  ## The outline description from `vstk`.
  let s = strokeDescriptor(l)
  if s.isNone: return none(Stroke)
  let d = s.get()
  if d.classId.asString() != "strokeStyle": return none(Stroke)
  let width = d.get("strokeStyleLineWidth")
  some(Stroke(
    enabled: d.getBool("strokeEnabled", false),
    lineWidth: if width.isSome and width.get().kind == vUnitFloat:
        width.get().floatUnitValue else: 0.0,
    miterLimit: d.getDouble("strokeStyleMiterLimit", 10.0),
    capType: enumIdOf(d, "strokeStyleLineCapType"),
    joinType: enumIdOf(d, "strokeStyleLineJoinType"),
    content: d.getDescriptor("strokeStyleContent")))
