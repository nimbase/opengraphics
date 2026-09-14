import unittest
import ../src/opengraphics/aep/rifx
import ../src/opengraphics/aep/types

proc be32(v: int): seq[byte] =
  @[byte((v shr 24) and 0xFF), byte((v shr 16) and 0xFF),
    byte((v shr 8) and 0xFF), byte(v and 0xFF)]

proc chunk(id: string, payload: seq[byte]): seq[byte] =
  assert id.len == 4
  result = @[]
  for c in id: result.add(byte(c))
  result.add(be32(payload.len))
  result.add(payload)
  if (payload.len and 1) == 1:
    result.add(0)

proc listChunk(listType: string, body: seq[byte]): seq[byte] =
  assert listType.len == 4
  var payload: seq[byte] = @[]
  for c in listType: payload.add(byte(c))
  payload.add(body)
  chunk("LIST", payload)

proc root(form: string, body: seq[byte]): seq[byte] =
  result = @[]
  for c in "RIFX": result.add(byte(c))
  var payload: seq[byte] = @[]
  for c in form: payload.add(byte(c))
  payload.add(body)
  result.add(be32(payload.len))
  result.add(payload)

proc strBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

test "minimal root parses":
  let body = chunk("svap", @[byte(1), 2, 3, 4]) &
    listChunk("Fold", @[])
  let r = readRifxBytes(root("Egg!", body))
  check r.formType == "Egg!"
  check r.children.len == 2
  check r.children[0].id == "svap"
  check r.children[0].data == @[byte(1), 2, 3, 4]
  check r.children[1].listType == "Fold"
  check r.children[1].children.len == 0
  check r.xmpTail.len == 0

test "odd size padding skipped":
  let body = chunk("qtlg", @[byte(9)]) & chunk("mrid", strBytes("abcd"))
  let r = readRifxBytes(root("Egg!", body))
  check r.children.len == 2
  check r.children[0].data == @[byte(9)]
  check r.children[1].data == strBytes("abcd")

test "bad magic rejected":
  var bad = root("Egg!", @[])
  bad[0] = byte('X')
  expect(AepError):
    discard readRifxBytes(bad)

test "truncated payload rejected":
  var data = root("Egg!", chunk("svap", @[byte(1), 2, 3]))
  data.setLen(data.len - 2)
  expect(AepError):
    discard readRifxBytes(data)

test "child overrun rejected":
  let body = chunk("svap", @[byte(1)]) & @[byte('L'), byte('I')]
  expect(AepError):
    discard readRifxBytes(root("Egg!", body))

test "depth cap enforced":
  var nested: seq[byte] = chunk("leaf", @[byte(0)])
  for _ in 0 ..< 6:
    nested = listChunk("Nest", nested)
  var limits = defaultAepLimits()
  limits.maxDepth = 3
  expect(AepError):
    discard readRifxBytes(root("Egg!", nested), limits)

test "btdk kept opaque":
  let body = listChunk("btdk", strBytes("COS garbage here"))
  let r = readRifxBytes(root("Egg!", body))
  check r.children.len == 1
  check r.children[0].opaque
  check r.children[0].children.len == 0
  check r.children[0].data.len > 0

test "trailing bytes become xmp tail":
  var data = root("Egg!", chunk("svap", @[byte(1), 2, 3, 4]))
  let tail = "<?xpacket test?>"
  for c in tail: data.add(byte(c))
  let r = readRifxBytes(data)
  check r.xmpTail == tail
