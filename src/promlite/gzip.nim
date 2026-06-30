import std/strformat

{.passL: "-lz".}

type
  ZStream {.importc: "z_stream", header: "<zlib.h>", bycopy.} = object
    next_in*: ptr uint8
    avail_in*: cuint
    total_in*: culong
    next_out*: ptr uint8
    avail_out*: cuint
    total_out*: culong
    msg*: cstring
    state*: pointer
    zalloc*: pointer
    zfree*: pointer
    opaque*: pointer
    data_type*: cint
    adler*: culong
    reserved*: culong

const
  ZFinish = 4.cint
  ZOk = 0.cint
  ZStreamEnd = 1.cint
  ZDefaultCompression = -1.cint
  ZDeflated = 8.cint
  ZDefaultStrategy = 0.cint
  GzipWindowBits = 15.cint + 16.cint
  ChunkSize = 16 * 1024

proc zlibVersion(): cstring {.importc: "zlibVersion", header: "<zlib.h>".}
proc deflateInit2Impl(stream: ptr ZStream; level, zmethod, windowBits, memLevel,
    strategy: cint; version: cstring; streamSize: cint): cint {.
    importc: "deflateInit2_", header: "<zlib.h>".}
proc deflate(stream: ptr ZStream; flush: cint): cint {.
    importc: "deflate", header: "<zlib.h>".}
proc deflateEnd(stream: ptr ZStream): cint {.importc: "deflateEnd", header: "<zlib.h>".}

proc gzipCompress*(input: string): string =
  var stream: ZStream
  let initResult = deflateInit2Impl(addr stream, ZDefaultCompression, ZDeflated,
    GzipWindowBits, 8.cint, ZDefaultStrategy, zlibVersion(), sizeof(ZStream).cint)
  if initResult != ZOk:
    raise newException(IOError, &"zlib deflateInit2 failed: {initResult}")

  var output = newStringOfCap(max(64, input.len div 2))
  var chunk = newString(ChunkSize)
  if input.len > 0:
    stream.next_in = cast[ptr uint8](unsafeAddr input[0])
  stream.avail_in = input.len.cuint

  while true:
    stream.next_out = cast[ptr uint8](addr chunk[0])
    stream.avail_out = chunk.len.cuint
    let deflateResult = deflate(addr stream, ZFinish)
    if deflateResult != ZOk and deflateResult != ZStreamEnd:
      discard deflateEnd(addr stream)
      raise newException(IOError, &"zlib deflate failed: {deflateResult}")

    let produced = chunk.len - stream.avail_out.int
    if produced > 0:
      output.add(chunk[0 ..< produced])
    if deflateResult == ZStreamEnd:
      break

  let endResult = deflateEnd(addr stream)
  if endResult != ZOk:
    raise newException(IOError, &"zlib deflateEnd failed: {endResult}")
  output
