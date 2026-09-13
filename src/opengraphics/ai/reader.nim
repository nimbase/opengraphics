## Byte-level scanning helpers for AI/PDF parsing (stdlib only).
##
## v1 never decodes streams, so parsing is bounded string scanning over
## the raw file bytes held as a string.

import std/strutils
import ./types

proc sniffHead*(data: string, limits: AiLimits): string =
  ## Header window: the PDF spec tolerates leading bytes before %PDF-,
  ## so sniff a bounded prefix rather than matching at offset 0.
  data[0 ..< min(data.len, limits.maxScanBytes)]

proc sniffTail*(data: string, n: int): string =
  data[max(0, data.len - n) ..< data.len]

proc hasMarker*(data: string, marker: string): bool =
  ## Single linear pass over the whole file. No allocation risk, so no
  ## cap is applied; limits guard structure walks, not scans.
  find(data, marker) >= 0

proc parsePdfVersion*(head: string): string =
  ## Version token after %PDF-, e.g. "1.5". Empty when absent.
  let p = find(head, "%PDF-")
  if p < 0:
    return ""
  var v = ""
  var i = p + 5
  while i < head.len and head[i] notin {'\x00', '\x09', '\x0A', '\x0C',
      '\x0D', '\x20'}:
    v.add(head[i])
    inc i
  if v.len > 0 and v[0] in {'0'..'9'}: v else: ""

proc parseAiFormatVersion*(data: string): int =
  ## Illustrator format version from the %AI5_FileFormat marker, e.g. 14
  ## for modern CC files. Returns -1 when absent or unparseable.
  let p = find(data, "%AI5_FileFormat")
  if p < 0:
    return -1
  var i = p + "%AI5_FileFormat".len
  while i < data.len and data[i] in {' ', '\x09'}:
    inc i
  var digits = ""
  while i < data.len and data[i] in {'0'..'9'}:
    digits.add(data[i])
    inc i
  if digits.len == 0:
    return -1
  try:
    parseInt(digits)
  except ValueError:
    -1

proc bytesToString*(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)
