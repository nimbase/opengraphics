## Full color-mode previews: Indexed palette, Lab conversion, multichannel fallback.
##
## Synthetic planes (no fixture needed): the point is that preview never raises
## and maps through the right path.

import std/unittest
import ../src/opengraphics/psd

proc buf(channels: int, w, h, depth: int, fill: uint8): string =
  result = newString(w * h * (depth div 8))
  for i in 0 ..< result.len: result[i] = char(fill)

proc duoBlock(inks: seq[tuple[space: uint16, comps: array[4, uint16],
    name: string]]): string =
  ## 524-byte duotone color-mode data with identity transfer curves.
  var w = initWriter()
  w.putU16(1)
  w.putU16(uint16(inks.len))
  for i in 0 ..< 4:
    if i < inks.len:
      w.putU16(inks[i].space)
      for k in 0 ..< 4: w.putU16(inks[i].comps[k])
    else:
      w.putU16(0xFFFF)
      for k in 0 ..< 4: w.putU16(0)
  for i in 0 ..< 4:
    let nm = if i < inks.len: inks[i].name else: ""
    var blk = newString(64)
    let ln = min(nm.len, 63)
    blk[0] = char(ln)
    for j in 0 ..< ln: blk[1 + j] = nm[j]
    w.put(blk)
  const at = [0.0, 5.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0,
    90.0, 95.0, 100.0]
  for i in 0 ..< 4:
    for a in at: w.putI16(int16(a * 10.0))
    w.putI16(0)
  w.putU16(20)
  result = w.toString()
  while result.len < 524: result.add('\0')

proc alt1066(entries: seq[tuple[space: uint16,
    c: array[4, uint16]]]): string =
  var w = initWriter()
  w.putU16(1)
  w.putU16(uint16(entries.len))
  for e in entries:
    w.putU16(e.space)
    for k in 0 ..< 4: w.putU16(e.c[k])
  w.toString()

proc duoFile(blockData: string,
    res: seq[ImageResource] = @[]): PsdFile =
  result = PsdFile(header: Header(version: Version.Psd,
    channels: 1, width: 3, height: 1, depth: 8,
    colorMode: ColorMode(kind: cmDuotone)))
  result.colorModeData = Span(src: newStringSource(blockData),
    start: 0, stop: blockData.len)
  result.resources = res

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

suite "color: duotone book inks":
  test "density follows the transfer curve":
    check abs(duotoneDensity(@[], 0.3) - 0.3) < 1e-9
    check abs(duotoneDensity(@[(at: 0.2, v: 0.7)], 0.9) - 0.7) < 1e-9
    check abs(duotoneDensity(@[(at: 0.0, v: 0.0), (at: 1.0, v: 1.0)],
      0.3) - 0.3) < 1e-9
    let c = @[(at: 0.2, v: 0.4), (at: 0.8, v: 0.9)]
    check abs(duotoneDensity(c, 0.0) - 0.4) < 1e-9
    check abs(duotoneDensity(c, 1.0) - 0.9) < 1e-9
    check abs(duotoneDensity(c, 0.5) - 0.65) < 1e-9
    check abs(duotoneDensity(@[(at: 0.0, v: 0.0), (at: 1.0, v: 2.0)],
      1.0) - 1.0) < 1e-9

  test "black ink previews as the gray plate":
    let blk = (space: 2'u16, comps: [65535'u16, 65535, 65535, 0],
      name: "Black")
    let f = duoFile(duoBlock(@[blk]))
    let inks = duotoneDisplayInks(f)
    check inks.len == 1
    check inks[0].rgb == [0.0, 0.0, 0.0]
    let img = planesToImage(@["\0\x80\xFF"], 3, 1, 8, 1,
      ColorMode(kind: cmDuotone), @[], inks)
    check img.data[0] == Rgba(r: 0, g: 0, b: 0, a: 255)
    check img.data[1] == Rgba(r: 128, g: 128, b: 128, a: 255)
    check img.data[2] == Rgba(r: 255, g: 255, b: 255, a: 255)

  test "rgb ink resolves from its own block":
    let ink = (space: 0'u16, comps: [65535'u16, 0, 0, 0], name: "Red")
    let inks = duotoneDisplayInks(duoFile(duoBlock(@[ink])))
    check inks.len == 1
    check inks[0].rgb == [1.0, 0.0, 0.0]

  test "book ink takes its color from the 1066 alternate":
    # PANTONE 327 CVC stored by book key; the alternate Lab (45.49, -66, -5)
    # is the teal the reference asserts (r<0.1, g>0.4, b>0.35, g>b).
    let blk = (space: 2'u16, comps: [65535'u16, 65535, 65535, 0],
      name: "Black")
    let book = (space: 0xFFFF'u16, comps: [0'u16, 0, 0, 0],
      name: "PANTONE 327 CVC")
    let alt = alt1066(@[(space: 7'u16, c: [0'u16, 0, 0, 0]),
      (space: 7'u16, c: [4549'u16, 58936, 65036, 0])])
    let f = duoFile(duoBlock(@[blk, book]), @[newImageResource(1066, alt)])
    let inks = duotoneDisplayInks(f)
    check inks.len == 2
    check inks[1].rgb[0] < 0.1
    check inks[1].rgb[1] > 0.4
    check inks[1].rgb[2] > 0.35
    check inks[1].rgb[1] > inks[1].rgb[2]
    check abs(inks[1].rgb[0] - 0.0) < 1e-9
    check abs(inks[1].rgb[1] - 132.0 / 255.0) < 1e-9
    check abs(inks[1].rgb[2] - 114.0 / 255.0) < 1e-9

  test "book inks tint the gray plate":
    let blk = (space: 2'u16, comps: [65535'u16, 65535, 65535, 0],
      name: "Black")
    let book = (space: 0xFFFF'u16, comps: [0'u16, 0, 0, 0],
      name: "PANTONE 327 CVC")
    let alt = alt1066(@[(space: 7'u16, c: [0'u16, 0, 0, 0]),
      (space: 7'u16, c: [4549'u16, 58936, 65036, 0])])
    let f = duoFile(duoBlock(@[blk, book]), @[newImageResource(1066, alt)])
    let inks = duotoneDisplayInks(f)
    let img = planesToImage(@["\x80"], 1, 1, 8, 1,
      ColorMode(kind: cmDuotone), @[], inks)
    check img.data[0] == Rgba(r: 64, g: 97, b: 93, a: 255)
    let ends = planesToImage(@["\0\xFF"], 2, 1, 8, 1,
      ColorMode(kind: cmDuotone), @[], inks)
    check ends.data[0] == Rgba(r: 0, g: 0, b: 0, a: 255)
    check ends.data[1] == Rgba(r: 255, g: 255, b: 255, a: 255)

  test "unknown ink falls back to the gray plate":
    let book = (space: 0xFFFF'u16, comps: [0'u16, 0, 0, 0], name: "Spot")
    check duotoneDisplayInks(duoFile(duoBlock(@[book]))).len == 0
    let img = planesToImage(@["\x80"], 1, 1, 8, 1,
      ColorMode(kind: cmDuotone))
    check img.data[0] == Rgba(r: 128, g: 128, b: 128, a: 255)

  test "non-duotone documents have no display inks":
    var f = PsdFile(header: Header(version: Version.Psd,
      channels: 3, width: 1, height: 1, depth: 8,
      colorMode: ColorMode(kind: cmRgb)))
    check duotoneDisplayInks(f).len == 0
