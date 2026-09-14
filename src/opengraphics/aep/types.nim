## Shared types and errors for the AEP reader.
##
## v1 scope: read-only project inventory. Container (`RIFX` + `Egg!`),
## item routing (`idta`), comp headers (`cdta`), layer records (`ldta`),
## footage size and type (`sspc` / `opti`), match name scanning (`tdmn`).
## v2 adds `cdat` statics plus `tdb4` typing, v3 adds `lhd3`/`ldat`
## keyframes. No writer.

type
  AepError* = object of CatchableError

  ItemKind* {.pure.} = enum
    ItemUnknown = 0
    ItemFolder = 1
    ItemComp = 4
    ItemFootage = 7

  LayerKind* {.pure.} = enum
    LayerAsset = 0
    LayerLight = 1
    LayerCamera = 2
    LayerText = 3
    LayerShape = 4
    LayerUnknown = -1

  PropKind* {.pure.} = enum
    ## Value kind from the tdb4 type flags.
    PropNoValue = 0 ## shapes, gradients: values live outside keyframes
    PropColor = 1 ## 4 floats (ARGB, 0..255)
    PropInteger = 2 ## index refs in tdpi / tdps / tdli
    PropVector = 3 ## components floats (scalar when components == 1)
    PropUnknown = -1

  KeyframeEase* {.pure.} = enum
    ## Ease mode byte of the common keyframe header.
    EaseUnknown = 0
    EaseLinear = 1
    EaseEase = 2
    EaseHold = 3

  Keyframe* = object
    ## One decoded ldat keyframe. Speeds and influences are per
    ## dimension for multi-dimensional properties and single element
    ## otherwise. Spatial tangents exist for position properties only.
    time*: int ## raw u16 time units
    ease*: KeyframeEase
    labelColor*: int
    continuousBezier*: bool
    autoBezier*: bool
    roving*: bool
    values*: seq[float64] ## value floats, empty for no-value kind
    inSpeed*: seq[float64]
    inInfluence*: seq[float64]
    outSpeed*: seq[float64]
    outInfluence*: seq[float64]
    tanIn*: seq[float64] ## spatial tangents, position only
    tanOut*: seq[float64] ## spatial tangents, position only
    extra*: seq[float64] ## trailing floats of unknown meaning (color: 8)

  AepLimits* = object
    ## Caps applied before allocating or recursing, so corrupt headers
    ## cannot force huge allocations. Violations raise AepError.
    maxChunks*: int ## total chunks parsed per file
    maxDepth*: int ## nested LIST depth
    maxItems*: int ## folder items collected
    maxLayers*: int ## layers collected per comp
    maxChunkBytes*: int ## largest single chunk payload kept
    maxNameBytes*: int ## longest name or match string kept
    maxPropsPerGroup*: int ## properties collected from one tdgp
    maxComponents*: int ## floats read from one cdat
    maxKeyframes*: int ## keyframes decoded from one LIST list

  CompInfo* = object
    id*: uint32
    name*: string
    width*: int
    height*: int
    timeScale*: int ## divisor for raw time values
    framerate*: float64 ## best effort guess, 0 when unknown
    framerateRaw*: int ## raw uint16 at the spec framerate offset
    playhead*: int ## raw time units
    inTime*: int ## raw time units
    outTime*: int ## raw time units, -1 when FFFF (means duration)
    duration*: int ## raw time units

  LayerInfo* = object
    id*: uint32
    name*: string
    kind*: LayerKind
    sourceId*: uint32 ## item id of the used asset, 0 when none
    parentId*: uint32
    labelColor*: int
    matteMode*: int
    startTime*: int ## raw time offset added to times inside the layer
    inTime*: int ## raw time units
    outTime*: int ## raw time units
    stretch*: float64 ## numerator / denominator, 1.0 when unset
    isAdjustment*: bool
    isNull*: bool
    isGuide*: bool
    isVisible*: bool
    isLocked*: bool
    isShy*: bool

  FootageInfo* = object
    id*: uint32
    name*: string
    width*: int ## 0 when absent
    height*: int ## 0 when absent
    assetType*: string ## first 4 bytes of opti, eg Soli
    filePath*: string ## from alas JSON fullpath, empty when absent

  PropValue* = object
    ## Decoded value of one property. Static properties carry values,
    ## animated ones carry keyframes (v3, from LIST list lhd3/ldat).
    kind*: PropKind
    components*: int ## tdb4 component count
    values*: seq[float64] ## first components floats of cdat, static only
    keyframes*: seq[Keyframe] ## decoded keyframes, animated only
    hasLayerRef*: bool ## integer kind pointing at a layer
    layerIndex*: int ## from tdpi
    layerSource*: int ## from tdps (0 layer, -1 effects and masks, -2 masks)
    hasMaskRef*: bool ## integer kind pointing at a mask
    maskIndex*: int ## from tdli
    isAnimated*: bool
    isPosition*: bool
    displayName*: string ## human name from tdsn, empty when absent
    expression*: string ## expression code, empty when absent
    hasExpression*: bool
    minVal*: float64 ## from tdum
    maxVal*: float64 ## from tduM
    hasMinMax*: bool

  PropInfo* = object
    matchName*: string ## tdmn value, eg ADBE Position
    value*: PropValue

  OrientationInfo* = object
    ## Decoded LIST otst (orientation is not a plain tdbs property:
    ## static triplet in cdat plus one otda triplet per otky entry).
    matchName*: string ## tdmn value, eg ADBE Orientation
    displayName*: string ## human name from tdsn, empty when absent
    staticValue*: array[3, float64] ## first 3 floats of cdat
    frames*: seq[array[3, float64]] ## one triplet per otda, timeless

proc defaultAepLimits*(): AepLimits =
  AepLimits(maxChunks: 200_000, maxDepth: 64, maxItems: 10_000,
    maxLayers: 10_000, maxChunkBytes: 256_000_000, maxNameBytes: 4096,
    maxPropsPerGroup: 10_000, maxComponents: 16, maxKeyframes: 50_000)

proc itemKindFromU16*(v: uint16): ItemKind =
  case v
  of 1: ItemFolder
  of 4: ItemComp
  of 7: ItemFootage
  else: ItemUnknown

proc layerKindFromU8*(v: uint8): LayerKind =
  case v
  of 0: LayerAsset
  of 1: LayerLight
  of 2: LayerCamera
  of 3: LayerText
  of 4: LayerShape
  else: LayerUnknown

proc toFrames*(raw: int, timeScale: int, startTime: int = 0): float64 =
  ## Raw time to frames. Returns 0 when the scale is unknown.
  if timeScale <= 0:
    return 0.0
  float64(raw + startTime) / float64(timeScale)
