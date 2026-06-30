import std/[locks, os, sets, strutils, times]

import promlite/gzip
import promlite/httpserver

export TextContentType

type
  Label* = tuple[name, value: string]
  Collector* = proc(m: var MetricsBuilder) {.gcsafe.}
  MetricKind* = enum mkGauge = "gauge", mkCounter = "counter"

  MetricsBuilder* = object
    text: string
    emittedTypes: HashSet[string]
    strictNames: bool

  CachedResponse* = object
    body*: string
    compressed*: bool
    generatedAtUnix*: int64

  Exporter* = ref object
    address: string
    port: int
    refreshIntervalSeconds: int
    gzipEnabled: bool
    strictNames: bool
    collector: Collector
    lock: Lock
    cache: CachedResponse
    ready: bool
    lastRefreshUnix: int64
    lastRefreshOk: bool
    refreshFailures: uint64
    scrapesTotal: uint64

when compileOption("threads"):
  import std/typedthreads

const
  DefaultPort* = 9090
  MetricsContentType* = TextContentType

proc isValidMetricName*(name: string): bool =
  if name.len == 0:
    return false
  if not (name[0].isAlphaAscii or name[0] in {'_', ':'}):
    return false
  for ch in name:
    if not (ch.isAlphaNumeric or ch in {'_', ':'}):
      return false
  true

proc isValidLabelName*(name: string): bool =
  if name.len == 0:
    return false
  if not (name[0].isAlphaAscii or name[0] == '_'):
    return false
  for ch in name:
    if not (ch.isAlphaNumeric or ch == '_'):
      return false
  true

proc escapeHelp*(value: string): string =
  result = newStringOfCap(value.len)
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    else: result.add(ch)

proc escapeLabelValue*(value: string): string =
  result = newStringOfCap(value.len)
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    else: result.add(ch)

proc initMetricsBuilder*(strictNames = true; initialCapacity = 4096): MetricsBuilder =
  result.strictNames = strictNames
  result.text = newStringOfCap(initialCapacity)
  result.emittedTypes = initHashSet[string]()

proc requireMetricName(builder: MetricsBuilder; name: string) =
  if builder.strictNames and not isValidMetricName(name):
    raise newException(ValueError, "invalid Prometheus metric name: " & name)

proc requireLabelName(builder: MetricsBuilder; name: string) =
  if builder.strictNames and not isValidLabelName(name):
    raise newException(ValueError, "invalid Prometheus label name: " & name)

proc help*(builder: var MetricsBuilder; name, doc: string) =
  builder.requireMetricName(name)
  builder.text.add("# HELP ")
  builder.text.add(name)
  builder.text.add(' ')
  builder.text.add(escapeHelp(doc))
  builder.text.add('\n')

proc metricType*(builder: var MetricsBuilder; name: string; kind: MetricKind) =
  builder.requireMetricName(name)
  if name in builder.emittedTypes:
    return
  builder.emittedTypes.incl(name)
  builder.text.add("# TYPE ")
  builder.text.add(name)
  builder.text.add(' ')
  builder.text.add($kind)
  builder.text.add('\n')

proc appendLabels(builder: var MetricsBuilder; labels: openArray[Label]) =
  if labels.len == 0:
    return
  builder.text.add('{')
  for i, label in labels:
    builder.requireLabelName(label.name)
    if i > 0:
      builder.text.add(',')
    builder.text.add(label.name)
    builder.text.add("=\"")
    builder.text.add(escapeLabelValue(label.value))
    builder.text.add('"')
  builder.text.add('}')

proc appendMetric(builder: var MetricsBuilder; name, value: string;
    labels: openArray[Label]; kind: MetricKind) =
  builder.metricType(name, kind)
  builder.text.add(name)
  builder.appendLabels(labels)
  builder.text.add(' ')
  builder.text.add(value)
  builder.text.add('\n')

proc gauge*(builder: var MetricsBuilder; name: string; value: SomeNumber;
    labels: openArray[Label] = []) =
  builder.appendMetric(name, $value, labels, mkGauge)

proc counter*(builder: var MetricsBuilder; name: string; value: SomeNumber;
    labels: openArray[Label] = []) =
  builder.appendMetric(name, $value, labels, mkCounter)

proc info*(builder: var MetricsBuilder; name: string; labels: openArray[Label] = []) =
  builder.gauge(name, 1, labels)

proc `$`*(builder: MetricsBuilder): string = builder.text

proc buildPlaintext*(collector: Collector; strictNames = true): string =
  var builder = initMetricsBuilder(strictNames)
  collector(builder)
  $builder

proc compressedSnapshot*(collector: Collector; strictNames = true): CachedResponse =
  let plain = buildPlaintext(collector, strictNames)
  CachedResponse(body: gzipCompress(plain), compressed: true, generatedAtUnix: epochTime().int64)

proc newExporter*(address = "0.0.0.0"; port = DefaultPort; refreshIntervalSeconds = 0;
    collector: Collector = nil; gzipEnabled = true; strictNames = true): Exporter =
  new(result)
  result.address = address
  result.port = port
  result.refreshIntervalSeconds = refreshIntervalSeconds
  result.collector = collector
  result.gzipEnabled = gzipEnabled
  result.strictNames = strictNames
  result.lastRefreshOk = false
  initLock(result.lock)

proc setCollector*(exporter: Exporter; collector: Collector) =
  withLock exporter.lock:
    exporter.collector = collector

proc selfMetrics(exporter: Exporter; builder: var MetricsBuilder; cacheReady: bool;
    lastRefreshUnix: int64; refreshFailures, scrapesTotal: uint64) =
  builder.help("promlite_cache_ready", "Whether the exporter has a cached metrics response")
  builder.gauge("promlite_cache_ready", if cacheReady: 1 else: 0)
  builder.help("promlite_last_refresh_timestamp_seconds", "Unix timestamp of the last successful metrics refresh")
  builder.gauge("promlite_last_refresh_timestamp_seconds", lastRefreshUnix)
  builder.help("promlite_refresh_failures_total", "Total failed metrics refresh attempts")
  builder.counter("promlite_refresh_failures_total", refreshFailures)
  builder.help("promlite_scrapes_total", "Total /metrics scrape requests handled")
  builder.counter("promlite_scrapes_total", scrapesTotal)

proc refresh*(exporter: Exporter): bool {.discardable.} =
  var collector: Collector
  withLock exporter.lock:
    collector = exporter.collector
  if collector.isNil:
    raise newException(ValueError, "collector is not configured")

  try:
    var builder = initMetricsBuilder(exporter.strictNames)
    collector(builder)
    let generatedAtUnix = epochTime().int64
    var refreshFailures: uint64
    var scrapesTotal: uint64
    withLock exporter.lock:
      refreshFailures = exporter.refreshFailures
      scrapesTotal = exporter.scrapesTotal
    exporter.selfMetrics(builder, cacheReady = true, lastRefreshUnix = generatedAtUnix,
      refreshFailures = refreshFailures, scrapesTotal = scrapesTotal)
    let plain = $builder
    let body = if exporter.gzipEnabled: gzipCompress(plain) else: plain
    let snapshot = CachedResponse(body: body, compressed: exporter.gzipEnabled,
      generatedAtUnix: generatedAtUnix)
    withLock exporter.lock:
      exporter.cache = snapshot
      exporter.ready = true
      exporter.lastRefreshUnix = snapshot.generatedAtUnix
      exporter.lastRefreshOk = true
    true
  except CatchableError:
    withLock exporter.lock:
      inc exporter.refreshFailures
      exporter.lastRefreshOk = false
    false

proc cachedResponse*(exporter: Exporter): CachedResponse =
  withLock exporter.lock:
    result = exporter.cache

proc isReady*(exporter: Exporter): bool =
  withLock exporter.lock:
    result = exporter.ready

proc acceptsGzip(acceptEncoding: string): bool =
  for part in acceptEncoding.split(','):
    let tokens = part.strip().split(';')
    if tokens.len == 0 or tokens[0].strip().toLowerAscii() != "gzip":
      continue
    var quality = 1.0
    for token in tokens[1 .. ^1]:
      let param = token.strip()
      let eq = param.find('=')
      if eq > 0 and param[0 ..< eq].strip().toLowerAscii() == "q":
        try:
          quality = parseFloat(param[eq + 1 .. ^1].strip())
        except ValueError:
          quality = 0.0
    if quality > 0.0:
      return true

proc handleRequest*(exporter: Exporter; httpMethod, path, acceptEncoding: string): HttpResponse =
  if httpMethod != "GET" and httpMethod != "HEAD":
    return HttpResponse(status: 405, contentType: "text/plain", body: "method not allowed\n")
  if path == "/healthz":
    return HttpResponse(status: 200, contentType: "text/plain", body: "ok\n")
  if path != "/metrics":
    return HttpResponse(status: 404, contentType: "text/plain", body: "not found\n")

  withLock exporter.lock:
    inc exporter.scrapesTotal
    if not exporter.ready:
      return HttpResponse(status: 503, contentType: "text/plain", body: "metrics cache not ready\n")
    if exporter.cache.compressed and acceptsGzip(acceptEncoding):
      return HttpResponse(status: 200, contentType: MetricsContentType,
        contentEncoding: "gzip", body: exporter.cache.body)
    elif exporter.cache.compressed:
      return HttpResponse(status: 406, contentType: "text/plain",
        body: "gzip is required for this cached response\n")
    else:
      return HttpResponse(status: 200, contentType: MetricsContentType,
        body: exporter.cache.body)

when compileOption("threads"):
  proc refreshLoop(exporter: Exporter) {.thread.} =
    while true:
      sleep(exporter.refreshIntervalSeconds * 1000)
      discard exporter.refresh()

proc start*(exporter: Exporter) =
  if exporter.collector.isNil:
    raise newException(ValueError, "collector is not configured")
  discard exporter.refresh()
  if exporter.refreshIntervalSeconds > 0:
    when compileOption("threads"):
      var thread: Thread[Exporter]
      createThread(thread, refreshLoop, exporter)
    else:
      raise newException(ValueError, "periodic refresh requires compiling with --threads:on")
  runServer(exporter.address, exporter.port,
    proc(httpMethod, path, acceptEncoding: string): HttpResponse =
      exporter.handleRequest(httpMethod, path, acceptEncoding))

proc run*(exporter: Exporter) = exporter.start()
