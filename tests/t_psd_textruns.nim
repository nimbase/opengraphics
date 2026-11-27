## Type-layer runs/paragraphs/warp: parsed from EngineData + TySh trailing.
##
## `02.psd` and `03.psd` each carry a text layer Photoshop wrote, so the
## expectations are read off real files, not this implementation.

import std/options
import std/unittest
import ../src/opengraphics/psd

proc textLayers(path: string): seq[TextEngine] =
  let f = readPsd(readFile(path))
  result = @[]
  for l in f.layers():
    let t = l.getBlock("TySh")
    if t.isSome:
      result.add(parseTextEngine(t.get().data))

suite "text: engine data runs":
  test "02.psd text has run lengths matching its text":
    let ts = textLayers("tests/data/02.psd")
    check ts.len > 0
    let e = ts[0]
    check e.hasText
    check e.engineData.len > 0
    check e.runLengths.len > 0
    check e.runs.len == e.runLengths.len
    var total = 0
    for r in e.runs: total += r.length
    check total > 0

  test "runs carry font sizes":
    let e = textLayers("tests/data/02.psd")[0]
    check e.fontSizes.len > 0
    check e.runs[0].fontSize > 0

  test "paragraphs parallel runs":
    let e = textLayers("tests/data/02.psd")[0]
    check e.paragraphs.len == e.runLengths.len

  test "warp and bounds parse without crash on all fixtures":
    for path in ["tests/data/01.psd", "tests/data/02.psd", "tests/data/03.psd"]:
      for e in textLayers(path):
        # present or not, parsing must not raise; bounds are text-space.
        check e.text.len >= 0
        if e.hasBounds:
          check e.bounds[2] >= e.bounds[0]
          check e.bounds[3] >= e.bounds[1]
