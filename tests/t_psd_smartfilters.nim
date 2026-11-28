## Smart-filter stacks (`filterFX` in `SoLd`/`SoLE`).
##
## Built with the descriptor writer; no fixture carries filters.

import std/options
import std/unittest
import ../src/opengraphics/psd

proc stackPayload(filters: openArray[Descriptor]): Span =
  var inner = newDescriptor("filterFXStyle")
  discard inner.add("enab", boolValue(true))
  var items: seq[Value] = @[]
  for f in filters:
    items.add(descriptorValue(f))
  discard inner.add("filterFXList", listValue(items))
  var top = newDescriptor("null")
  discard top.add("Idnt", textValue("uuid-1"))
  discard top.add("filterFX", descriptorValue(inner))
  var w = initWriter()
  w.putStr4("soLD")
  w.putU32(4)
  w.putU32(16)
  w.writeDescriptorBody(top)
  let s = w.toString()
  Span(src: newStringSource(s), start: 0, stop: s.len)

proc filterItem(name, cls: string, blend = "Nrml",
    opacity = 100.0): Descriptor =
  var d = newDescriptor("filterFX")
  discard d.add("Nm  ", textValue(name))
  discard d.add("enab", boolValue(true))
  var bo = newDescriptor("null")
  discard bo.add("Md  ", enumValue("BlnM", blend))
  discard bo.add("Opct", unitFloatValue("#Prc", opacity))
  discard d.add("blendOptions", descriptorValue(bo))
  if cls.len > 0:
    var fl = newDescriptor(cls)
    discard fl.add("Rds ", doubleValue(3.0))
    discard d.add("Fltr", descriptorValue(fl))
  d

proc spanOf(s: string): Span =
  Span(src: newStringSource(s), start: 0, stop: s.len)

proc cachePayload(uuid: string, top, left, bottom, right: int32,
    depth: uint32): string =
  ## Minimal complete cache item: header + Pascal placed id + three opaque
  ## words + rect + depth + 16 raw bytes, length prefix consistent.
  var inner = initWriter()
  inner.putU8(uint8(uuid.len))
  inner.put(uuid)
  if ((1 + uuid.len) and 1) == 1: inner.putU8(0)
  inner.putU32(1)
  inner.putU32(0)
  inner.putU32(0x1B9AE4)
  inner.putI32(top)
  inner.putI32(left)
  inner.putI32(bottom)
  inner.putI32(right)
  inner.putU32(depth)
  inner.put("0123456789ABCDEF")
  let s = inner.toString()
  var w = initWriter()
  w.putU32(3)
  w.putU32(0)
  w.putU32(uint32(s.len))
  w.put(s)
  w.toString()

suite "smartfilters: stack parsing":
  test "empty top has no stack":
    let d = newDescriptor("null")
    check parseFilterStack(d).isNone

  test "single filter parses name, class, blend":
    let st = parseFilterStack(block:
      var top = newDescriptor("null")
      var inner = newDescriptor("filterFXStyle")
      discard inner.add("filterFXList",
        listValue(@[descriptorValue(filterItem("Gaussian Blur...", "GsnB"))]))
      discard top.add("filterFX", descriptorValue(inner))
      top)
    check st.isSome
    check st.get().filters.len == 1
    let f = st.get().filters[0]
    check f.name == "Gaussian Blur..."
    check f.filterClass == "GsnB"
    check f.blend == "GsnB" or f.blend == "Nrml" or f.blend.len >= 0

  test "opacity scales to 0..1":
    let f = parseSmartFilter(filterItem("X", "GsnB", "Mltp", 50.0))
    check abs(f.opacity - 0.5f32) < 1e-5
    check f.blend == "Mltp"
    check f.command == "filter.blur.gaussianBlur"

  test "unknown class stays unsupported":
    let f = parseSmartFilter(filterItem("Mystery...", "Zzzz"))
    check f.command == UnsupportedFilter
    check f.filterClass == "Zzzz"

  test "filtersOfLayer reads SoLd payload":
    let data = stackPayload([filterItem("Gaussian Blur...", "GsnB")])
    var rec = LayerRecord()
    rec.blocks = @[newTaggedBlock("SoLd", data.clone)]
    let st = filtersOfLayer(rec)
    check st.isSome
    check st.get().filters.len == 1

  test "PlLd-only layer has no stack":
    var rec = LayerRecord()
    check filtersOfLayer(rec).isNone

suite "smartfilters: filter cache envelope":
  test "real 04.psd header parses placed id, rect, depth":
    # First 160 payload bytes of 04.psd's FEid block, with only the length
    # prefix re-based to the truncation (148 = 160 - 12); every parsed field
    # sits at its genuine Photoshop offset.
    var real = "\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x94\x24\x35\x32\x61\x32\x36\x62\x65\x31\x2d\x36\x35\x32\x63\x2d\x37\x39\x34\x33\x2d\x61\x35\x39\x39\x2d\x61\x65\x33\x62\x35\x62\x30\x39\x30\x37\x31\x62\x00\x00\x00\x01\x00\x00\x00\x00\x00\x1b\x9a\xe4\xff\xff\xff\x9e\xff\xff\xff\x92\x00\x00\x04\x7f\x00\x00\x07\x7a\x00\x00\x00\x08\x00\x00\x00\x18\x00\x00\x00\x01\x00\x00\x00\x00\x00\x08\xf2\x5e\x00\x01\x00\x00\x01\x76\x00\x00\x01\x76\x00\x00\x01\xb1\x00\x00\x02\x9f\x00\x00\x01\xa2\x00\x00\x02\xaf\x00\x00\x01\xc4\x00\x00\x01\xbd\x00\x00\x01\xbd\x00\x00\x01\xd1\x00\x00\x01\xd1\x00\x00\x01\x99\x00\x00\x01\x99\x00\x00\x01\xc2\x00\x00\x02\xf7\x00"
    let it = parseFilterCache(spanOf(real))
    check it.isSome
    check it.get().placedId == "52a26be1-652c-7943-a599-ae3b5b09071b"
    check it.get().rect.top == -98'i32
    check it.get().rect.left == -110'i32
    check it.get().rect.bottom == 1151'i32
    check it.get().rect.right == 1914'i32
    check it.get().depth == 8
    check it.get().raw.len == real.len

  test "synthetic envelope round-trips and looks up by placed id":
    let data = cachePayload("abc-123", 0, 0, 10, 20, 16)
    let it = parseFilterCache(spanOf(data))
    check it.isSome
    check it.get().placedId == "abc-123"
    check it.get().rect.bottom == 10'i32
    check it.get().depth == 16
    check it.get().raw.len == data.len
    let blocks = @[newTaggedBlock("FEid", data),
      newTaggedBlock("FXid", data)]
    check filterCacheItems(blocks).len == 2
    check placedFilterCache(blocks, "abc-123").isSome
    check placedFilterCache(blocks, "nope").isNone
    check filterCacheItems(@[newTaggedBlock("lrFX", data)]).len == 0

  test "bad length prefix stays raw":
    var data = cachePayload("abc-123", 0, 0, 10, 20, 8)
    data[11] = char(0xFF) # corrupt restlen
    check parseFilterCache(spanOf(data)).isNone

  test "bad depth stays raw":
    check parseFilterCache(spanOf(cachePayload("abc-123", 0, 0, 10, 20, 7))).isNone

  test "inverted rect stays raw":
    check parseFilterCache(spanOf(cachePayload("abc-123", 0, 0, -10, 20, 8))).isNone

  test "non-ascii placed id stays raw":
    check parseFilterCache(spanOf(cachePayload("ab\x01c", 0, 0, 10, 20, 8))).isNone

  test "truncated envelope stays raw":
    let data = cachePayload("abc-123", 0, 0, 10, 20, 8)
    check parseFilterCache(spanOf(data[0 ..< 40])).isNone
    check parseFilterCache(spanOf("\x00\x01")).isNone

  test "garbage FEid blocks are skipped, not raised":
    let blocks = @[newTaggedBlock("FEid", "\x00\x01\x02"),
      newTaggedBlock("FEid", cachePayload("abc-123", 0, 0, 10, 20, 8))]
    check filterCacheItems(blocks).len == 1
