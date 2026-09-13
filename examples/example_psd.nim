import std/os
import ../src/opengraphics/psd

let doc = openPsd("tests" / "data" / "01.psd")
echo doc.width, "x", doc.height, " layers: ", doc.layerCount
for node in doc.layerTree():
  echo node.layer.displayName()
doc.composite.savePpm("preview.ppm")
doc.composite.saveImage("preview.jpg")