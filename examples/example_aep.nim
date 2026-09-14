import std/os
import ../src/opengraphics/aep

let doc = openAep("tests" / "data" / "01.aep")
echo "form: ", doc.formType, " comps: ", doc.compCount,
  " items: ", doc.itemCount, " xmp: ", doc.hasXmp
for c in doc.comps:
  echo "comp ", c.info.id, " \"", c.info.name, "\" ",
    c.info.width, "x", c.info.height, " ts=", c.info.timeScale,
    " fps=", c.info.framerate, " dur(raw)=", c.info.duration,
    " layers=", c.layers.len, " views=", c.viewLayers
  for l in c.layers:
    echo "  layer ", l.id, " \"", l.name, "\" kind=", l.kind,
      " src=", l.sourceId
    for p in layerTransform(c, l.id):
      if p.value.kind == PropVector and not p.value.isAnimated:
        echo "    ", p.matchName, " = ", p.value.values
for f in doc.footage:
  echo "footage ", f.id, " \"", f.name, "\" ", f.assetType,
    " ", f.width, "x", f.height, " ", f.filePath
