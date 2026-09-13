## HarfBuzz text shaping (M3b).
##
## shapeText runs the Unicode text of one run through HarfBuzz at
## 1000 units per em, returning glyph ids plus advances for width
## measurement and the M6 writer's subsetting. Fonts come from embedded
## FontFile streams (TrueType/OpenType); base-14 fonts have no program
## and Adobe Type 1 is not supported by HarfBuzz, both reported as
## clear errors rather than silent zeros.

import harfbuzz
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters

type
  ShapedGlyph* = object
    glyphId*: int
    xAdvance*: float64 ## font units at 1000 upm
    yAdvance*: float64
    cluster*: int ## byte index into the input text

  ShapedRun* = object
    glyphs*: seq[ShapedGlyph]
    text*: string

proc loadFontBytes*(fontDict: CosObj, d: var PdfDoc): string =
  ## Decode the embedded program from /FontDescriptor (/FontFile2 or
  ## /FontFile3 preferred, /FontFile last). Fails when the font is not
  ## embedded.
  var desc = fontDict.dictGet("FontDescriptor")
  if desc.kind == coRef:
    desc = d.resolve(desc)
  if desc.kind != coDict:
    pdfFail("no /FontDescriptor: font is not embedded, " &
      "shaping needs an embedded program")
  for key in ["FontFile2", "FontFile3", "FontFile"]:
    var s = desc.dictGet(key)
    if s.kind == coRef:
      s = d.resolve(s)
    if s.kind == coStream:
      let raw = decodeCosStream(s)
      if raw.len == 0:
        pdfFail("empty embedded font program in /" & key)
      return raw
  pdfFail("no embedded font program (/FontFile, /FontFile2 or " &
    "/FontFile3) in /FontDescriptor")

proc shapeText*(fontBytes, text: string): ShapedRun =
  ## Shape UTF-8 text with HarfBuzz. Advances are horizontal font
  ## units at 1000 upm; divide by 1000 and scale by the font size for
  ## text-space advances.
  result = ShapedRun(glyphs: @[], text: text)
  if text.len == 0:
    return
  if fontBytes.len == 0:
    pdfFail("cannot shape text with empty font program")
  let blob = hb_blob_create(cstring(fontBytes), cuint(fontBytes.len),
    HB_MEMORY_MODE_READONLY, nil, nil)
  if blob == nil:
    pdfFail("HarfBuzz refused the font program")
  let face = hb_face_create(blob, 0)
  let font = hb_font_create(face)
  hb_font_set_scale(font, 1000, 1000)
  if hb_face_get_glyph_count(face) == 0:
    hb_font_destroy(font)
    hb_face_destroy(face)
    hb_blob_destroy(blob)
    pdfFail("font program has no glyphs (Adobe Type 1 programs are " &
      "not supported by HarfBuzz; embed TrueType or OpenType)")
  let buf = hb_buffer_create()
  hb_buffer_add_utf8(buf, cstring(text), cint(text.len), 0,
    cint(text.len))
  hb_buffer_guess_segment_properties(buf)
  hb_shape(font, buf, nil, 0)
  var nInfo: cuint = 0
  var nPos: cuint = 0
  let infos = cast[ptr UncheckedArray[hb_glyph_info_t]](
    hb_buffer_get_glyph_infos(buf, addr nInfo))
  let poss = cast[ptr UncheckedArray[hb_glyph_position_t]](
    hb_buffer_get_glyph_positions(buf, addr nPos))
  let n = min(int(nInfo), int(nPos))
  for i in 0 ..< n:
    result.glyphs.add(ShapedGlyph(glyphId: int(infos[i].codepoint),
      xAdvance: float64(poss[i].x_advance),
      yAdvance: float64(poss[i].y_advance),
      cluster: int(infos[i].cluster)))
  hb_buffer_destroy(buf)
  hb_font_destroy(font)
  hb_face_destroy(face)
  hb_blob_destroy(blob)
