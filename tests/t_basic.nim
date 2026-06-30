import std/[math, net, os, osproc, strutils, unittest]

import promlite

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

proc httpRequest(port: Port; path: string; httpMethod = "GET"): string =
  rawHttpRequest(port, httpMethod & " " & path & " HTTP/1.1\r\n" &
    "Host: 127.0.0.1\r\n" &
    "Connection: close\r\n\r\n")

proc waitForHttp(port: Port; path: string; httpMethod = "GET"): string =
  for _ in 0 ..< 50:
    try:
      result = httpRequest(port, path, httpMethod)
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

proc collectEscapedMetric(m: var MetricsBuilder) {.gcsafe.} =
  m.help("escaped_metric", "slashes \\ and newline\nok")
  m.gauge("escaped_metric", 1,
    labels = {"quote": "a\"b", "slash": "a\\b", "line": "a\nb"})

proc collectSlowMetric(m: var MetricsBuilder) {.gcsafe.} =
  sleep(1500)
  m.help("slow_start_metric", "Metric emitted after slow initial refresh")
  m.gauge("slow_start_metric", 1)

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

proc runTcpTestServer(mode: string; port: Port; dataDir: string) =
  let exporter = newExporter(
    address = "127.0.0.1",
    port = int(port),
    dataDir = dataDir,
    refreshIntervalSeconds = if mode == "slow-start": 60 else: 0,
    collector =
      case mode
      of "escape": collectEscapedMetric
      of "slow-start": collectSlowMetric
      of "values": collectValueMetrics
      else: collectTcpMetric
  )
  exporter.run()

proc startTcpTestServer(mode: string; port: Port; dataDir: string): Process =
  startProcess(getAppFilename(), args = ["--tcp-test-server", mode, $int(port), dataDir])

proc stopTcpTestServer(process: Process) =
  process.terminate()
  discard process.waitForExit(2000)
  process.close()

if paramCount() == 4 and paramStr(1) == "--tcp-test-server":
  runTcpTestServer(paramStr(2), Port(parseInt(paramStr(3))), paramStr(4))
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

suite "Exporter disk cache":
  test "creates empty files for darkhttpd on startup":
    let dataDir = getTempDir() / "promlite-startup-files"
    removeDir(dataDir)
    let exporter = newExporter(dataDir = dataDir, collector = proc(m: var MetricsBuilder) = discard)
    exporter.ensureMetricsFile()
    check fileExists(dataDir / "metrics")
    check readFile(dataDir / "metrics") == ""
    check readFile(dataDir / "healthz") == "ok\n"
    removeDir(dataDir)

  test "refresh writes the next metrics file and records its path":
    let dataDir = getTempDir() / "promlite-refresh-file"
    removeDir(dataDir)
    let exporter = newExporter(dataDir = dataDir, forceGcAfterRefresh = false,
      collector = proc(m: var MetricsBuilder) =
        m.help("disk_metric", "Disk-backed refresh test metric")
        m.gauge("disk_metric", 1)
    )
    check exporter.refresh()
    check exporter.isReady()
    check exporter.cachedResponse().path == dataDir / "metrics"
    let metrics = readFile(dataDir / "metrics")
    check metrics.contains("disk_metric 1\n")
    check checkWithPromtool(metrics)
    removeDir(dataDir)

  test "refresh preserves the previous file on failure":
    let dataDir = getTempDir() / "promlite-refresh-failure"
    removeDir(dataDir)
    var fail = false
    var value = 1
    let exporter = newExporter(dataDir = dataDir, forceGcAfterRefresh = false,
      collector = proc(m: var MetricsBuilder) =
        m.gauge("partial_stream_metric", value)
        if fail:
          raise newException(ValueError, "boom after partial write")
    )
    check exporter.refresh()
    let first = readFile(dataDir / "metrics")
    value = 2
    fail = true
    check not exporter.refresh()
    let afterFailure = readFile(dataDir / "metrics")
    check afterFailure == first
    check afterFailure.contains("partial_stream_metric 1\n")
    check not afterFailure.contains("partial_stream_metric 2\n")
    removeDir(dataDir)

suite "HTTP serving":
  test "serves /healthz and /metrics over darkhttpd":
    let dataDir = getTempDir() / "promlite-http-plain"
    removeDir(dataDir)
    let port = freeTcpPort()
    let process = startTcpTestServer("plain", port, dataDir)
    try:
      let healthResponse = waitForHttp(port, "/healthz")
      check healthResponse.contains("HTTP/1.1 200 OK\r\n")
      check healthResponse.endsWith("ok\n")

      let metricsResponse = waitForHttp(port, "/metrics")
      check metricsResponse.contains("HTTP/1.1 200 OK\r\n")
      check metricsResponse.contains("Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n")
      let metrics = responseBody(metricsResponse)
      check metrics.contains("tcp_metric 3\n")
      check checkWithPromtool(metrics)

      let headResponse = httpRequest(port, "/metrics", httpMethod = "HEAD")
      check headResponse.contains("HTTP/1.1 200 OK\r\n")
      check responseBody(headResponse).len == 0
    finally:
      stopTcpTestServer(process)
      removeDir(dataDir)

  test "serves escaped HELP and labels over darkhttpd":
    let dataDir = getTempDir() / "promlite-http-escape"
    removeDir(dataDir)
    let port = freeTcpPort()
    let process = startTcpTestServer("escape", port, dataDir)
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
      removeDir(dataDir)

  test "starts darkhttpd with an empty metrics file before slow refresh completes":
    let dataDir = getTempDir() / "promlite-http-slow"
    removeDir(dataDir)
    let port = freeTcpPort()
    let process = startTcpTestServer("slow-start", port, dataDir)
    try:
      let healthResponse = waitForHttp(port, "/healthz")
      check healthResponse.contains("HTTP/1.1 200 OK\r\n")
      check healthResponse.endsWith("ok\n")

      let warmingMetricsResponse = httpRequest(port, "/metrics")
      check warmingMetricsResponse.contains("HTTP/1.1 200 OK\r\n")
      check responseBody(warmingMetricsResponse).len == 0

      sleep(1800)
      let readyMetricsResponse = waitForHttp(port, "/metrics")
      check readyMetricsResponse.contains("HTTP/1.1 200 OK\r\n")
      check responseBody(readyMetricsResponse).contains("slow_start_metric 1\n")
    finally:
      stopTcpTestServer(process)
      removeDir(dataDir)

  test "serves exact metric values for gauges, counters, info, and labels":
    let dataDir = getTempDir() / "promlite-http-values"
    removeDir(dataDir)
    let port = freeTcpPort()
    let process = startTcpTestServer("values", port, dataDir)
    try:
      let metricsResponse = waitForHttp(port, "/metrics")
      check metricsResponse.contains("HTTP/1.1 200 OK\r\n")
      checkValueMetrics(responseBody(metricsResponse))
    finally:
      stopTcpTestServer(process)
      removeDir(dataDir)

  test "adds exporter self-metrics for refresh state":
    let dataDir = getTempDir() / "promlite-self-metrics"
    removeDir(dataDir)
    var fail = false
    let exporter = newExporter(dataDir = dataDir, forceGcAfterRefresh = false,
      collector = proc(m: var MetricsBuilder) =
        if fail:
          raise newException(ValueError, "boom")
        m.help("app_metric", "An application metric")
        m.gauge("app_metric", 1)
    )
    check exporter.refresh()
    fail = true
    check not exporter.refresh()
    fail = false
    check exporter.refresh()

    let metrics = readFile(dataDir / "metrics")
    check metrics.contains("promlite_cache_ready 1\n")
    check metrics.contains("promlite_refresh_failures_total 1\n")
    check checkWithPromtool(metrics)
    removeDir(dataDir)
