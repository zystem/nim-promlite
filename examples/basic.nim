import std/times

import promlite

proc collect(m: var MetricsBuilder) =
  m.help("my_app_items_total", "Number of processed items")
  m.counter("my_app_items_total", 123)

  m.help("my_app_cache_ready", "Whether cache is ready")
  m.gauge("my_app_cache_ready", 1)

  m.gauge("my_app_last_refresh_timestamp_seconds", epochTime())
  m.info("my_app_build_info", labels = {"version": "dev", "runtime": "nim"})

let exporter = newExporter(
  refreshIntervalSeconds = 60,
  collector = collect
)

exporter.run()
