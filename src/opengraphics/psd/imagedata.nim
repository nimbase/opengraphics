## Image Data section: the flattened composite in planar order
## (all of channel 1, then channel 2, ...). v1: 8-bit, Raw + RLE + ZIP.

import ./types
import ./reader
import ./pixels
import ./zip

proc decodePlanarChannelRaw(r: var BinReader, w, h: int): seq[byte] =
  r.readBytes(w * h)

proc decodePlanarChannelRle(data: seq[byte], pos: var int,
    rowCounts: seq[uint16], w, h, rowBase: int): seq[byte] =
  result = newSeqOfCap[byte](w * h)
  for y in 0 ..< h:
    let rowLen = int(rowCounts[rowBase + y])
    if pos + rowLen > data.len:
      raise newException(PsdError, "truncated RLE channel data")
    var p = pos
    let stop = pos + rowLen
    var row: seq[byte] = @[]
    # decode exactly w bytes from this row's slice
    while row.len < w:
      if p >= stop:
        raise newException(PsdError, "short RLE row")
      let n = cast[int8](data[p])
      inc p
      if n >= 0:
        let count = int(n) + 1
        if p + count > stop:
          raise newException(PsdError, "truncated RLE literal")
        for i in 0 ..< count:
          row.add(data[p + i])
        p += count
      elif n != -128:
        let count = 1 - int(n)
        if p >= stop:
          raise newException(PsdError, "truncated RLE repeat")
        let v = data[p]
        inc p
        for _ in 0 ..< count:
          row.add(v)
    if row.len != w:
      raise newException(PsdError, "RLE row length mismatch")
    if p != stop:
      # Photoshop row lengths should match consumed bytes; tolerate
      # trailing noop but otherwise require exact consumption.
      discard
    pos = stop
    for b in row:
      result.add(b)

proc decodeComposite*(r: var BinReader, width, height, channels: int,
    isGrayscaleOrRgb: bool): tuple[img: ImageBuf, compression: Compression] =
  let compRaw = r.readU16BE()
  let comp = compressionFromU16(compRaw)
  if width <= 0 or height <= 0:
    raise newException(PsdError, "invalid composite dimensions")
  if comp != Raw and comp != Rle and comp != ZipNoPrediction and
      comp != ZipPrediction:
    raise newException(PsdError,
      "unsupported composite compression " & $compRaw & " (supports Raw, RLE and ZIP)")
  var planes: seq[seq[byte]] = newSeq[seq[byte]](channels)
  if comp == ZipNoPrediction or comp == ZipPrediction:
    let payloadStart = r.pos
    let payload = r.data[payloadStart .. ^1]
    let flat = inflateZlib(payload, width * height * channels)
    for c in 0 ..< channels:
      planes[c] = flat[c * width * height ..< (c + 1) * width * height]
      if comp == ZipPrediction:
        undoPrediction(planes[c], width, height)
    r.pos = r.data.len
  elif comp == Raw:
    for c in 0 ..< channels:
      planes[c] = r.readBytes(width * height)
  else:
    let rowCounts = block:
      var rc = newSeq[uint16](height * channels)
      for i in 0 ..< rc.len:
        rc[i] = r.readU16BE()
      rc
    # remaining bytes to end of section belong to RLE rows; but we do
    # not know section length here, so slurp rest of stream? No:
    # composite runs to EOF, so read all remaining as RLE payload.
    let payloadStart = r.pos
    let payload = r.data[payloadStart .. ^1]
    var pos = 0
    for c in 0 ..< channels:
      planes[c] = decodePlanarChannelRle(payload, pos, rowCounts, width, height, c * height)
    r.pos = payloadStart + pos
  var img = initImageBuf(width, height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let k = y * width + x
      var px = Rgba(r: 0, g: 0, b: 0, a: 255)
      if isGrayscaleOrRgb:
        # RGB mode: planes are R,G,B,(A). Gray mode never takes this path
        # with channels >= 3 in v1, but handle defensively.
        if channels == 1:
          px.r = planes[0][k]
          px.g = planes[0][k]
          px.b = planes[0][k]
        else:
          px.r = planes[0][k]
          if channels >= 2:
            px.g = planes[1][k]
          if channels >= 3:
            px.b = planes[2][k]
          if channels >= 4:
            px.a = planes[3][k]
      else:
        # Grayscale mode: plane 0 is gray, plane 1 (if present) is alpha.
        px.r = planes[0][k]
        px.g = planes[0][k]
        px.b = planes[0][k]
        if channels >= 2:
          px.a = planes[1][k]
      img.data[k] = px
  result = (img, comp)
