## Synthetic PSD builder for tests (stdlib only).
## Builds minimal valid PSD bytes: header, colormode, resources,
## layer/mask, composite. Supports Raw, RLE and ZIP, 8-bit RGB/Gray.

import ../src/opengraphics/psd/rle
import ../src/opengraphics/psd/zip

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
  TestMaskSpec* = object
    present*: bool
    top*, left*, bottom*, right*: int32
    defaultColor*: uint8
    flags*: uint8 ## bit0 relative, bit1 disabled, bit2 invert
    real*: bool ## append real flags/bg/rect (36-byte form)
    realFlags*: uint8
    realDefault*: uint8
    realTop*, realLeft*, realBottom*, realRight*: int32
    rawOverride*: seq[byte] ## when non-empty, used verbatim as mask payload

  TestLayerSpec* = object
    name*: string
    top*, left*, bottom*, right*: int32
    planes*: seq[seq[byte]] # one per channel; -2 planes are maskW*maskH bytes
    channelIds*: seq[int16]
    useRle*: bool
    useZip*: bool = false
    zipPrediction*: bool = false
    mask*: TestMaskSpec = TestMaskSpec()
    blendKey*: string
    opacity*: uint8
    clipping*: uint8 = 0
    flags*: uint8
    lsct*: int # -1 = no divider block, else lsct section type 0..3
    lsdk*: int # -1 = none, else nested divider type (wins over lsct)
    tysh*: seq[byte] = @[] # empty = none, else one 8BIM/TySh block in extra

proc maskPayload*(m: TestMaskSpec): seq[byte] =
  ## Builds the mask-data field (after its u32 size prefix).
  result = @[]
  if m.rawOverride.len > 0:
    return m.rawOverride
  if not m.present:
    return @[]
  putI32BE(result, m.top)
  putI32BE(result, m.left)
  putI32BE(result, m.bottom)
  putI32BE(result, m.right)
  result.add(m.defaultColor)
  result.add(m.flags)
  if m.real:
    result.add(m.realFlags)
    result.add(m.realDefault)
    putI32BE(result, m.realTop)
    putI32BE(result, m.realLeft)
    putI32BE(result, m.realBottom)
    putI32BE(result, m.realRight)
  else:
    result.add(0) # padding
    result.add(0)

proc maskDims*(m: TestMaskSpec): tuple[w, h: int] =
  if not m.present or m.rawOverride.len > 0:
    (0, 0)
  else:
    (max(int(m.right - m.left), 0), max(int(m.bottom - m.top), 0))

proc encodeChannelZip*(plane: seq[byte], w, h: int,
    prediction = false): seq[byte] =
  ## Returns compression(2|3) + deflated plane (delta-applied for 3).
  result = @[]
  putU16BE(result, if prediction: 3'u16 else: 2'u16)
  var tmp = plane
  if prediction:
    applyPrediction(tmp, w, h)
  for v in deflateZlib(tmp): result.add(v)

proc buildLayerRecord*(spec: TestLayerSpec): tuple[record: seq[byte], channelData: seq[byte]] =
  let w = int(spec.right - spec.left)
  let h = int(spec.bottom - spec.top)
  let (mw, mh) = maskDims(spec.mask)
  var channelBlobs: seq[seq[byte]] = @[]
  for i, p in spec.planes:
    # The user-mask channel (id -2) is sized by the mask rect
    # (libpsd channel_image.c: mask_channel_length for id -2).
    let (cw, chh) =
      if spec.channelIds[i] == -2: (mw, mh) else: (w, h)
    if spec.useZip:
      channelBlobs.add(encodeChannelZip(p, cw, chh, spec.zipPrediction))
    elif spec.useRle:
      channelBlobs.add(encodeChannelRle(p, cw, chh))
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
  rec.add(spec.clipping)
  rec.add(spec.flags)
  rec.add(0) # filler
  # extra
  var extra: seq[byte] = @[]
  let mp = maskPayload(spec.mask)
  putU32BE(extra, uint32(mp.len)) # mask len
  for v in mp: extra.add(v)
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
  if spec.tysh.len > 0:
    putStr(extra, "8BIM")
    putStr(extra, "TySh")
    putU32BE(extra, uint32(spec.tysh.len))
    for v in spec.tysh: extra.add(v)
    if spec.tysh.len mod 2 != 0:
      extra.add(0)
  putU32BE(rec, uint32(extra.len))
  for v in extra: rec.add(v)
  var cd: seq[byte] = @[]
  for blob in channelBlobs:
    for v in blob: cd.add(v)
  result = (rec, cd)

proc buildPsd*(width, height, channels: int,
    planes: seq[seq[byte]], useRle = false,
    layers: seq[TestLayerSpec] = @[], useZip = false,
    zipPrediction = false, globalMask: seq[byte] = @[]): seq[byte] =
  result = @[]
  putHeader(result, width, height, channels)
  putU32BE(result, 0) # colormode len
  putU32BE(result, 0) # resources len
  # layer and mask
  if layers.len == 0 and globalMask.len == 0:
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
    putU32BE(section, uint32(globalMask.len)) # global mask len
    for v in globalMask: section.add(v)
    putU32BE(result, uint32(section.len))
    for v in section: result.add(v)
  # composite
  if useZip:
    var flat: seq[byte] = @[]
    for p in planes:
      var tmp = p
      if zipPrediction:
        applyPrediction(tmp, width, height)
      for v in tmp: flat.add(v)
    putU16BE(result, if zipPrediction: 3'u16 else: 2'u16)
    for v in deflateZlib(flat): result.add(v)
  elif useRle:
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

proc putF64BE*(b: var seq[byte], v: float64) =
  let bits = cast[uint64](v)
  for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
    b.add(byte((bits shr shift) and 0xFF))

proc encodeUtf16Be*(s: string): seq[byte] =
  ## UTF-16BE without BOM (ASCII fast path covers test strings).
  result = @[]
  for c in s:
    result.add(0)
    result.add(byte(c))

proc encodeParenUtf16*(s: string): seq[byte] =
  ## `(FE FF + UTF-16BE)` paren payload for EngineData names/text.
  result = @[byte(0xFE), byte(0xFF)]
  for v in encodeUtf16Be(s): result.add(v)

proc buildMinimalTySh*(text, fontName: string, fontSize = 40.0,
    tx = 60.0, ty = 357.75): seq[byte] =
  ## Minimal well-formed `TySh` payload the text parser accepts:
  ## version + transform + TEXT field + EngineData with editor text,
  ## one `/Name` and one `/FontSize`. Unknown styling is omitted.
  result = @[]
  putU16BE(result, 1)
  putF64BE(result, 1.0)
  putF64BE(result, 0.0)
  putF64BE(result, 0.0)
  putF64BE(result, 1.0)
  putF64BE(result, tx)
  putF64BE(result, ty)
  putU16BE(result, 50) # textVersion
  putU32BE(result, 16) # descriptorVersion
  # TEXT field: OSType + char count + UTF-16BE
  putStr(result, "TEXT")
  putU32BE(result, uint32(text.len))
  for v in encodeUtf16Be(text): result.add(v)
  # EngineData: key + type + length + ASCII markup
  var engine: seq[byte] = @[]
  putStr(engine, "<< /EngineDict << /Editor << /Text (")
  for v in encodeParenUtf16(text): engine.add(v)
  putStr(engine, ") >> /FontSet [ << /Name (")
  for v in encodeParenUtf16(fontName): engine.add(v)
  putStr(engine, ") >> ] /StyleRun << /FontSize ")
  putStr(engine, $fontSize)
  putStr(engine, " >> >> >>")
  putStr(result, "EngineData")
  putStr(result, "tdta")
  putU32BE(result, uint32(engine.len))
  for v in engine: result.add(v)
