## Runs the README's PSD example, so the documentation cannot rot.
##
## This is a documentation test as much as a code test. Every accessor below
## was written by copying the README snippet, and several names in that snippet
## had to be corrected because they never existed: `displayName` is an AEP
## field rather than a `LayerRecord` one, `layerText`/`hasMask`/`maskWidth` /
## `maskEnabled` / `maskData` were invented, and `subpaths` and `kindKey` are
## nested one level deeper than shown (`vm.path.records`, `fc.key` with
## `fc.solid.get()`). An example that does not compile is worse than no
## example, so the check is that it runs.
##
## `writePsd` coming back byte-identical is asserted rather than echoed: that is
## the README's headline round-trip claim.
import std/options
import std/os
import std/unittest
import ../src/opengraphics/psd

test "README PSD snippet runs as written":
  let doc = openPsd("tests/data/01.psd")
  echo doc.width, "x", doc.height, " layers: ", doc.layerCount
  for node in doc.layerTree():
    echo node.layer.name()
  check doc.layerByName("nim-lang") == 1

  doc.composite.savePpm("/tmp/readme_preview.ppm")
  renderDocument(doc).savePpm("/tmp/readme_render.ppm")
  check fileExists("/tmp/readme_render.ppm")

  for l in doc.layers:
    if l.isTextLayer():
      let t = l.textOf().get()
      echo l.name(), " -> ", t.engineText, " ", t.fontNames
    if l.mask.kind == mdMask:
      let r = l.mask.maskRect()
      echo l.name(), " mask ", r.width(), "x", r.height()
    if l.hasVectorMask():
      let vm = l.vectorMask().get()
      echo l.name(), " path records=", vm.path.records.len
    if l.hasFillContent():
      let fc = l.fillContent().get()
      if fc.solid.isSome:
        let sf = fc.solid.get()
        echo l.name(), " fill=", fc.key, " (", sf.red, ",", sf.green, ",", sf.blue, ")"
    if l.isSmartObject():
      let pl = l.placedLayer().get()
      echo l.name(), " smart ", pl.kind, " id=", pl.uniqueId

  writeFile("/tmp/readme_copy.psd", writePsd(doc.file))
  check readFile("/tmp/readme_copy.psd") == readFile("tests/data/01.psd")
