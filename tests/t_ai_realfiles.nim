## Real Illustrator files as committed fixtures.
##
## boogie.ai and e2ee.ai are PDF-compatible .ai with catalog
## /OCProperties, ICCBased working spaces, clipping groups, and (in
## e2ee) one Type 1 text run. Both must extract without raising, with
## all art routed to the single content group and paints resolved
## through the ICC alternate space. Counts are pinned so future
## changes degrade loudly rather than silently.
import std/strutils
import unittest
import ../src/opengraphics/ai

proc walk(n: VecNode, texts: var seq[string], paths, clips: var int) =
  case n.kind
  of vnkText:
    texts.add(n.text)
  of vnkPath:
    inc paths
  of vnkClip:
    inc clips
    for c in n.clipped:
      walk(c, texts, paths, clips)
  of vnkGroup:
    for c in n.children:
      walk(c, texts, paths, clips)
  of vnkImage:
    discard

proc load(path: string): VecDocument =
  readAiVectors(readFile("tests/data/" & path))

proc census(doc: VecDocument): tuple[texts: seq[string], paths,
    clips: int] =
  result.texts = @[]
  for l in doc.layers:
    for n in l.children:
      walk(n, result.texts, result.paths, result.clips)

proc layerNames(doc: VecDocument): seq[string] =
  for l in doc.layers:
    result.add(l.name)

test "boogie.ai extracts its clipped vector art":
  # No text-showing operators in the file: ten clipped paths, nothing
  # else. Verified against the raw streams.
  let doc = load("boogie.ai")
  check doc.artboards.len == 1
  check layerNames(doc) == @["Page 1", "Layer 1"]
  check doc.layers[0].children.len == 0
  check doc.layers[1].children.len == 10
  let c = census(doc)
  check c.texts.len == 0
  check c.paths == 10
  check c.clips == 10
  check doc.warnings.len == 2
  let w = doc.warnings.join(" ")
  check "ICCBased" in w
  check "ExtGState" in w

test "e2ee.ai extracts its title and vector art":
  # Exactly one Tj in the file ("E2EE"); the rest is 147 clipped
  # paths. The Type 1 font shapes nothing but keeps Widths advances.
  let doc = load("e2ee.ai")
  check doc.artboards.len == 1
  check layerNames(doc) == @["Page 1", "Layer 1"]
  check doc.layers[0].children.len == 0
  check doc.layers[1].children.len == 148
  let first = doc.layers[1].children[0]
  check first.kind == vnkText
  check first.text == "E2EE"
  let c = census(doc)
  check c.texts == @["E2EE"]
  check c.paths == 147
  check c.clips == 147
  check doc.warnings.len == 4
  let w = doc.warnings.join(" ")
  check "ICCBased" in w
  check "ExtGState" in w
  check "T1_0" in w

test "no paint or text-state operator goes unmapped":
  # Guards the ICCBased alternate mapping and the text-state discard:
  # these warnings meant lost paints and noise, and must not return.
  for path in ["boogie.ai", "e2ee.ai"]:
    let w = load(path).warnings.join(" ")
    check "is not mapped" notin w
    check "without a resolvable paint" notin w
    check "not mapped to vector artwork" notin w
