import unittest
import ../src/opengraphics/ai
import ../src/opengraphics/ai/legacy

proc close(a, b: float64): bool = abs(a - b) < 1e-9

const Eps = "%!PS-Adobe-3.0 EPSF-3.0\n" &
  "%%BoundingBox: 0 0 100 200\n" &
  "%%Pages: 1\n" &
  "%AI5_FileFormat 6\n" &
  "0 0 moveto\n" &
  "%%EOF\n"

test "envelope reads bbox, pages, and ai version":
  let leg = readLegacyEps(Eps)
  check leg.hasBBox
  check close(leg.bbox.x1, 100.0) and close(leg.bbox.y1, 200.0)
  check leg.pages == 1
  check leg.aiFormatVersion == 6
  check leg.previewKind == epkNone

test "hires box wins over the integer box":
  let leg = readLegacyEps("%!PS-Adobe-3.0 EPSF-3.0\n" &
    "%%BoundingBox: 0 0 10 10\n" &
    "%%HiResBoundingBox: 0.5 0.5 9.5 9.5\n")
  check close(leg.bbox.x0, 0.5) and close(leg.bbox.x1, 9.5)

test "atend trailer boxes resolve":
  let leg = readLegacyEps("%!PS-Adobe-3.0 EPSF-3.0\n" &
    "%%BoundingBox: (atend)\n" &
    "%%Pages: 2\n" &
    "%%BoundingBox: 1 2 30 40\n")
  check leg.hasBBox
  check close(leg.bbox.x0, 1.0) and close(leg.bbox.y1, 40.0)
  check leg.pages == 2

test "dos eps preview section extracts":
  let ps = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 8 8\n"
  var hdr = "\xC5\xD0\xD3\xC6"
  proc u32(v: int) =
    hdr.add(chr(v and 0xFF))
    hdr.add(chr((v shr 8) and 0xFF))
    hdr.add(chr((v shr 16) and 0xFF))
    hdr.add(chr((v shr 24) and 0xFF))
  let preview = "TIFFDATA"
  u32(30) # ps offset
  u32(ps.len) # ps length
  u32(0) # wmf offset
  u32(0) # wmf length
  u32(30 + ps.len) # tiff offset
  u32(preview.len) # tiff length
  hdr.add("\x00\x00") # checksum
  let leg = readLegacyEps(hdr & ps & preview)
  check leg.previewKind == epkTIFF
  check leg.previewBytes == preview
  check leg.hasBBox

test "truncated binary header fails":
  expect(AiError):
    discard readLegacyEps("\xC5\xD0\xD3\xC6\x1E")

test "non-postscript input fails":
  expect(AiError):
    discard readLegacyEps("%PDF-1.5\n")

test "envelope to vector gives artboard plus warning":
  let doc = legacyToVec(readLegacyEps(Eps))
  check doc.artboards.len == 1
  check close(doc.artboards[0].rect.y1, 200.0)
  check doc.layers.len == 1
  check doc.layers[0].children.len == 0
  check doc.warnings.len == 1

test "artwork interpretation refuses loudly":
  expect(AiError):
    discard readLegacyArtwork(Eps)

test "missing bbox fails the vector conversion":
  expect(AiError):
    discard legacyToVec(readLegacyEps("%!PS-Adobe-3.0\n"))
