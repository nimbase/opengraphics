## Synthetic PSD builder for tests (stdlib only).
## Builds minimal valid PSD bytes: header, colormode, resources,
## layer/mask, composite. Supports Raw and RLE, 8-bit RGB/Gray.

import ../src/opengraphics/psd/rle

proc putU16BE*(b: var seq[byte], v: uint16) =
  b.add(byte(v shr 8))
  b.add(byte(v and 0xFF))

proc putU32BE*(b: var seq[byte], v: uint32) =
  b.add(byte(v shr 24))
  b.add(byte((v shr 16) and 0xFF))
  b.add(byte((v shr 8) and 0xFF))
  b.add(byte(v and 0xFF))

proc putI16BE*(b: var seq[byte], v: int16) =
  putU16BE(b, cast[uint16](v))

proc putI32BE*(b: var seq[byte], v: int32) =
  putU32BE(b, cast[uint32](v))

proc putStr*(b: var seq[byte], s: string) =
  for c in s:
    b.add(byte(c))

proc putPascalEven*(b: var seq[byte], s: string) =
  b.add(byte(s.len))
  putStr(b, s)
  if (1 + s.len) mod 2 != 0:
    b.add(0)

proc putPascalPad4*(b: var seq[byte], s: string) =
  b.add(byte(s.len))
  putStr(b, s)
  let consumed = 1 + s.len
  let padded = ((consumed + 3) div 4) * 4
  for _ in consumed ..< padded:
    b.add(0)

proc putHeader*(b: var seq[byte], width, height, channels: int,
    depth = 8, mode = 3) =
  putStr(b, "8BPS")
  putU16BE(b, 1)
  for _ in 0 ..< 6: b.add(0)
  putU16BE(b, uint16(channels))
  putU32BE(b, uint32(height))
  putU32BE(b, uint32(width))
  putU16BE(b, uint16(depth))
  putU16BE(b, uint16(mode))

proc encodeChannelRle*(plane: seq[byte], w, h: int): seq[byte] =
  ## Returns compression(2) + rowCounts + PackBits rows.
  result = @[]
  var rows: seq[seq[byte]] = @[]
  for y in 0 ..< h:
    rows.add(encodePackBitsRow(plane[y * w ..< (y + 1) * w]))
  putU16BE(result, 1)
  for r in rows:
    putU16BE(result, uint16(r.len))
  for r in rows:
    for v in r: result.add(v)

proc encodeChannelRaw*(plane: seq[byte]): seq[byte] =
  result = @[]
  putU16BE(result, 0)
  for v in plane: result.add(v)

type
  TestLayerSpec* = object
    name*: string
    top*, left*, bottom*, right*: int32
    planes*: seq[seq[byte]] # one per channel, each w*h bytes
    channelIds*: seq[int16]
    useRle*: bool
    blendKey*: string
    opacity*: uint8
    flags*: uint8
    lsct*: int # -1 = no divider block, else lsct section type 0..3
    lsdk*: int # -1 = none, else nested divider type (wins over lsct)

proc buildLayerRecord*(spec: TestLayerSpec): tuple[record: seq[byte], channelData: seq[byte]] =
  let w = int(spec.right - spec.left)
  let h = int(spec.bottom - spec.top)
  var channelBlobs: seq[seq[byte]] = @[]
  for p in spec.planes:
    if spec.useRle:
      channelBlobs.add(encodeChannelRle(p, w, h))
    else:
      channelBlobs.add(encodeChannelRaw(p))
  var rec: seq[byte] = @[]
  putI32BE(rec, spec.top)
  putI32BE(rec, spec.left)
  putI32BE(rec, spec.bottom)
  putI32BE(rec, spec.right)
  putU16BE(rec, uint16(spec.channelIds.len))
  for i, id in spec.channelIds:
    putI16BE(rec, id)
    putU32BE(rec, uint32(channelBlobs[i].len))
  putStr(rec, "8BIM")
  let bk = if spec.blendKey.len == 4: spec.blendKey else: "norm"
  putStr(rec, bk)
  rec.add(spec.opacity)
  rec.add(0) # clipping
  rec.add(spec.flags)
  rec.add(0) # filler
  # extra
  var extra: seq[byte] = @[]
  putU32BE(extra, 0) # mask len
  putU32BE(extra, 0) # blending ranges len
  putPascalPad4(extra, spec.name)
  if spec.lsct >= 0:
    putStr(extra, "8BIM")
    putStr(extra, "lsct")
    putU32BE(extra, 4)
    putU32BE(extra, uint32(spec.lsct))
  if spec.lsdk >= 0:
    putStr(extra, "8BIM")
    putStr(extra, "lsdk")
    putU32BE(extra, 4)
    putU32BE(extra, uint32(spec.lsdk))
  putU32BE(rec, uint32(extra.len))
  for v in extra: rec.add(v)
  var cd: seq[byte] = @[]
  for blob in channelBlobs:
    for v in blob: cd.add(v)
  result = (rec, cd)

proc buildPsd*(width, height, channels: int,
    planes: seq[seq[byte]], useRle = false,
    layers: seq[TestLayerSpec] = @[]): seq[byte] =
  result = @[]
  putHeader(result, width, height, channels)
  putU32BE(result, 0) # colormode len
  putU32BE(result, 0) # resources len
  # layer and mask
  if layers.len == 0:
    putU32BE(result, 0)
  else:
    var layerInfo: seq[byte] = @[]
    putI16BE(layerInfo, int16(layers.len))
    var channelData: seq[byte] = @[]
    for spec in layers:
      let (rec, cd) = buildLayerRecord(spec)
      for v in rec: layerInfo.add(v)
      for v in cd: channelData.add(v)
    for v in channelData: layerInfo.add(v)
    var section: seq[byte] = @[]
    putU32BE(section, uint32(layerInfo.len))
    for v in layerInfo: section.add(v)
    putU32BE(section, 0) # global mask len
    putU32BE(result, uint32(section.len))
    for v in section: result.add(v)
  # composite
  if useRle:
    var comp: seq[byte] = @[]
    putU16BE(comp, 1)
    var rows: seq[seq[byte]] = @[]
    for p in planes:
      for y in 0 ..< height:
        rows.add(encodePackBitsRow(p[y * width ..< (y + 1) * width]))
    var idx = 0
    # row counts grouped per channel: planes order
    # rows currently interleaved per plane sequentially, which matches
    # planar order, so emit counts in same order
    for r in rows:
      putU16BE(comp, uint16(r.len))
      inc idx
    for r in rows:
      for v in r: comp.add(v)
    for v in comp: result.add(v)
  else:
    putU16BE(result, 0)
    for p in planes:
      for v in p: result.add(v)
