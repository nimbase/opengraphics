import unittest
import std/options
import std/math
import std/strutils
import ../src/opengraphics/psd/document
import ../src/opengraphics/psd/layers
import ../src/opengraphics/psd/text
import ../src/opengraphics/psd/types
import psd_support

const Fixture = "tests/data/01.psd"

test "real file text layers":
  let doc = openPsd(Fixture)
  check not doc.layers[0].isTextLayer()
  check not doc.layers[1].isTextLayer()
  check doc.layers[0].layerText().isNone
  check doc.layers[2].isTextLayer()
  check doc.layers[3].isTextLayer()
  let t = doc.layers[2].layerText().get()
  check t.hasText
  check t.text == "Efficient, expressive, elegant"
  check t.engineText.contains("Efficient, expressive, elegant")
  check t.displayText().contains("Efficient")
  check "ArialMT" in t.fontNames
  check "MyriadPro-Regular" in t.fontNames
  check 40.0 in t.fontSizes
  check t.version == 1
  check t.textVersion == 50
  check abs(t.transform[4] - 60.061309814453125) < 1e-9
  check t.engineData.len > 0
  check t.warpRaw.len > 0
  # raw preserved for future writers
  check t.raw.len == 10344

test "real file long paragraph layer":
  let doc = openPsd(Fixture)
  let t = doc.layers[3].layerText().get()
  check t.text.startsWith("Nim is a statically typed")
  check t.engineText.contains("Python, Ada and Modula")
  check 23.0 in t.fontSizes

test "synthetic TySh round-trips":
  let tysh = buildMinimalTySh("Hello Nim", "ArialMT", 40.0)
  let plane = @[byte(1), byte(2), byte(3), byte(4)]
  let spec = TestLayerSpec(name: "text", top: 0, left: 0, bottom: 2,
    right: 2, planes: @[plane], channelIds: @[int16(0)], useRle: false,
    blendKey: "norm", opacity: 255, flags: 0, lsct: -1, lsdk: -1,
    tysh: tysh)
  let bytes = buildPsd(2, 2, 1, @[plane], false, @[spec])
  let doc = readPsdBytes(bytes)
  check doc.layerCount == 1
  check doc.layers[0].isTextLayer()
  let t = doc.layers[0].layerText().get()
  check t.text == "Hello Nim"
  check t.engineText == "Hello Nim"
  check t.fontNames == @["ArialMT"]
  check t.fontSizes == @[40.0]
  check t.raw == tysh

test "truncated TySh raises":
  expect(PsdError):
    discard parseTySh(@[byte(0), byte(1)])
