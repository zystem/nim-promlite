import std/[net, strutils]

const
  TextContentType* = "text/plain; version=0.0.4; charset=utf-8"

type
  HttpResponse* = object
    status*: int
    contentType*: string
    contentEncoding*: string
    body*: string

  RequestHandler* = proc(httpMethod, path, acceptEncoding: string): HttpResponse

proc reason(status: int): string =
  case status
  of 200: "OK"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 503: "Service Unavailable"
  else: "OK"

proc renderResponse*(httpMethod: string; response: HttpResponse): string =
  result = "HTTP/1.1 " & $response.status & " " & reason(response.status) & "\r\n" &
    "Content-Type: " & response.contentType & "\r\n" &
    "Content-Length: " & $response.body.len & "\r\n" &
    "Connection: close\r\n"
  if response.contentEncoding.len > 0:
    result.add("Content-Encoding: " & response.contentEncoding & "\r\n")
  result.add("\r\n")
  if httpMethod != "HEAD" and response.body.len > 0:
    result.add(response.body)

proc sendResponse(client: Socket; httpMethod: string; response: HttpResponse) =
  client.send(renderResponse(httpMethod, response))

proc parseRequest(raw: string): tuple[httpMethod, path, acceptEncoding: string] =
  let headerEnd = raw.find("\r\n\r\n")
  let headerBlock = if headerEnd >= 0: raw[0 ..< headerEnd] else: raw
  let lines = headerBlock.split("\r\n")
  if lines.len == 0:
    return
  let first = lines[0].splitWhitespace()
  if first.len >= 2:
    result.httpMethod = first[0]
    result.path = first[1]
  for i in 1 ..< lines.len:
    let colon = lines[i].find(':')
    if colon > 0 and lines[i][0 ..< colon].toLowerAscii() == "accept-encoding":
      result.acceptEncoding = lines[i][colon + 1 .. ^1].strip()

proc serveOnce*(server: Socket; handler: RequestHandler) =
  var client: Socket
  server.accept(client)
  defer: client.close()
  var raw = ""
  try:
    while raw.find("\r\n\r\n") < 0 and raw.len < 8192:
      let chunk = client.recv(1024, timeout = 1000)
      if chunk.len == 0:
        break
      raw.add(chunk)
  except TimeoutError:
    return
  let req = parseRequest(raw)
  if req.httpMethod.len == 0:
    client.sendResponse("GET", HttpResponse(status: 400, contentType: "text/plain", body: "bad request\n"))
    return
  client.sendResponse(req.httpMethod, handler(req.httpMethod, req.path, req.acceptEncoding))

proc runServer*(address: string; port: int; handler: RequestHandler) =
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(port), address)
  server.listen()
  while true:
    serveOnce(server, handler)
