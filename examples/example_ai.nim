import std/os
import ../src/opengraphics/ai

# Any PDF-based file opens; native .ai adds AIPrivateData and version.
let doc = openAi("tests" / "data" / "pdf" / "m3b_text.pdf")
echo "kind: ", doc.kind, " pdf: ", doc.pdfVersion,
  " ai version: ", doc.aiFormatVersion
echo "artboards: ", doc.artboardCount
for ab in doc.artboards:
  echo "  [", ab.index, "] ", ab.width, "x", ab.height, "pt"
