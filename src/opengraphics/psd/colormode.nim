## Color Mode Data section.
## Only Indexed (768-byte palette) and Duotone carry data;
## everything else is a zero length. Raw bytes are preserved
## for future write support.

import ./reader

type
  ColorModeData* = object
    raw*: seq[byte]

proc parseColorModeData*(r: var BinReader): ColorModeData =
  let n = int(r.readU32BE())
  result = ColorModeData(raw: r.readBytes(n))
