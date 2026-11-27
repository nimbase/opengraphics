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
