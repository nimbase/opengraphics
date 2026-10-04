## Sample-level helpers for the depths the format allows: 1, 8, 16 and 32.
##
## Plane data on disk is planar and big-endian. These procs convert between
## that representation and something a caller can use directly:
## `samplesU16` / `samplesF32` widen a plane into typed values, and
## `planeToU8` reduces any supported depth to 8 bits for the renderer and for
## the shared `ImageBuf` pixel model.
##
## Nothing here premultiplies alpha. PSD stores straight alpha throughout.

import ./error
import ./header

proc samplesU16*(bytes: string): seq[uint16] =
  ## Big-endian 16-bit samples. A trailing odd byte is ignored.
  let n = bytes.len div 2
  result = newSeq[uint16](n)
  for i in 0 ..< n:
    result[i] = (uint16(ord(bytes[2 * i])) shl 8) or uint16(ord(bytes[2 * i + 1]))

proc u16ToBytes*(samples: openArray[uint16]): string =
  ## Inverse of `samplesU16`.
  result = newString(samples.len * 2)
  for i, s in samples:
    result[2 * i] = char(s shr 8)
    result[2 * i + 1] = char(s and 0xFF)

proc samplesF32*(bytes: string): seq[float32] =
  ## Big-endian 32-bit float samples. A trailing partial sample is ignored.
  let n = bytes.len div 4
  result = newSeq[float32](n)
  for i in 0 ..< n:
    var bits: uint32 = 0
    for k in 0 ..< 4:
      bits = (bits shl 8) or uint32(ord(bytes[4 * i + k]))
    copyMem(addr result[i], unsafeAddr bits, 4)

proc f32ToBytes*(samples: openArray[float32]): string =
  ## Inverse of `samplesF32`.
  result = newString(samples.len * 4)
  for i, f in samples:
    var bits: uint32 = 0
    copyMem(addr bits, unsafeAddr f, 4)
    for k in 0 ..< 4:
      result[4 * i + k] = char((bits shr ((3 - k) * 8)) and 0xFF)

proc unpackBits*(bytes: string, width, height: int): string =
  ## 1-bit plane to one byte per pixel, MSB first. A set bit reads as white,
  ## which is why `planeToU8` inverts afterwards.
  let stride = (width + 7) div 8
  result = newString(width * height)
  for y in 0 ..< height:
    let rowBase = y * stride
    for x in 0 ..< width:
      let b = ord(bytes[rowBase + (x shr 3)])
      result[y * width + x] = char((b shr (7 - (x and 7))) and 1)

proc planeToU8*(bytes: string, depth, width, height: int): string =
  ## Reduce one plane to 8 bits per pixel, one byte per pixel, row major.
  ## Bit depths are scaled with rounding; 32-bit NaN maps to 0 and out-of-
  ## range values are clamped.
  case depth
  of 1:
    let bits = unpackBits(bytes, width, height)
    result = newString(bits.len)
    for i, b in bits:
      # a set bit means white in the file, so it becomes 0 after inverting
      result[i] = if b == char(1): char(0) else: char(0xFF)
  of 8:
    result = bytes[0 ..< width * height]
  of 16:
    result = newString(width * height)
    let s = samplesU16(bytes)
    for i in 0 ..< width * height:
      result[i] = char(((int(s[i]) * 255) + 32767) div 65535)
  of 32:
    result = newString(width * height)
    let f = samplesF32(bytes)
    for i in 0 ..< width * height:
      let v = f[i]
      if v != v: # NaN
        result[i] = char(0)
      elif v <= 0.0'f32:
        result[i] = char(0)
      elif v >= 1.0'f32:
        result[i] = char(0xFF)
      else:
        result[i] = char(int(v * 255.0'f32 + 0.5'f32))
  else:
    unsupported("plane to 8-bit conversion for depth " & $depth)

proc interleave*(planes: seq[string], width, height: int): string =
  ## Planar to interleaved: `planes[0][0] planes[1][0] ... planes[0][1] ...`.
  ## Used for the Color channels of a layer or of the merged image.
  if width <= 0 or height <= 0 or planes.len == 0:
    return ""
  result = newString(width * height * planes.len)
  var o = 0
  for i in 0 ..< width * height:
    for p in planes:
      result[o] = p[i]
      inc o

proc deinterleave*(data: string, bandCount, width, height: int): seq[string] =
  ## Interleaved to planar. Inverse of `interleave`.
  result = newSeq[string](bandCount)
  let n = width * height
  if bandCount <= 0 or data.len < n * bandCount:
    return
  for b in 0 ..< bandCount:
    var plane = newString(n)
    var o = 0
    for i in 0 ..< n:
      plane[i] = data[i * bandCount + b]
      inc o
    result[b] = plane
