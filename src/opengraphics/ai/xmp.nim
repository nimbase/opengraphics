## XMP metadata extraction (stdlib only).
##
## Finds the <?xpacket ...?> payload and reads Dublin Core title/creator,
## the XMP create date, and the illustrator:Type flag with std/xmlparser.
## Best-effort throughout: a missing or malformed packet yields
## found=false or empty fields, never an exception.

import std/xmlparser
import std/xmltree
import std/strutils
import ./types

proc findTag(n: XmlNode, suffix: string): XmlNode =
  ## First element whose tag equals the suffix or ends with :suffix,
  ## depth-first. Matches "dc:title" via "title" and "illustrator:Type"
  ## via the full "illustrator:Type".
  if n.kind == xnElement:
    if n.tag == suffix or n.tag.endsWith(":" & suffix):
      return n
    for child in n:
      let hit = findTag(child, suffix)
      if hit != nil:
        return hit
  nil

proc liText(n: XmlNode): string =
  let li = findTag(n, "li")
  if li == nil:
    return ""
  innerText(li)

proc parseXmp*(data: string): XmpMeta =
  result = XmpMeta(found: false)
  let b = find(data, "<?xpacket begin")
  if b < 0:
    return
  let piEnd = find(data, "?>", b)
  if piEnd < 0:
    return
  let e = find(data, "<?xpacket end", piEnd)
  if e < 0:
    return
  var root: XmlNode
  try:
    root = parseXml(data[piEnd + 2 ..< e])
  except XmlError:
    result.found = true
    return
  result.found = true
  let title = findTag(root, "title")
  if title != nil:
    result.title = liText(title)
  let creator = findTag(root, "creator")
  if creator != nil:
    result.creator = liText(creator)
  let date = findTag(root, "CreateDate")
  if date != nil:
    result.createDate = innerText(date)
  let aiType = findTag(root, "illustrator:Type")
  if aiType != nil and innerText(aiType) == "Document":
    result.isIllustratorDoc = true
