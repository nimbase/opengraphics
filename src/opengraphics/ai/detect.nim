## File-kind detection for .ai files.
##
## Detection is byte-signature scanning, never the extension: modern
## files carry %PDF- in the head window, legacy pre-9 files carry
## %!PS-Adobe. A native .ai is distinguished from an Illustrator-saved
## .pdf by /AIPrivateData vs /AIPDFPrivateData.

import std/strutils
import ./types
import ./reader

type
  Detection* = object
    kind*: AiKind
    pdfVersion*: string
    aiFormatVersion*: int ## -1 when the marker is absent

proc detectAi*(data: string, limits = defaultAiLimits()): Detection =
  let head = sniffHead(data, limits)
  if find(head, "%PDF-") < 0:
    if find(head, "%!PS-Adobe") >= 0:
      return Detection(kind: EpsLegacy, pdfVersion: "",
        aiFormatVersion: -1)
    return Detection(kind: Unknown, pdfVersion: "", aiFormatVersion: -1)
  let kind =
    if hasMarker(data, "/AIPrivateData"): AiNative
    elif hasMarker(data, "/AIPDFPrivateData"): AiPdfExport
    else: PdfWithoutAiData
  Detection(kind: kind, pdfVersion: parsePdfVersion(head),
    aiFormatVersion: parseAiFormatVersion(data))
