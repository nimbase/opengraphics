## Layer and Mask Information section.
##
## v1 parses record structure, blend keys, names (ASCII + luni),
## group dividers (lsct), and 8-bit Raw/RLE channel pixels.
## Everything else is preserved as raw bytes.

import ./types
import ./reader
import ./rle
import ./pixels

type
  LayerKind* {.pure.} = enum
    Pixel = 0
    OpenFolder = 1
    ClosedFolder = 2
    Divider = 3

  ChannelDescriptor* = object
    id*: int16
    dataLen*: uint32

  TaggedBlock* = object
    signature*: string
    key*: string
    data*: seq[byte]

  Layer* = object
    top*, left*, bottom*, right*: int32
    channels*: seq[ChannelDescriptor]
    blendKey*: string
    opacity*: uint8
    clipping*: uint8
    flags*: uint8
    name*: string
    unicodeName*: string
    layerId*: int32
    hasLayerId*: bool
    kind*: LayerKind
    maskRaw*: seq[byte]
    blendingRangesRaw*: seq[byte]
    extraBlocks*: seq[TaggedBlock]
    channelPixels*: seq[seq[byte]] # decoded bytes per channel, parallel to channels
    channelCompression*: Compression

  LayerInfo* = object
    layers*: seq[Layer]
    hasMergedAlpha*: bool
    globalMaskRaw*: seq[byte]
    additional*: seq[TaggedBlock]

  LayerNode* = ref object
    ## One node of the layer hierarchy. Leaves wrap a pixel layer;
    ## groups wrap the folder record (its name, opacity, visibility)
    ## and own the layers nested inside it.
    layer*: Layer
    isGroup*: bool
    opened*: bool # only meaningful when isGroup (OpenFolder vs ClosedFolder)
    children*: seq[LayerNode]

proc width*(l: Layer): int {.inline.} = int(l.right - l.left)
proc height*(l: Layer): int {.inline.} = int(l.bottom - l.top)

proc isVisible*(l: Layer): bool {.inline.} =
  (l.flags and 2) == 0

proc isFolder*(l: Layer): bool {.inline.} =
  l.kind == OpenFolder or l.kind == ClosedFolder

proc decodeUtf16BeAscii(data: seq[byte]): string =
  var i = 0
  while i + 1 < data.len:
    let c = (uint16(data[i]) shl 8) or uint16(data[i + 1])
    i += 2
    if c == 0:
      break
    if c < 128:
      result.add(char(c))
    else:
      result.add('?')

proc parseLuni(data: seq[byte]): string =
  if data.len < 4:
    return ""
  var r = initReader(data)
  let n = int(r.readU32BE())
  let raw = r.readBytes(min(n * 2, r.remaining()))
  result = decodeUtf16BeAscii(raw)

proc parseDividerType(data: seq[byte]): int =
  ## Raw lsct/lsdk section type: 0 other, 1 open folder,
  ## 2 closed folder, 3 bounding divider. -1 when unreadable.
  if data.len < 4:
    return -1
  var r = initReader(data)
  result = int(r.readU32BE())

proc parseTaggedBlocks(r: var BinReader, stop: int): seq[TaggedBlock] =
  result = @[]
  while r.pos + 12 <= stop:
    let sig = r.readStr(4)
    if sig != "8BIM" and sig != "8B64":
      raise newException(PsdError, "bad layer info signature at " & $(r.pos - 4))
    let key = r.readStr(4)
    let n = int(r.readU32BE())
    let data = r.readBytes(n)
    if n mod 2 != 0:
      # data padded to even size
      if r.pos < stop:
        r.skip(1)
    result.add(TaggedBlock(signature: sig, key: key, data: data))

proc parseOneLayerRecord(r: var BinReader): Layer =
  let top = r.readI32BE()
  let left = r.readI32BE()
  let bottom = r.readI32BE()
  let right = r.readI32BE()
  let nCh = int(r.readU16BE())
  if nCh < 0 or nCh > 56:
    raise newException(PsdError, "invalid layer channel count " & $nCh)
  var ch: seq[ChannelDescriptor] = newSeq[ChannelDescriptor](nCh)
  for i in 0 ..< nCh:
    ch[i] = ChannelDescriptor(id: r.readI16BE(), dataLen: r.readU32BE())
  let sig = r.readStr(4)
  if sig != "8BIM":
    raise newException(PsdError, "bad layer blend signature")
  let blendKey = r.readStr(4)
  let opacity = r.readU8()
  let clipping = r.readU8()
  let flags = r.readU8()
  discard r.readU8() # filler
  let extraLen = int(r.readU32BE())
  let extraEnd = r.pos + extraLen
  if extraEnd > r.data.len:
    raise newException(PsdError, "truncated layer extra data")
  # mask data
  let maskLen = int(r.readU32BE())
  let maskRaw = r.readBytes(maskLen)
  # blending ranges
  let blendLen = int(r.readU32BE())
  let blendingRangesRaw = r.readBytes(blendLen)
  # name, pascal padded to multiple of 4
  let name = r.readPascalStringPad4()
  # tagged blocks filling the rest of extra
  let extraBlocks = parseTaggedBlocks(r, extraEnd)
  if r.pos != extraEnd:
    # tolerate gap by skipping (future-proof)
    r.pos = extraEnd
  var unicodeName = ""
  var layerId: int32 = 0
  var hasLayerId = false
  # Divider lookup mirrors psd-tools: lsdk (nested) wins over lsct
  # when present; type 0 (other) means a normal layer.
  var dividerType = -1
  var nestedType = -1
  for b in extraBlocks:
    if b.key == "luni":
      unicodeName = parseLuni(b.data)
    elif b.key == "lyid":
      if b.data.len >= 4:
        var br = initReader(b.data)
        layerId = br.readI32BE()
        hasLayerId = true
    elif b.key == "lsct":
      dividerType = parseDividerType(b.data)
    elif b.key == "lsdk":
      nestedType = parseDividerType(b.data)
  let sectionType = if nestedType >= 0: nestedType else: dividerType
  var kind = Pixel
  case sectionType
  of 1: kind = OpenFolder
  of 2: kind = ClosedFolder
  of 3: kind = Divider
  else: kind = Pixel
  result = Layer(top: top, left: left, bottom: bottom, right: right,
    channels: ch, blendKey: blendKey, opacity: opacity, clipping: clipping,
    flags: flags, name: name, unicodeName: unicodeName, layerId: layerId,
    hasLayerId: hasLayerId, kind: kind, maskRaw: maskRaw,
    blendingRangesRaw: blendingRangesRaw, extraBlocks: extraBlocks,
    channelPixels: @[], channelCompression: Raw)

proc displayName*(l: Layer): string {.inline.} =
  if l.unicodeName.len > 0: l.unicodeName else: l.name

proc skipChannelData(r: var BinReader, w, h: int) =
  let comp = r.readU16BE()
  if comp != 0 and comp != 1:
    raise newException(PsdError,
      "unsupported layer compression " & $comp & " (v1 supports Raw and RLE)")
  if w <= 0 or h <= 0:
    return
  if comp == 0:
    r.skip(w * h)
  else:
    var total = 0
    for _ in 0 ..< h:
      total += int(r.readU16BE())
    r.skip(total)

proc decodeChannelData(r: var BinReader, w, h: int): seq[byte] =
  let comp = r.readU16BE()
  if comp != 0 and comp != 1:
    raise newException(PsdError,
      "unsupported layer compression " & $comp & " (v1 supports Raw and RLE)")
  if w <= 0 or h <= 0:
    return @[]
  if comp == 0:
    return r.readBytes(w * h)
  var rowCounts = newSeq[uint16](h)
  for i in 0 ..< h:
    rowCounts[i] = r.readU16BE()
  result = newSeqOfCap[byte](w * h)
  for y in 0 ..< h:
    let rowLen = int(rowCounts[y])
    let rowRaw = r.readBytes(rowLen)
    var p = 0
    let row = decodePackBitsRow(rowRaw, p, w)
    for b in row:
      result.add(b)
    if p != rowLen:
      raise newException(PsdError, "RLE layer row length mismatch")

proc layerPixelsToImage*(l: Layer): ImageBuf =
  ## Assemble decoded channel planes into an ImageBuf cropped to the
  ## layer rect. Supports 1-4 channels of 8-bit gray/RGB(A).
  ## Channel ids: 0=R,1=G,2=B,-1=alpha; others mapped by order.
  let w = l.width()
  let h = l.height()
  if w <= 0 or h <= 0 or l.channelPixels.len == 0:
    return ImageBuf(width: 0, height: 0, data: @[])
  # map channel id -> plane index
  var rPlane, gPlane, bPlane, aPlane = -1
  for i, c in l.channels:
    case c.id
    of 0: rPlane = i
    of 1: gPlane = i
    of 2: bPlane = i
    of -1: aPlane = i
    else: discard
  var img = initImageBuf(w, h)
  for k in 0 ..< w * h:
    var px = Rgba(r: 0, g: 0, b: 0, a: 255)
    if l.channels.len == 1 and rPlane < 0 and gPlane < 0:
      # single gray plane (id may be 0 or -1); use first plane
      let v = l.channelPixels[0][k]
      px.r = v; px.g = v; px.b = v
      if l.channels[0].id == -1:
        px.a = v
    else:
      if rPlane >= 0: px.r = l.channelPixels[rPlane][k]
      if gPlane >= 0: px.g = l.channelPixels[gPlane][k]
      elif rPlane >= 0 and l.channels.len >= 1 and gPlane < 0 and bPlane < 0:
        # gray + alpha case: reuse R for G/B
        px.g = px.r
      if bPlane >= 0: px.b = l.channelPixels[bPlane][k]
      elif rPlane >= 0 and bPlane < 0 and gPlane < 0:
        px.b = px.r
      if aPlane >= 0: px.a = l.channelPixels[aPlane][k]
    img.data[k] = px
  result = img

proc parseLayerInfo*(r: var BinReader, optsSkipImage: bool): LayerInfo =
  let sectionLen = int(r.readU32BE())
  if sectionLen == 0:
    return LayerInfo(layers: @[], hasMergedAlpha: false,
      globalMaskRaw: @[], additional: @[])
  let sectionEnd = r.pos + sectionLen
  if sectionEnd > r.data.len:
    raise newException(PsdError, "truncated layer and mask section")
  # --- layer info sub-section
  let layerInfoLen = int(r.readU32BE())
  let layerInfoEnd = r.pos + layerInfoLen
  if layerInfoEnd > sectionEnd:
    raise newException(PsdError, "bad layer info length")
  var layers: seq[Layer] = @[]
  var hasMergedAlpha = false
  if layerInfoLen > 0:
    let countRaw = r.readI16BE()
    var count = int(countRaw)
    if count < 0:
      hasMergedAlpha = true
      count = -count
    for _ in 0 ..< count:
      layers.add(parseOneLayerRecord(r))
    # channel image data, in same layer order
    for li in 0 ..< layers.len:
      let w = layers[li].width()
      let h = layers[li].height()
      var planes: seq[seq[byte]] = @[]
      var comp: Compression = Raw
      if optsSkipImage:
        for _ in layers[li].channels:
          let cw = if w < 0: 0 else: w
          let chh = if h < 0: 0 else: h
          skipChannelData(r, cw, chh)
          planes.add(@[])
        layers[li].channelPixels = planes
        layers[li].channelCompression = Raw
      else:
        for ci in 0 ..< layers[li].channels.len:
          let save = r.pos
          let ccRaw = r.readU16BE()
          r.pos = save
          comp = compressionFromU16(ccRaw)
          planes.add(decodeChannelData(r, max(w, 0), max(h, 0)))
        layers[li].channelPixels = planes
        layers[li].channelCompression = comp
  r.pos = layerInfoEnd
  # --- global mask
  if r.pos + 4 > sectionEnd:
    raise newException(PsdError, "truncated global mask length")
  let gLen = int(r.readU32BE())
  var gRaw: seq[byte] = @[]
  if gLen > 0:
    gRaw = r.readBytes(gLen)
  # --- additional tagged blocks to end of section
  var additional: seq[TaggedBlock] = @[]
  if r.pos < sectionEnd:
    additional = parseTaggedBlocks(r, sectionEnd)
  if r.pos != sectionEnd:
    r.pos = sectionEnd
  result = LayerInfo(layers: layers, hasMergedAlpha: hasMergedAlpha,
    globalMaskRaw: gRaw, additional: additional)

proc buildLayerTree*(layers: seq[Layer]): seq[LayerNode] =
  ## Nest flat file-order (bottom layer first) records into a hierarchy.
  ## Follows psd-tools PSDImage._init: a bounding divider (lsct/lsdk
  ## type 3) opens a group, the matching folder record (type 1 open or
  ## type 2 closed) closes it and supplies the group properties, so a
  ## single bottom-to-top pass suffices. Dividers are dropped from the
  ## result. Type 0 (other) dividers are ignored and treated as normal
  ## layers; an lsdk block takes precedence over lsct when both exist.
  ## Malformed nesting degrades gracefully: a stray folder becomes an
  ## empty group, unclosed groups are flushed to the top level.
  var stack: seq[LayerNode] = @[]
  var top: seq[LayerNode] = @[]
  for l in layers:
    case l.kind
    of Divider:
      stack.add(LayerNode(layer: l, isGroup: true, opened: true, children: @[]))
    of OpenFolder, ClosedFolder:
      var node =
        if stack.len > 0:
          stack.pop()
        else:
          LayerNode(layer: l, isGroup: true, opened: true, children: @[])
      node.layer = l
      node.isGroup = true
      node.opened = l.kind == OpenFolder
      if stack.len > 0:
        stack[^1].children.add(node)
      else:
        top.add(node)
    of Pixel:
      let node = LayerNode(layer: l, isGroup: false, opened: false,
        children: @[])
      if stack.len > 0:
        stack[^1].children.add(node)
      else:
        top.add(node)
  # flush unclosed groups, innermost first
  while stack.len > 0:
    let node = stack.pop()
    if stack.len > 0:
      stack[^1].children.add(node)
    else:
      top.add(node)
  result = top

proc flattenTree*(nodes: seq[LayerNode]): seq[Layer] =
  ## Pre-order walk back to flat layers (folders included, dividers not).
  for n in nodes:
    result.add(n.layer)
    if n.isGroup:
      for l in flattenTree(n.children):
        result.add(l)
