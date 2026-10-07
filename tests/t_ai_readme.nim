## README vector snippet runs as written.
##
## Mirrors the Illustrator section of README.md against a generated
## document, so the documented calls stay honest.

import std/os
import unittest
import ../src/opengraphics/ai

test "README .ai vector snippet runs as written":
  var vec = VecDocument()
  vec.artboards.add(VecArtboard(name: "A", rect: vecRect(0, 0, 200, 100)))
  var layer = VecLayer(name: "L", visible: true, locked: false)
  var sub = VecSubPath()
  moveTo(sub, vecPt(10, 10))
  lineTo(sub, vecPt(60, 40))
  layer.children.add(newPathNode(VecPath(subs: @[sub]),
    solidPaint(rgbColor(1, 0, 0))))
  vec.layers.add(layer)
  echo "artboards: ", vec.artboards.len, " warnings: ", vec.warnings.len
  for lay in vec.layers:
    for n in lay.children:
      if n.kind == vnkPath:
        echo "path with ", n.path.subs.len, " subpaths"
  var rep = writeAi(vec)
  let path = getTempDir() / "opengraphics_readme.ai"
  writeFile(path, rep.bytes)
  for w in rep.warnings:
    echo "write: ", w
  let back = readAiVectors(readFile(path))
  check back.artboards.len == 1
  check back.layers[0].children.len == 1
  removeFile(path)
