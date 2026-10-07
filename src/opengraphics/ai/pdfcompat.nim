## PDF-compatible AI content access through opendocs.
##
## Modern `.ai` files are PDFs, so this module delegates container parsing,
## filter decoding, and content-stream walking to `opendocs/pdf`. It keeps
## only the AI-facing shape: one entry per page with that page's walked
## operators. Unknown PDF features stay errors from opendocs rather than
## becoming silent gaps here.

import ./types
import opendocs/pdf/types
import opendocs/pdf/docmodel
import opendocs/pdf/gstate

export gstate

type
  AiPdfPage* = object
    index*: int
    width*: float64
    height*: float64
    ops*: seq[WalkedOp]

  AiPdfContent* = object
    pages*: seq[AiPdfPage]

proc openPdfDoc*(data: string): PdfDoc =
  ## The open PDF document behind `openAiPdf`, for callers that need
  ## resource lookups (XObjects, shadings) while folding operators.
  try:
    openDoc(data)
  except PdfError as e:
    raise newException(AiError, "PDF-compatible AI open failed: " & e.msg)

proc openAiPdf*(data: string): AiPdfContent =
  ## Open the PDF-compatible portion of an `.ai` file and walk every page.
  ##
  ## Each returned operator carries its resource frame, CTM, form bounding
  ## information, and nesting depth from opendocs. Callers interpret those
  ## values; this procedure does not guess missing semantics.
  try:
    var doc = openDoc(data)
    let boxes = doc.pageBoxes()
    for i in 0 ..< boxes.len:
      result.pages.add(AiPdfPage(index: boxes[i].index,
        width: boxes[i].width, height: boxes[i].height,
        ops: doc.walkNested(i)))
  except PdfError as e:
    raise newException(AiError, "PDF-compatible AI content failed: " & e.msg)
