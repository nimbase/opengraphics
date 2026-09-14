## Comp header decoder (`cdta`).
##
## Offsets from plans/aep-spec.md, validated against tests/data/01.aep
## (width 1920 and height 1080 at 140/142, time scale 3 at 5, duration
## 2812 at 45). Suffix fields past the pixel ratio are only partly
## documented, so framerate is exposed raw plus a best effort guess.

import ./types
import ./rifx
import ./reader

const
  CdtaMinLen* = 172 ## bytes needed up to the rate fields
  FfffTime* = 0xFFFF ## out time value meaning "same as duration"

proc parseCdta*(data: openArray[byte]): tuple[width, height, timeScale,
    frRaw: int, playhead, inR, outR, duration, attr: int,
    parW, parH: int] =
  if data.len < CdtaMinLen:
    raise newException(AepError,
      "truncated cdta (" & $data.len & " bytes, need " &
      $CdtaMinLen & ")")
  let timeScale = int(readU16BEAt(data, 5, "cdta time scale"))
  let playhead = int(readU16BEAt(data, 21, "cdta playhead"))
  let inR = int(readU16BEAt(data, 29, "cdta in time"))
  let outR = int(readU16BEAt(data, 37, "cdta out time"))
  let duration = int(readU16BEAt(data, 45, "cdta duration"))
  let attr = int(data[139])
  let width = int(readU16BEAt(data, 140, "cdta width"))
  let height = int(readU16BEAt(data, 142, "cdta height"))
  let parW = int(readU32BEAt(data, 144, "cdta pixel ratio w"))
  let parH = int(readU32BEAt(data, 148, "cdta pixel ratio h"))
  let frRaw = int(readU16BEAt(data, 164, "cdta framerate"))
  (width, height, timeScale, frRaw, playhead, inR, outR, duration, attr,
    parW, parH)

proc guessFramerate*(frRaw, centiRaw: int): float64 =
  ## Best effort only. The spec framerate offset reads 0 in the fixture
  ## while the u32 at 168 reads 2997 (29.97 fps as centi fps, followed
  ## by 180 and 360), so prefer a centi value near a standard rate,
  ## then a sane raw value.
  const standard = [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0,
    120.0]
  if centiRaw >= 100 and centiRaw <= 12000:
    let f = float64(centiRaw) / 100.0
    for s in standard:
      if abs(f - s) < 0.05:
        return f
  if frRaw >= 1 and frRaw <= 240:
    return float64(frRaw)
  0.0

proc compOfItem*(id: uint32, name: string, node: RifxChunk): CompInfo =
  let ci = node.findFirst("cdta")
  if ci < 0:
    raise newException(AepError, "comp item " & $id & " without cdta")
  let d = node.children[ci].data
  let f = parseCdta(d)
  var centiRaw = 0
  if d.len >= 172:
    centiRaw = int(readU32BEAt(d, 168, "cdta rate"))
  var outRaw = f.outR
  if outRaw == FfffTime:
    outRaw = -1
  CompInfo(id: id, name: name, width: f.width, height: f.height,
    timeScale: f.timeScale, framerate: guessFramerate(f.frRaw, centiRaw),
    framerateRaw: f.frRaw, playhead: f.playhead, inTime: f.inR,
    outTime: outRaw, duration: f.duration)
