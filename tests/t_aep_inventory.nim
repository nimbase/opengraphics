import unittest
import std/math
import ../src/opengraphics/aep/document
import ../src/opengraphics/aep/types

const Fixture = "tests/data/01.aep"

proc be32(v: int): seq[byte] =
  @[byte((v shr 24) and 0xFF), byte((v shr 16) and 0xFF),
    byte((v shr 8) and 0xFF), byte(v and 0xFF)]

proc putU16(b: var seq[byte], off, v: int) =
  b[off] = byte((v shr 8) and 0xFF)
  b[off + 1] = byte(v and 0xFF)

proc putU32(b: var seq[byte], off, v: int) =
  b[off] = byte((v shr 24) and 0xFF)
  b[off + 1] = byte((v shr 16) and 0xFF)
  b[off + 2] = byte((v shr 8) and 0xFF)
  b[off + 3] = byte(v and 0xFF)

proc chunk(id: string, payload: seq[byte]): seq[byte] =
  result = @[]
  for c in id: result.add(byte(c))
  result.add(be32(payload.len))
  result.add(payload)
  if (payload.len and 1) == 1:
    result.add(0)

proc listChunk(listType: string, body: seq[byte]): seq[byte] =
  var payload: seq[byte] = @[]
  for c in listType: payload.add(byte(c))
  payload.add(body)
  chunk("LIST", payload)

proc strBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc idtaBytes(typ, id: int): seq[byte] =
  result = newSeq[byte](59)
  putU16(result, 0, typ)
  putU32(result, 16, id)

proc cdtaBytes(w, h, ts: int): seq[byte] =
  result = newSeq[byte](172)
  putU16(result, 5, ts)
  putU16(result, 45, 900)
  putU16(result, 140, w)
  putU16(result, 142, h)
  putU16(result, 164, 30)

proc ldtaBytes(id: int, ltype: int, name: string): seq[byte] =
  result = newSeq[byte](152)
  putU32(result, 0, id)
  putU16(result, 10, 1)
  putU16(result, 110, 1)
  result[131] = byte(ltype)
  for i, c in name:
    if i < 31:
      result[64 + i] = byte(c)

proc syntheticDoc(): seq[byte] =
  let layr = listChunk("Layr",
    chunk("ldta", ldtaBytes(3, 4, "Box")) &
    chunk("Utf8", strBytes("Box")))
  let item = listChunk("Item",
    chunk("idta", idtaBytes(4, 7)) &
    chunk("Utf8", strBytes("Test Comp")) &
    chunk("cdta", cdtaBytes(320, 240, 30)) & layr)
  let fold = listChunk("Fold", chunk("fdta", newSeq[byte](14)) & item)
  result = @[]
  for c in "RIFX": result.add(byte(c))
  var payload: seq[byte] = @[]
  for c in "Egg!": payload.add(byte(c))
  payload.add(fold)
  result.add(be32(payload.len))
  result.add(payload)

test "synthetic inventory parses":
  let doc = readAepBytes(syntheticDoc())
  check doc.formType == "Egg!"
  check doc.itemCount == 1
  check doc.compCount == 1
  let c = doc.comps[0]
  check c.info.id == 7
  check c.info.name == "Test Comp"
  check c.info.width == 320
  check c.info.height == 240
  check c.info.timeScale == 30
  check c.layers.len == 1
  check c.layers[0].id == 3
  check c.layers[0].kind == LayerShape
  check c.layers[0].name == "Box"

test "fixture inventory pinned":
  let doc = openAep(Fixture)
  check doc.compCount == 1
  check doc.itemCount == 1
  check doc.hasXmp
  let c = doc.comps[0]
  check c.info.id == 1
  check c.info.name == "Comp 1"
  check c.info.width == 1920
  check c.info.height == 1080
  check c.info.timeScale == 3
  check c.info.duration == 2812
  check c.info.outTime == -1
  check abs(c.info.framerate - 29.97) < 0.01
  check c.layers.len == 1
  check c.layers[0].id == 13
  check c.layers[0].kind == LayerText
  check c.layers[0].name == "Nim is awesome!"
  check c.layers[0].inTime == 0
  check c.layers[0].outTime == 2812
  check c.viewLayers == 11
  check doc.footage.len == 0

test "fixture transform statics":
  let doc = openAep(Fixture)
  let c = doc.comps[0]
  let tr = layerTransform(c, 13)
  check tr.len == 7
  let pos = getProp(tr, "ADBE Position")
  check pos.components == 3
  check pos.isPosition
  check not pos.isAnimated
  check abs(pos.values[0] - 441.8056) < 0.001
  check abs(pos.values[1] - 587.38) < 0.001
  check pos.values[2] == 0.0
  let scale = getProp(tr, "ADBE Scale")
  check abs(scale.values[0] - 3.7751) < 0.001
  check abs(scale.values[1] - 3.7751) < 0.001
  let rx = getProp(tr, "ADBE Rotate X")
  check rx.values == @[0.0]
