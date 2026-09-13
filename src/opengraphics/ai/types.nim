## Shared types and errors for the AI reader.
##
## v1 scope: modern PDF-based .ai only (Illustrator 9+), read-only,
## detect + artboards + metadata. No stream decoding, no PGF parsing.

type
  AiError* = object of CatchableError

  AiKind* {.pure.} = enum
    AiNative ## has /AIPrivateData: a true Illustrator .ai file
    AiPdfExport ## has /AIPDFPrivateData: Illustrator-saved .pdf
    PdfWithoutAiData ## valid PDF, no Illustrator markers
    EpsLegacy ## %!PS-Adobe: pre-9 EPS-based .ai, unsupported in v1
    Unknown

  Artboard* = object
    index*: int
    width*: float64 ## MediaBox width in points
    height*: float64 ## MediaBox height in points
    name*: string ## v1: always empty, names live in PGF private data

  XmpMeta* = object
    found*: bool
    title*: string
    creator*: string
    createDate*: string
    isIllustratorDoc*: bool

  AiLimits* = object
    ## Caps applied before walking the page tree. Marker scans are single
    ## linear passes and need no cap; maxScanBytes bounds only the
    ## header sniff window.
    maxPages*: int
    maxScanBytes*: int

proc defaultAiLimits*(): AiLimits =
  AiLimits(maxPages: 1000, maxScanBytes: 8192)
