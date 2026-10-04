## Error type and resource limits for the PSD reader and writer.
##
## `PsdError` mirrors the reference crate's seven variants so callers can
## distinguish "the file is truncated" from "the file uses a feature we do
## not implement" from "the file exceeds a configured limit". Truncation is
## an ordinary, expected outcome for untrusted input, so it is a catchable
## data error rather than an `EOFError` escaping the parser.

type
  PsdErrorKind* {.pure.} = enum
    ## Ran off the end of the input.
    UnexpectedEof
    ## A 4-byte magic did not match what the format requires.
    InvalidSignature
    ## File version outside the supported set.
    UnsupportedVersion
    ## A configured cap (dimensions, pixels, bytes, counts) was exceeded.
    LimitExceeded
    ## Structurally invalid data that is not a truncation.
    Invalid
    ## A compressed stream failed to inflate.
    Decompress
    ## Well-formed, but a feature this implementation does not provide.
    Unsupported

  PsdError* = object of CatchableError
    ## Every raise site sets `kind` so callers can branch without parsing
    ## the message. `msg` stays human-readable for logs and `e.msg`.
    kind*: PsdErrorKind
    offset*: int  ## byte offset of the failure, when known; -1 otherwise

proc newPsdError*(kind: PsdErrorKind, msg: string,
    offset = -1) {.noinline.} =
  ## Raised directly by parsers that classify their own failures.
  var e = newException(PsdError, msg)
  e.kind = kind
  e.offset = offset
  raise e

proc eof*(needed, offset: int) {.noinline.} =
  ## Short read. `needed` is how many bytes were still required.
  newPsdError(PsdErrorKind.UnexpectedEof,
    "unexpected end of data at offset " & $offset & " (needed " & $needed &
    " more bytes)", offset)

proc badSignature*(expected, found: string,
    offset = -1) {.noinline.} =
  newPsdError(PsdErrorKind.InvalidSignature,
    "invalid signature '" & found & "', expected '" & expected & "'", offset)

proc limitExceeded*(msg: string) {.noinline.} =
  newPsdError(PsdErrorKind.LimitExceeded, "limit exceeded: " & msg)

proc invalid*(msg: string) {.noinline.} =
  newPsdError(PsdErrorKind.Invalid, "invalid data: " & msg)

proc decompressFailed*(msg: string) {.noinline.} =
  newPsdError(PsdErrorKind.Decompress, "decompression failed: " & msg)

proc unsupported*(msg: string) {.noinline.} =
  newPsdError(PsdErrorKind.Unsupported, "unsupported: " & msg)

type
  Limits* = object
    ## Caps applied before any buffer is allocated, so corrupt length
    ## prefixes cannot force huge allocations. Every check runs on a value
    ## straight off the wire, ahead of the read or skip it guards.
    ##
    ## Defaults are the spec maxima with a safety net. Tighten them when
    ## reading user-supplied files, e.g.
    ## `Limits(maxWidth: 10000, maxHeight: 10000, maxPixels: 100_000_000,
    ##   maxLayers: 100, maxSectionBytes: 64_000_000, maxBlocks: 1000)`.
    maxWidth*: int
    maxHeight*: int
    maxPixels*: int
      ## width*height cap per image, and also the decoded-volume cap
      ## (see `checkSamples` for the channel-aware form)
    maxLayers*: int
    maxSectionBytes*: int
      ## cap on any length-prefixed section or block: color mode data,
      ## image resources, layer/mask section, layer extra data, tagged
      ## blocks, merged image data
    maxBlocks*: int
      ## cap on resource / tagged-block / descriptor-item counts
    maxDecodedBytes*: int
      ## cap on a single decoded plane buffer; the reference uses 2 GiB

proc defaultLimits*(): Limits =
  ## Spec-maximum dimensions with a pixel and layer-count safety net.
  Limits(maxWidth: 300_000, maxHeight: 300_000, maxPixels: 1_073_741_824,
    maxLayers: 10_000, maxSectionBytes: 2_147_483_648, maxBlocks: 1_000_000,
    maxDecodedBytes: 2_147_483_648)

proc checkDimensions*(limits: Limits, w, h: int, what: string) =
  ## Reject implausible sizes before any buffer is allocated.
  if w <= 0 or h <= 0:
    invalid("invalid " & what & " dimensions " & $w & "x" & $h)
  if w > limits.maxWidth or h > limits.maxHeight:
    limitExceeded(what & " dimensions " & $w & "x" & $h & " exceed limit " &
      $limits.maxWidth & "x" & $limits.maxHeight)
  if w.int64 * h.int64 > limits.maxPixels.int64:
    limitExceeded(what & " size " & $w & "x" & $h &
      " exceeds pixel limit " & $limits.maxPixels)

proc checkSection*(limits: Limits, n: int64, what: string) =
  ## Reject an oversized length-prefixed section before its payload is read
  ## or skipped. `n` comes straight off the wire, so this runs before any
  ## allocation.
  if n < 0:
    invalid("invalid " & what & " length " & $n)
  if n > limits.maxSectionBytes.int64:
    limitExceeded(what & " length " & $n & " exceeds section limit " &
      $limits.maxSectionBytes)

proc checkSamples*(limits: Limits, w, h, channels: int, what: string) =
  ## Channel-aware volume cap. Decoded bytes are `w * h` per channel, so a file
  ## claiming 56 channels must not slip past the pixel cap on dimensions alone.
  if w <= 0 or h <= 0 or channels <= 0:
    return
  if w.int64 * h.int64 * channels.int64 > limits.maxPixels.int64:
    limitExceeded(what & " volume " & $w & "x" & $h & "x" & $channels &
      "ch exceeds pixel limit " & $limits.maxPixels)

proc checkDecoded*(limits: Limits, bytes: int64, what: string) =
  ## Cap on one decoded plane buffer. `PlaneLayout.totalBytes` computes this
  ## before anything is allocated.
  if bytes < 0:
    invalid("invalid " & what & " decoded size " & $bytes)
  if bytes > limits.maxDecodedBytes.int64:
    limitExceeded(what & " decoded size " & $bytes & " exceeds " &
      $limits.maxDecodedBytes)

proc checkCount*(limits: Limits, count, remaining: int64, minItemSize: int64,
    what: string) =
  ## Reject a declared element count that cannot fit in what is left of the
  ## input. Guards every `newSeq` sized from file data, so a huge count
  ## costs nothing to reject.
  if count < 0:
    invalid("invalid " & what & " count " & $count)
  if count * minItemSize > remaining:
    limitExceeded(what & " count " & $count & " does not fit in " &
      $remaining & " remaining bytes")
