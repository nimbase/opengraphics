## High-level AI document API (v1: detect + artboards + metadata).

import ./types
import ./reader
import ./detect
import ./pages
import ./xmp

export types

type
  AiDocument* = object
    kind*: AiKind
    pdfVersion*: string
    aiFormatVersion*: int ## Illustrator format version, -1 when absent
    artboards*: seq[Artboard] ## one per PDF page, in page-tree order
    xmp*: XmpMeta
    hasPrivateData*: bool

proc artboardCount*(d: AiDocument): int {.inline.} = d.artboards.len

proc readAiBytes*(data: string, limits = defaultAiLimits()): AiDocument =
  let det = detectAi(data, limits)
  case det.kind
  of EpsLegacy:
    raise newException(AiError,
      "EPS-based .ai (pre-Illustrator 9) is not supported in v1")
  of Unknown:
    raise newException(AiError,
      "not a PDF-based Illustrator file (no %PDF- header)")
  else:
    discard
  let dims = parsePages(data, limits)
  var arts: seq[Artboard] = @[]
  for i, d in dims:
    arts.add(Artboard(index: i, width: d.w, height: d.h, name: ""))
  AiDocument(kind: det.kind, pdfVersion: det.pdfVersion,
    aiFormatVersion: det.aiFormatVersion, artboards: arts,
    xmp: parseXmp(data), hasPrivateData: det.kind == AiNative)

proc readAiBytes*(data: seq[byte],
    limits = defaultAiLimits()): AiDocument =
  readAiBytes(bytesToString(data), limits)

proc openAi*(path: string, limits = defaultAiLimits()): AiDocument =
  readAiBytes(readFile(path), limits)
