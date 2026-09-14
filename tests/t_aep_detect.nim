import unittest
import ../src/opengraphics/aep/detect
import ../src/opengraphics/aep/types

const Fixture = "tests/data/01.aep"

proc be32(v: int): seq[byte] =
  @[byte((v shr 24) and 0xFF), byte((v shr 16) and 0xFF),
    byte((v shr 8) and 0xFF), byte(v and 0xFF)]

proc rootBytes(magic, form: string): seq[byte] =
  result = @[]
  for c in magic: result.add(byte(c))
  result.add(be32(4))
  for c in form: result.add(byte(c))

test "fixture detected as project":
  let raw = readFile(Fixture)
  let d = detectAep(raw)
  check d.isAep
  check d.formType == "Egg!"
  check d.hasXmp

test "little endian riff rejected":
  expect(AepError):
    discard detectAep(rootBytes("RIFF", "Egg!"))

test "wrong form rejected by checkAep":
  expect(AepError):
    discard checkAep(rootBytes("RIFX", "TEST"))

test "garbage rejected":
  expect(AepError):
    discard detectAep(@[byte(1), 2, 3])
