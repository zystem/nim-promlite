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
  ZNoFlush = 0.cint
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

type
  GzipCompressor* = ref object
    stream: ZStream
    output: string
    chunk: string
    finished: bool

proc initGzipCompressor*(): GzipCompressor =
  new(result)
  let initResult = deflateInit2Impl(addr result.stream, ZDefaultCompression, ZDeflated,
    GzipWindowBits, 8.cint, ZDefaultStrategy, zlibVersion(), sizeof(ZStream).cint)
  if initResult != ZOk:
    raise newException(IOError, &"zlib deflateInit2 failed: {initResult}")
  result.output = newStringOfCap(1024)
  result.chunk = newString(ChunkSize)

proc drain(compressor: var GzipCompressor; flush: cint): cint =
  while true:
    compressor.stream.next_out = cast[ptr uint8](addr compressor.chunk[0])
    compressor.stream.avail_out = compressor.chunk.len.cuint
    result = deflate(addr compressor.stream, flush)
    if result != ZOk and result != ZStreamEnd:
      discard deflateEnd(addr compressor.stream)
      compressor.finished = true
      raise newException(IOError, &"zlib deflate failed: {result}")

    let produced = compressor.chunk.len - compressor.stream.avail_out.int
    if produced > 0:
      compressor.output.add(compressor.chunk[0 ..< produced])
    if compressor.stream.avail_out > 0 or result == ZStreamEnd:
      break

proc write*(compressor: var GzipCompressor; input: string) =
  if compressor.finished:
    raise newException(IOError, "cannot write to a finished gzip stream")
  if input.len == 0:
    return
  compressor.stream.next_in = cast[ptr uint8](unsafeAddr input[0])
  compressor.stream.avail_in = input.len.cuint
  while compressor.stream.avail_in > 0:
    discard compressor.drain(ZNoFlush)

proc finish*(compressor: var GzipCompressor): string =
  if compressor.finished:
    return compressor.output
  while true:
    let deflateResult = compressor.drain(ZFinish)
    if deflateResult == ZStreamEnd:
      break

  let endResult = deflateEnd(addr compressor.stream)
  compressor.finished = true
  if endResult != ZOk:
    raise newException(IOError, &"zlib deflateEnd failed: {endResult}")
  compressor.output

proc gzipCompress*(input: string): string =
  var compressor = initGzipCompressor()
  compressor.write(input)
  compressor.finish()
