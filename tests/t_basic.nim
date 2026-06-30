import std/[os, osproc, strutils, unittest]

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

suite "gzip":
  test "produces a valid gzip stream":
    let gz = gzipCompress("example_metric 1\n")
    check gz.len > 10
    check gunzipWithPython(gz) == "example_metric 1\n"

suite "Exporter cache":
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
