import std/[math, net, os, osproc, strutils, unittest]

import promlite
import promlite/gzip
import promlite/httpserver

proc gunzipWithPython(data: string): string =
  let path = getTempDir() / "promlite_test.gz"
  writeFile(path, data)
  let command = "python3 -c 'import gzip,sys; sys.stdout.buffer.write(gzip.open(sys.argv[1], \"rb\").read())' " & path
  result = execProcess(command)
  removeFile(path)

proc checkWithPromtool(metrics: string): bool =
  if findExe("promtool").len == 0:
    return true
  let path = getTempDir() / "promlite_metrics.prom"
  writeFile(path, metrics)
  let (output, exitCode) = execCmdEx("promtool check metrics < " & path)
  removeFile(path)
  if exitCode != 0:
    echo output
  exitCode == 0

proc responseBody(response: string): string =
  let headerEnd = response.find("\r\n\r\n")
  doAssert headerEnd >= 0
  response[headerEnd + 4 .. ^1]

proc rawHttpRequest(port: Port; request: string): string =
  var client = newSocket()
  defer: client.close()
  client.connect("127.0.0.1", port)
  client.send(request)
  while true:
    let chunk = client.recv(4096)
    if chunk.len == 0:
      break
    result.add(chunk)

proc httpRequest(port: Port; path: string; acceptEncoding = "";
    httpMethod = "GET"): string =
  var request = httpMethod & " " & path & " HTTP/1.1\r\n" &
    "Host: 127.0.0.1\r\n" &
    "Connection: close\r\n"
  if acceptEncoding.len > 0:
    request.add("Accept-Encoding: " & acceptEncoding & "\r\n")
  request.add("\r\n")
  rawHttpRequest(port, request)

proc waitForHttp(port: Port; path: string; acceptEncoding = "";
    httpMethod = "GET"): string =
  for _ in 0 ..< 50:
    try:
      result = httpRequest(port, path, acceptEncoding, httpMethod)
      if result.len > 0:
        return
    except OSError, TimeoutError:
      sleep(50)
  raise newException(IOError, "test HTTP server did not respond")

proc freeTcpPort(): Port =
  var server = newSocket()
  defer: server.close()
  server.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = server.getLocalAddr()
  port

proc collectTcpMetric(m: var MetricsBuilder) {.gcsafe.} =
  m.help("tcp_metric", "A real TCP test metric")
  m.gauge("tcp_metric", 3)

proc collectTcpGzipMetric(m: var MetricsBuilder) {.gcsafe.} =
  m.help("tcp_gzip_metric", "A real TCP gzip test metric")
  m.gauge("tcp_gzip_metric", 5)

proc collectEscapedMetric(m: var MetricsBuilder) {.gcsafe.} =
  m.help("escaped_metric", "slashes \\ and newline\nok")
  m.gauge("escaped_metric", 1,
    labels = {"quote": "a\"b", "slash": "a\\b", "line": "a\nb"})

proc collectLargeMetrics(m: var MetricsBuilder) {.gcsafe.} =
  m.help("large_series", "Large gzip smoke test series")
  for i in 0 ..< 10000:
    m.gauge("large_series", i, labels = {"idx": $i})

proc collectValueMetrics(m: var MetricsBuilder) {.gcsafe.} =
  m.help("value_temperature_celsius", "Integer gauge")
  m.gauge("value_temperature_celsius", 42)
  m.help("value_ratio", "Float gauge")
  m.gauge("value_ratio", 3.5)
  m.help("value_offset", "Negative gauge")
  m.gauge("value_offset", -2)
  m.help("value_requests_total", "Integer counter")
  m.counter("value_requests_total", 7)
  m.help("value_seconds_total", "Float counter")
  m.counter("value_seconds_total", 12.25)
  m.help("value_info", "Info metric")
  m.info("value_info", labels = {"version": "1.2.3", "runtime": "nim"})
  m.help("value_cache_entries", "Labeled gauge")
  m.gauge("value_cache_entries", 9, labels = {"state": "warm", "zone": "a"})

proc checkValueMetrics(metrics: string) =
  check metrics.contains("# TYPE value_temperature_celsius gauge\n")
  check metrics.contains("value_temperature_celsius 42\n")
  check metrics.contains("# TYPE value_ratio gauge\n")
  check metrics.contains("value_ratio 3.5\n")
  check metrics.contains("# TYPE value_offset gauge\n")
  check metrics.contains("value_offset -2\n")
  check metrics.contains("# TYPE value_requests_total counter\n")
  check metrics.contains("value_requests_total 7\n")
  check metrics.contains("# TYPE value_seconds_total counter\n")
  check metrics.contains("value_seconds_total 12.25\n")
  check metrics.contains("# TYPE value_info gauge\n")
  check metrics.contains("value_info{version=\"1.2.3\",runtime=\"nim\"} 1\n")
  check metrics.contains("# TYPE value_cache_entries gauge\n")
  check metrics.contains("value_cache_entries{state=\"warm\",zone=\"a\"} 9\n")
  check checkWithPromtool(metrics)

proc runTcpTestServer(mode: string; port: Port) =
  let exporter = newExporter(
    address = "127.0.0.1",
    port = int(port),
    gzipEnabled = mode in ["gzip", "large-gzip", "values-gzip"],
    collector =
      case mode
      of "gzip": collectTcpGzipMetric
      of "escape": collectEscapedMetric
      of "large-gzip": collectLargeMetrics
      of "values", "values-gzip": collectValueMetrics
      else: collectTcpMetric
  )
  exporter.run()

proc startTcpTestServer(mode: string; port: Port): Process =
  startProcess(getAppFilename(), args = ["--tcp-test-server", mode, $int(port)])

proc stopTcpTestServer(process: Process) =
  process.terminate()
  discard process.waitForExit(2000)
  process.close()

if paramCount() == 3 and paramStr(1) == "--tcp-test-server":
  runTcpTestServer(paramStr(2), Port(parseInt(paramStr(3))))
  quit(0)

suite "MetricsBuilder":
  test "formats metrics with HELP, TYPE, and labels":
    var m = initMetricsBuilder()
    m.help("my_app_items_total", "Number of processed items")
    m.counter("my_app_items_total", 123)
    m.help("my_app_cache_ready", "Whether cache is ready")
    m.gauge("my_app_cache_ready", 1, labels = {"state": "warm"})
    check $m == "# HELP my_app_items_total Number of processed items\n" &
      "# TYPE my_app_items_total counter\n" &
      "my_app_items_total 123\n" &
      "# HELP my_app_cache_ready Whether cache is ready\n" &
      "# TYPE my_app_cache_ready gauge\n" &
      "my_app_cache_ready{state=\"warm\"} 1\n"

  test "escapes HELP and label values":
    check escapeHelp("a\\b\nc") == "a\\\\b\\nc"
    check escapeLabelValue("a\"b\\c\nd") == "a\\\"b\\\\c\\nd"

  test "validates metric and label names in strict mode":
    var m = initMetricsBuilder()
    expect ValueError:
      m.gauge("9bad", 1)
    expect ValueError:
      m.gauge("good_metric", 1, labels = {"bad-label": "x"})

  test "rejects invalid counter values and conflicting metric types":
    var m = initMetricsBuilder()
    expect ValueError:
      m.counter("negative_events_total", -1)
    expect ValueError:
      m.counter("negative_float_events_total", -0.5)

    m.gauge("same_metric_name", 1)
    expect ValueError:
      m.counter("same_metric_name", 2)

  test "allows invalid names when strict mode is disabled":
    var m = initMetricsBuilder(strictNames = false)
    m.gauge("9bad", -1.5, labels = {"bad-label": "x"})
    check $m == "# TYPE 9bad gauge\n9bad{bad-label=\"x\"} -1.5\n"

  test "emits Prometheus-compatible text format":
    var m = initMetricsBuilder()
    m.help("promlite_test_metric", "A test metric")
    m.gauge("promlite_test_metric", 42, labels = {"state": "ok"})
    m.help("promlite_test_events_total", "A test event counter")
    m.counter("promlite_test_events_total", 3'u64)
    check checkWithPromtool($m)

  test "formats Prometheus special float values":
    var m = initMetricsBuilder()
    m.help("special_positive_value", "Positive infinity")
    m.gauge("special_positive_value", Inf)
    m.help("special_negative_value", "Negative infinity")
    m.gauge("special_negative_value", -Inf)
    m.help("special_nan_value", "Not a number")
    m.gauge("special_nan_value", NaN)
    check ($m).contains("special_positive_value +Inf\n")
    check ($m).contains("special_negative_value -Inf\n")
    check ($m).contains("special_nan_value NaN\n")
    check checkWithPromtool($m)

  test "emits TYPE once for repeated samples":
    var m = initMetricsBuilder()
    m.gauge("repeat_samples", 1, labels = {"idx": "first"})
    m.gauge("repeat_samples", 2, labels = {"idx": "second"})
    let metrics = $m
    check metrics.count("# TYPE repeat_samples gauge\n") == 1
    check metrics.contains("repeat_samples{idx=\"first\"} 1\n")
    check metrics.contains("repeat_samples{idx=\"second\"} 2\n")

suite "gzip":
  test "produces a valid gzip stream":
    let gz = gzipCompress("example_metric 1\n")
    check gz.len > 10
    check gunzipWithPython(gz) == "example_metric 1\n"

  test "compresses incrementally":
    var gz = initGzipCompressor()
    gz.write("# TYPE example_metric gauge\n")
    gz.write("example_metric 1\n")
    check gunzipWithPython(gz.finish()) == "# TYPE example_metric gauge\nexample_metric 1\n"

suite "Exporter cache":
  test "allows disabling forced GC after refresh":
    let exporter = newExporter(forceGcAfterRefresh = false, collector = proc(m: var MetricsBuilder) =
      m.gauge("gc_option_metric", 1)
    )
    check exporter.refresh()
    check exporter.isReady()

  test "refresh swaps cache and preserves previous cache on failure":
    var fail = false
    let exporter = newExporter(gzipEnabled = false, collector = proc(m: var MetricsBuilder) =
      if fail:
        raise newException(ValueError, "boom")
      m.gauge("cache_swap_metric", 1)
    )

    check exporter.refresh()
    let first = exporter.cachedResponse()
    check first.body.contains("cache_swap_metric 1\n")
    fail = true
    check not exporter.refresh()
    check exporter.cachedResponse().body == first.body

  test "gzip refresh preserves previous cache on failure":
    var fail = false
    let exporter = newExporter(gzipEnabled = true, collector = proc(m: var MetricsBuilder) =
      if fail:
        raise newException(ValueError, "boom")
      m.gauge("gzip_cache_metric", 1)
    )

    check exporter.refresh()
    let first = exporter.cachedResponse()
    check first.compressed
    check gunzipWithPython(first.body).contains("gzip_cache_metric 1\n")
    fail = true
    check not exporter.refresh()
    check exporter.cachedResponse().body == first.body

  test "gzip refresh discards partially written stream on failure":
    var fail = false
    var value = 1
    let exporter = newExporter(gzipEnabled = true, collector = proc(m: var MetricsBuilder) =
      m.gauge("partial_stream_metric", value)
      if fail:
        raise newException(ValueError, "boom after partial write")
    )

    check exporter.refresh()
    let first = exporter.cachedResponse()
    check gunzipWithPython(first.body).contains("partial_stream_metric 1\n")
    value = 2
    fail = true
    check not exporter.refresh()
    let afterFailure = exporter.cachedResponse()
    check afterFailure.body == first.body
    let metrics = gunzipWithPython(afterFailure.body)
    check metrics.contains("partial_stream_metric 1\n")
    check not metrics.contains("partial_stream_metric 2\n")

suite "HTTP serving":
  test "/metrics returns headers and /healthz works":
    let exporter = newExporter(gzipEnabled = true, collector = proc(m: var MetricsBuilder) =
      m.gauge("http_metric", 7)
    )
    check exporter.refresh()

    let metricsResponse = renderResponse("GET",
      exporter.handleRequest("GET", "/metrics", "gzip"))

    check metricsResponse.contains("HTTP/1.1 200 OK\r\n")
    check metricsResponse.contains("Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n")
    check metricsResponse.contains("Content-Encoding: gzip\r\n")
    check metricsResponse.contains("Content-Length: ")

    let healthResponse = renderResponse("GET",
      exporter.handleRequest("GET", "/healthz", ""))

    check healthResponse.contains("HTTP/1.1 200 OK\r\n")
    check healthResponse.endsWith("ok\n")

  test "serves /healthz and /metrics over a real TCP socket":
    let port = freeTcpPort()
    let process = startTcpTestServer("plain", port)
    try:
      let healthResponse = waitForHttp(port, "/healthz")
      check healthResponse.contains("HTTP/1.1 200 OK\r\n")
      check healthResponse.endsWith("ok\n")

      let metricsResponse = httpRequest(port, "/metrics")
      check metricsResponse.contains("HTTP/1.1 200 OK\r\n")
      check metricsResponse.contains("Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n")
      check responseBody(metricsResponse).contains("tcp_metric 3\n")
      check checkWithPromtool(responseBody(metricsResponse))

      let headResponse = httpRequest(port, "/metrics", httpMethod = "HEAD")
      check headResponse.contains("HTTP/1.1 200 OK\r\n")
      check headResponse.contains("Content-Length: ")
      check responseBody(headResponse).len == 0

      let badResponse = rawHttpRequest(port, "definitely-not-http\r\n\r\n")
      check badResponse.contains("HTTP/1.1 400 Bad Request\r\n")
      check badResponse.endsWith("bad request\n")
    finally:
      stopTcpTestServer(process)

    let gzipPort = freeTcpPort()
    let gzipProcess = startTcpTestServer("gzip", gzipPort)
    try:
      let gzipResponse = waitForHttp(gzipPort, "/metrics", "gzip")
      check gzipResponse.contains("HTTP/1.1 200 OK\r\n")
      check gzipResponse.contains("Content-Encoding: gzip\r\n")
      check gunzipWithPython(responseBody(gzipResponse)).contains("tcp_gzip_metric 5\n")
    finally:
      stopTcpTestServer(gzipProcess)

  test "serves escaped HELP and labels over HTTP":
    let port = freeTcpPort()
    let process = startTcpTestServer("escape", port)
    try:
      let metricsResponse = waitForHttp(port, "/metrics")
      let metrics = responseBody(metricsResponse)

      check metrics.contains("# HELP escaped_metric slashes \\\\ and newline\\nok\n")
      check metrics.contains("quote=\"a\\\"b\"")
      check metrics.contains("slash=\"a\\\\b\"")
      check metrics.contains("line=\"a\\nb\"")
      check checkWithPromtool(metrics)
    finally:
      stopTcpTestServer(process)

  test "serves a large gzip metrics response over HTTP":
    let port = freeTcpPort()
    let process = startTcpTestServer("large-gzip", port)
    try:
      let metricsResponse = waitForHttp(port, "/metrics", "gzip")
      check metricsResponse.contains("HTTP/1.1 200 OK\r\n")
      check metricsResponse.contains("Content-Encoding: gzip\r\n")
      let metrics = gunzipWithPython(responseBody(metricsResponse))

      check metrics.contains("large_series{idx=\"0\"} 0\n")
      check metrics.contains("large_series{idx=\"9999\"} 9999\n")
      check metrics.count("# TYPE large_series gauge\n") == 1
      check checkWithPromtool(metrics)
    finally:
      stopTcpTestServer(process)

  test "serves exact metric values for gauges, counters, info, and labels over HTTP":
    let port = freeTcpPort()
    let process = startTcpTestServer("values", port)
    try:
      let metricsResponse = waitForHttp(port, "/metrics")
      check metricsResponse.contains("HTTP/1.1 200 OK\r\n")
      let metrics = responseBody(metricsResponse)

      checkValueMetrics(metrics)
    finally:
      stopTcpTestServer(process)

  test "serves exact metric values for gauges, counters, info, and labels over gzip HTTP":
    let port = freeTcpPort()
    let process = startTcpTestServer("values-gzip", port)
    try:
      let metricsResponse = waitForHttp(port, "/metrics", "gzip")
      check metricsResponse.contains("HTTP/1.1 200 OK\r\n")
      check metricsResponse.contains("Content-Encoding: gzip\r\n")
      checkValueMetrics(gunzipWithPython(responseBody(metricsResponse)))
    finally:
      stopTcpTestServer(process)

  test "honors gzip Accept-Encoding q-values":
    let exporter = newExporter(gzipEnabled = true, collector = proc(m: var MetricsBuilder) =
      m.gauge("encoding_metric", 1)
    )
    check exporter.refresh()

    check exporter.handleRequest("GET", "/metrics", "br, gzip").status == 200
    check exporter.handleRequest("GET", "/metrics", "gzip;q=1.0").status == 200
    check exporter.handleRequest("GET", "/metrics", "gzip; q=0.5").status == 200
    check exporter.handleRequest("GET", "/metrics", "gzip;q=0").status == 406
    check exporter.handleRequest("GET", "/metrics", "br, gzip;q=0").status == 406
    check exporter.handleRequest("GET", "/metrics", "identity").status == 406

  test "serves plaintext metrics when gzip is disabled":
    let exporter = newExporter(gzipEnabled = false, collector = proc(m: var MetricsBuilder) =
      m.help("plain_metric", "A plaintext test metric")
      m.gauge("plain_metric", 9)
    )
    check exporter.refresh()

    let response = exporter.handleRequest("GET", "/metrics", "")
    check response.status == 200
    check response.contentEncoding == ""
    check response.body.contains("plain_metric 9\n")
    check checkWithPromtool(response.body)

  test "handles HEAD, missing cache, methods, and paths":
    let emptyExporter = newExporter(gzipEnabled = false, collector = proc(m: var MetricsBuilder) =
      m.gauge("unused_metric", 1)
    )
    check emptyExporter.handleRequest("GET", "/metrics", "").status == 503
    check emptyExporter.handleRequest("POST", "/metrics", "").status == 405
    check emptyExporter.handleRequest("GET", "/missing", "").status == 404
    check emptyExporter.handleRequest("GET", "/metrics?foo=bar", "").status == 404

    let exporter = newExporter(gzipEnabled = false, collector = proc(m: var MetricsBuilder) =
      m.gauge("head_metric", 1)
    )
    check exporter.refresh()
    let headResponse = renderResponse("HEAD",
      exporter.handleRequest("HEAD", "/metrics", ""))
    check headResponse.contains("HTTP/1.1 200 OK\r\n")
    check headResponse.contains("Content-Length: ")
    check not headResponse.contains("head_metric 1\n")

  test "adds exporter self-metrics for scrapes and refresh failures":
    var fail = false
    let exporter = newExporter(gzipEnabled = false, collector = proc(m: var MetricsBuilder) =
      if fail:
        raise newException(ValueError, "boom")
      m.help("app_metric", "An application metric")
      m.gauge("app_metric", 1)
    )

    check exporter.refresh()
    discard exporter.handleRequest("GET", "/metrics", "")
    fail = true
    check not exporter.refresh()
    fail = false
    check exporter.refresh()

    let response = exporter.handleRequest("GET", "/metrics", "")
    check response.body.contains("promlite_cache_ready 1\n")
    check response.body.contains("promlite_refresh_failures_total 1\n")
    check response.body.contains("promlite_scrapes_total 1\n")
    check checkWithPromtool(response.body)
