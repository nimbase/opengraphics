## Full color-mode previews: Indexed palette, Lab conversion, multichannel fallback.
##
## Synthetic planes (no fixture needed): the point is that preview never raises
## and maps through the right path.

import std/unittest
import ../src/opengraphics/psd

proc buf(channels: int, w, h, depth: int, fill: uint8): string =
  result = newString(w * h * (depth div 8))
  for i in 0 ..< result.len: result[i] = char(fill)

suite "color: indexed palette":
  test "index maps through the 768-byte palette":
    let planes = @[buf(1, 2, 1, 8, 1)]
    var pal: seq[array[3, uint8]] = newSeq[array[3, uint8]](256)
    pal[1] = [255'u8, 0, 0]
    let img = planesToImage(planes, 2, 1, 8, 1,
      ColorMode(kind: cmIndexed), pal)
    check img.data[0] == Rgba(r: 255, g: 0, b: 0, a: 255)

  test "indexedPalette reads 768 bytes":
    var cmd = newString(768)
    for i in 0 ..< 256:
      cmd[i * 3] = char(i)
      cmd[i * 3 + 1] = char(255 - i)
      cmd[i * 3 + 2] = char(0)
    var f = PsdFile(header: Header(version: Version.Psd,
      channels: 1, width: 1, height: 1, depth: 8,
      colorMode: ColorMode(kind: cmIndexed)))
    f.colorModeData = Span(src: newStringSource(cmd), start: 0, stop: 768)
    let pal = indexedPalette(f)
    check pal.len == 256
    check pal[0] == [0'u8, 255, 0]

suite "color: lab preview":
  test "white-ish Lab converts near white":
    # L=100 (255), a=b=0 (128,128) -> white.
    let planes = @[buf(1, 1, 1, 8, 255), buf(1, 1, 1, 8, 128),
      buf(1, 1, 1, 8, 128)]
    let img = planesToImage(planes, 1, 1, 8, 3, ColorMode(kind: cmLab))
    check img.data[0].r > 250
    check img.data[0].g > 250
    check img.data[0].b > 250

  test "black Lab converts near black":
    let planes = @[buf(1, 1, 1, 8, 0), buf(1, 1, 1, 8, 128),
      buf(1, 1, 1, 8, 128)]
    let img = planesToImage(planes, 1, 1, 8, 3, ColorMode(kind: cmLab))
    check img.data[0].r < 5
    check img.data[0].g < 5
    check img.data[0].b < 5

suite "color: multichannel fallback":
  test "preview count falls back to 3, never raises":
    var f = PsdFile(header: Header(version: Version.Psd,
      channels: 5, width: 1, height: 1, depth: 8,
      colorMode: ColorMode(kind: cmMultichannel)))
    check previewChannelCount(f) == 3
