import unittest
import ../src/opengraphics/psd
import ./psd_support

proc leaf(name: string, v: byte): TestLayerSpec =
  TestLayerSpec(name: name, top: 0, left: 0, bottom: 1, right: 1,
    planes: @[@[v], @[v], @[v]], channelIds: @[int16(0), 1, 2],
    useRle: false, blendKey: "norm", opacity: 255, flags: 0,
    lsct: -1, lsdk: -1)

proc mark(name: string, lsct = -1, lsdk = -1): TestLayerSpec =
  TestLayerSpec(name: name, top: 0, left: 0, bottom: 0, right: 0,
    planes: @[], channelIds: @[],
    useRle: false, blendKey: "norm", opacity: 255, flags: 0,
    lsct: lsct, lsdk: lsdk)

proc docOf(specs: seq[TestLayerSpec]): Document =
  let p = @[byte(1)]
  readPsdBytes(buildPsd(1, 1, 3, @[p, p, p], layers = specs))

test "nested groups nest bottom-to-top":
  # file order: BG, divOuter, A, divInner, B, C, inner, D, outer
  let doc = docOf(@[
    leaf("BG", 1),
    mark("divOuter", lsct = 3),
    leaf("A", 2),
    mark("divInner", lsct = 3),
    leaf("B", 3),
    leaf("C", 4),
    mark("Inner", lsct = 1),
    leaf("D", 5),
    mark("Outer", lsct = 1),
  ])
  let tree = doc.layerTree()
  check tree.len == 2
  check tree[0].kind == lnLayer
  check tree[0].layer.name() == "BG"
  let outer = tree[1]
  check outer.kind == lnGroup
  check outer.opened
  check outer.layer.name() == "Outer"
  check outer.children.len == 3
  check outer.children[0].layer.name() == "A"
  check outer.children[2].layer.name() == "D"
  let inner = outer.children[1]
  check inner.kind == lnGroup
  check inner.layer.name() == "Inner"
  check inner.children.len == 2
  check inner.children[0].layer.name() == "B"
  check inner.children[1].layer.name() == "C"

test "closed folder reports opened=false":
  let doc = docOf(@[
    mark("div", lsct = 3),
    leaf("A", 1),
    mark("G", lsct = 2),
  ])
  let tree = doc.layerTree()
  check tree.len == 1
  check tree[0].kind == lnGroup
  check not tree[0].opened
  check tree[0].children.len == 1

test "type 0 divider is a normal layer":
  let doc = docOf(@[leaf("A", 1), mark("weird", lsct = 0), leaf("B", 2)])
  let tree = doc.layerTree()
  check tree.len == 3
  for n in tree:
    check n.kind == lnLayer

test "lsct takes priority over lsdk":
  # Both the reference and this implementation read `lsct` first and only fall
  # back to `lsdk`. An `lsct` of 0 ("other", an ordinary layer) therefore wins
  # and the group markers do not nest. The old v1 reader had this backwards.
  let doc = docOf(@[
    mark("div", lsct = 0, lsdk = 3),
    leaf("A", 1),
    mark("G", lsct = 1),
  ])
  # `div` no longer opens a group, so `G` has nothing to close and stands
  # alone as an empty group at the top level.
  let tree = doc.layerTree()
  check tree.len == 3
  check tree[0].kind == lnLayer
  check tree[1].kind == lnLayer
  check tree[2].kind == lnGroup
  check tree[2].children.len == 0

test "lsdk is used when there is no lsct":
  let doc = docOf(@[
    mark("div", lsdk = 3),
    leaf("A", 1),
    mark("G", lsdk = 1),
  ])
  let tree = doc.layerTree()
  check tree.len == 1
  check tree[0].kind == lnGroup
  check tree[0].children.len == 1

test "malformed nesting degrades gracefully":
  let stray = docOf(@[mark("G", lsct = 1)]).layerTree()
  check stray.len == 1
  check stray[0].kind == lnGroup
  check stray[0].children.len == 0
  let unclosed = docOf(@[mark("div", lsct = 3), leaf("A", 1)]).layerTree()
  check unclosed.len == 1
  check unclosed[0].kind == lnGroup
  check unclosed[0].children.len == 1

test "empty group":
  let doc = docOf(@[mark("div", lsct = 3), mark("G", lsct = 1)])
  let tree = doc.layerTree()
  check tree.len == 1
  check tree[0].kind == lnGroup
  check tree[0].children.len == 0

test "flattenTree is pre-order without dividers":
  let doc = docOf(@[
    leaf("BG", 1),
    mark("divOuter", lsct = 3),
    leaf("A", 2),
    mark("divInner", lsct = 3),
    leaf("B", 3),
    mark("Inner", lsct = 1),
    mark("Outer", lsct = 1),
  ])
  var names: seq[string] = @[]
  for l in flattenTree(doc.layerTree()):
    names.add(l.name())
  check names == @["BG", "Outer", "A", "Inner", "B"]
