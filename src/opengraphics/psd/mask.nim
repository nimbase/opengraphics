## Layer and global mask records.
##
## v1 parses the mask rectangle, default color and flag bits into a
## usable struct; the raw bytes stay preserved on the layer for
## future write support. Mask pixel data itself travels as the
## channel with id -2 (see layers.decodeChannelData) and is sized by
## the mask rectangle, not the layer rectangle.
##
## Structure reference (clean-room reimplementation, no copied code):
## libpsd src/layer_mask.c psd_get_layer_info (mask size 0/20/36) and
## psd_get_mask_info (global mask), include/libpsd.h psd_layer_mask_info.

import ./types
import ./reader

type
  LayerMask* = object
    hasMask*: bool
    top*, left*, bottom*, right*: int32
    defaultColor*: uint8
    relative*: bool ## mask position is relative to the layer
    disabled*: bool ## mask is disabled (do not apply)
    invert*: bool ## invert mask when blending
    hasReal*: bool ## a second "real" rect/flags pair was present (size 36)
    realTop*, realLeft*, realBottom*, realRight*: int32
    realDefaultColor*: uint8
    realRelative*: bool
    realDisabled*: bool
    realInvert*: bool

  GlobalMask* = object
    hasData*: bool
    colorSpace*: uint16
    colorComponents*: array[4, uint16]
    opacity*: uint16
    kind*: uint8

proc maskWidth*(m: LayerMask): int {.inline.} =
  if not m.hasMask: 0 else: max(int(m.right - m.left), 0)

proc maskHeight*(m: LayerMask): int {.inline.} =
  if not m.hasMask: 0 else: max(int(m.bottom - m.top), 0)

proc realWidth*(m: LayerMask): int {.inline.} =
  if not m.hasReal: 0 else: max(int(m.realRight - m.realLeft), 0)

proc realHeight*(m: LayerMask): int {.inline.} =
  if not m.hasReal: 0 else: max(int(m.realBottom - m.realTop), 0)

proc parseLayerMask*(raw: seq[byte]): LayerMask =
  ## Parse the mask-data field of a layer record (the bytes after the
  ## u32 size prefix, which the caller strips). Size 0 means no mask.
  ## Size 20 carries rect + color + flags + 2 padding bytes; size 36
  ## appends the "real" flags/background/rect. Longer payloads parse
  ## the known prefix and ignore the tail; sizes 1..19 are corrupt.
  if raw.len == 0:
    return LayerMask()
  if raw.len < 20:
    raise newException(PsdError, "truncated layer mask (" & $raw.len &
      " bytes, need 0 or >= 20)")
  var r = initReader(raw)
  let top = r.readI32BE()
  let left = r.readI32BE()
  let bottom = r.readI32BE()
  let right = r.readI32BE()
  let color = r.readU8()
  let flags = r.readU8()
  result = LayerMask(hasMask: true, top: top, left: left, bottom: bottom,
    right: right, defaultColor: color,
    relative: (flags and 1) != 0,
    disabled: (flags and (1 shl 1)) != 0,
    invert: (flags and (1 shl 2)) != 0)
  if raw.len == 20:
    r.skip(2) # padding, only present for size 20
    return
  if r.remaining() >= 18:
    let realFlags = r.readU8()
    result.hasReal = true
    result.realRelative = (realFlags and 1) != 0
    result.realDisabled = (realFlags and (1 shl 1)) != 0
    result.realInvert = (realFlags and (1 shl 2)) != 0
    result.realDefaultColor = r.readU8()
    result.realTop = r.readI32BE()
    result.realLeft = r.readI32BE()
    result.realBottom = r.readI32BE()
    result.realRight = r.readI32BE()
  # any further tail bytes stay preserved in maskRaw only

proc parseGlobalMask*(raw: seq[byte]): GlobalMask =
  ## Parse the global-mask section payload (after its u32 length).
  ## Layout: 2 bytes color space + 4x2 bytes components + 2 bytes
  ## opacity + 1 byte kind (13 bytes minimum).
  if raw.len == 0:
    return GlobalMask()
  if raw.len < 13:
    raise newException(PsdError, "truncated global mask (" & $raw.len &
      " bytes, need 0 or >= 13)")
  var r = initReader(raw)
  result.hasData = true
  result.colorSpace = r.readU16BE()
  for i in 0 ..< 4:
    result.colorComponents[i] = r.readU16BE()
  result.opacity = r.readU16BE()
  result.kind = r.readU8()
