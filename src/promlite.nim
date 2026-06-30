import std/[locks, math, os, strutils, tables, times]

type
  Label* = tuple[name, value: string]
  Collector* = proc(m: var MetricsBuilder) {.gcsafe.}
  MetricKind* = enum mkGauge = "gauge", mkCounter = "counter"

  MetricsBuilder* = object
    text: string
    outFile: File
    fileBacked: bool
    emittedTypes: Table[string, MetricKind]
    strictNames: bool

  CachedResponse* = object
    path*: string
    generatedAtUnix*: int64

  Exporter* = ref object
    address: string
    port: int
    refreshIntervalSeconds: int
    dataDir: string
    metricsFileName: string
    forceGcAfterRefresh: bool
    strictNames: bool
    collector: Collector
    lock: Lock
    cache: CachedResponse
    ready: bool
    lastRefreshUnix: int64
    lastRefreshOk: bool
    refreshFailures: uint64

when compileOption("threads"):
  import std/typedthreads

const
  DefaultPort* = 9090
  DefaultDataDir* = "/data"
  DefaultMetricsFileName* = "metrics"
  MetricsContentType* = "text/plain; version=0.0.4; charset=utf-8"

{.compile: "promlite/vendor/darkhttpd_promlite.c".}

proc darkhttpdMain(argc: cint; argv: cstringArray): cint {.importc: "promlite_darkhttpd_main".}

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
  result.emittedTypes = initTable[string, MetricKind]()

proc initFileMetricsBuilder(outFile: File; strictNames = true): MetricsBuilder =
  result.strictNames = strictNames
  result.outFile = outFile
  result.fileBacked = true
  result.emittedTypes = initTable[string, MetricKind]()

proc add(builder: var MetricsBuilder; value: string) =
  if builder.fileBacked:
    builder.outFile.write(value)
  else:
    builder.text.add(value)

proc add(builder: var MetricsBuilder; value: char) =
  if builder.fileBacked:
    builder.outFile.write(value)
  else:
    builder.text.add(value)

proc requireMetricName(builder: MetricsBuilder; name: string) =
  if builder.strictNames and not isValidMetricName(name):
    raise newException(ValueError, "invalid Prometheus metric name: " & name)

proc requireLabelName(builder: MetricsBuilder; name: string) =
  if builder.strictNames and not isValidLabelName(name):
    raise newException(ValueError, "invalid Prometheus label name: " & name)

proc help*(builder: var MetricsBuilder; name, doc: string) =
  builder.requireMetricName(name)
  builder.add("# HELP ")
  builder.add(name)
  builder.add(' ')
  builder.add(escapeHelp(doc))
  builder.add('\n')

proc metricType*(builder: var MetricsBuilder; name: string; kind: MetricKind) =
  builder.requireMetricName(name)
  if builder.emittedTypes.hasKey(name):
    let existingKind = builder.emittedTypes[name]
    if existingKind != kind:
      raise newException(ValueError, "conflicting Prometheus metric type for " &
        name & ": " & $existingKind & " vs " & $kind)
    return
  builder.emittedTypes[name] = kind
  builder.add("# TYPE ")
  builder.add(name)
  builder.add(' ')
  builder.add($kind)
  builder.add('\n')

proc appendLabels(builder: var MetricsBuilder; labels: openArray[Label]) =
  if labels.len == 0:
    return
  builder.add('{')
  for i, label in labels:
    builder.requireLabelName(label.name)
    if i > 0:
      builder.add(',')
    builder.add(label.name)
    builder.add("=\"")
    builder.add(escapeLabelValue(label.value))
    builder.add('"')
  builder.add('}')

proc appendMetric(builder: var MetricsBuilder; name, value: string;
    labels: openArray[Label]; kind: MetricKind) =
  builder.metricType(name, kind)
  builder.add(name)
  builder.appendLabels(labels)
  builder.add(' ')
  builder.add(value)
  builder.add('\n')

proc formatMetricValue(value: SomeNumber): string =
  when value is SomeFloat:
    case classify(value)
    of fcNan: "NaN"
    of fcInf: "+Inf"
    of fcNegInf: "-Inf"
    else: $value
  else:
    $value

proc requireCounterValue(value: SomeNumber) =
  when value is SomeUnsignedInt:
    discard
  else:
    if value < 0:
      raise newException(ValueError, "Prometheus counter value must be non-negative")

proc gauge*(builder: var MetricsBuilder; name: string; value: SomeNumber;
    labels: openArray[Label] = []) =
  builder.appendMetric(name, formatMetricValue(value), labels, mkGauge)

proc counter*(builder: var MetricsBuilder; name: string; value: SomeNumber;
    labels: openArray[Label] = []) =
  requireCounterValue(value)
  builder.appendMetric(name, formatMetricValue(value), labels, mkCounter)

proc info*(builder: var MetricsBuilder; name: string; labels: openArray[Label] = []) =
  builder.gauge(name, 1, labels)

proc `$`*(builder: MetricsBuilder): string = builder.text

proc buildPlaintext*(collector: Collector; strictNames = true): string =
  var builder = initMetricsBuilder(strictNames)
  collector(builder)
  $builder

proc forceGarbageCollection() =
  when declared(GC_fullCollect):
    GC_fullCollect()
  elif declared(GC_collect):
    GC_collect()

proc newExporter*(address = "0.0.0.0"; port = DefaultPort; refreshIntervalSeconds = 0;
    collector: Collector = nil; dataDir = DefaultDataDir;
    metricsFileName = DefaultMetricsFileName; strictNames = true;
    forceGcAfterRefresh = true): Exporter =
  new(result)
  result.address = address
  result.port = port
  result.refreshIntervalSeconds = refreshIntervalSeconds
  result.collector = collector
  result.dataDir = dataDir
  result.metricsFileName = metricsFileName
  result.forceGcAfterRefresh = forceGcAfterRefresh
  result.strictNames = strictNames
  result.lastRefreshOk = false
  initLock(result.lock)

proc setCollector*(exporter: Exporter; collector: Collector) =
  withLock exporter.lock:
    exporter.collector = collector

proc selfMetrics(exporter: Exporter; builder: var MetricsBuilder; cacheReady: bool;
    lastRefreshUnix: int64; refreshFailures: uint64) =
  builder.help("promlite_cache_ready", "Whether the exporter has a cached metrics response")
  builder.gauge("promlite_cache_ready", if cacheReady: 1 else: 0)
  builder.help("promlite_last_refresh_timestamp_seconds", "Unix timestamp of the last successful metrics refresh")
  builder.gauge("promlite_last_refresh_timestamp_seconds", lastRefreshUnix)
  builder.help("promlite_refresh_failures_total", "Total failed metrics refresh attempts")
  builder.counter("promlite_refresh_failures_total", refreshFailures)

proc metricsPath*(exporter: Exporter): string = exporter.dataDir / exporter.metricsFileName

proc healthzPath(exporter: Exporter): string = exporter.dataDir / "healthz"

proc ensureMetricsFile*(exporter: Exporter) =
  createDir(exporter.dataDir)
  let path = exporter.metricsPath()
  if not fileExists(path):
    writeFile(path, "")
  let healthPath = exporter.healthzPath()
  if not fileExists(healthPath):
    writeFile(healthPath, "ok\n")

proc metricsTmpPath(exporter: Exporter): string =
  exporter.metricsPath() & ".tmp." & $getCurrentProcessId() & "." & $epochTime()

proc refresh*(exporter: Exporter): bool {.discardable.} =
  var collector: Collector
  withLock exporter.lock:
    collector = exporter.collector
  if collector.isNil:
    raise newException(ValueError, "collector is not configured")

  var tmpPath = ""
  var outFile: File
  try:
    exporter.ensureMetricsFile()
    tmpPath = exporter.metricsTmpPath()
    if not open(outFile, tmpPath, fmWrite):
      raise newException(IOError, "cannot open metrics temp file: " & tmpPath)

    var builder = initFileMetricsBuilder(outFile, exporter.strictNames)
    collector(builder)
    let generatedAtUnix = epochTime().int64
    var refreshFailures: uint64
    withLock exporter.lock:
      refreshFailures = exporter.refreshFailures
    exporter.selfMetrics(builder, cacheReady = true, lastRefreshUnix = generatedAtUnix,
      refreshFailures = refreshFailures)
    outFile.flushFile()
    outFile.close()
    outFile = nil
    moveFile(tmpPath, exporter.metricsPath())
    let snapshot = CachedResponse(path: exporter.metricsPath(), generatedAtUnix: generatedAtUnix)
    withLock exporter.lock:
      exporter.cache = snapshot
      exporter.ready = true
      exporter.lastRefreshUnix = snapshot.generatedAtUnix
      exporter.lastRefreshOk = true
    if exporter.forceGcAfterRefresh:
      forceGarbageCollection()
    true
  except CatchableError:
    if outFile != nil:
      outFile.close()
    if tmpPath.len > 0 and fileExists(tmpPath):
      removeFile(tmpPath)
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

when compileOption("threads"):
  proc refreshLoop(exporter: Exporter) {.thread.} =
    while true:
      discard exporter.refresh()
      sleep(exporter.refreshIntervalSeconds * 1000)

  proc darkhttpdLoop(exporter: Exporter) {.thread.} =
    let portText = $exporter.port
    var args = allocCStringArray([
      "darkhttpd",
      exporter.dataDir,
      "--addr", exporter.address,
      "--port", portText,
      "--no-listing",
      "--no-keepalive",
      "--default-mimetype", MetricsContentType,
      "--header", "Cache-Control: no-store"
    ])
    discard darkhttpdMain(12.cint, args)
    deallocCStringArray(args)

proc start*(exporter: Exporter) =
  if exporter.collector.isNil:
    raise newException(ValueError, "collector is not configured")
  exporter.ensureMetricsFile()
  if exporter.refreshIntervalSeconds > 0:
    when compileOption("threads"):
      var thread: Thread[Exporter]
      createThread(thread, refreshLoop, exporter)
    else:
      raise newException(ValueError, "periodic refresh requires compiling with --threads:on")
  else:
    discard exporter.refresh()
  when compileOption("threads"):
    var httpThread: Thread[Exporter]
    createThread(httpThread, darkhttpdLoop, exporter)
    joinThread(httpThread)
  else:
    raise newException(ValueError, "darkhttpd serving requires compiling with --threads:on")

proc run*(exporter: Exporter) = exporter.start()
