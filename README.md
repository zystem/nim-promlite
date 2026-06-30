# promlite

`promlite` is a small snapshot-oriented Nim package for writing lightweight
Prometheus exporters. It is designed primarily for long-running exporters that
collect metrics from external systems, transform them, and expose the latest
successful snapshot from their own `/metrics` endpoint.

Application code only describes metrics. The package handles Prometheus text
formatting, label escaping, gzip compression, response caching, and the
`/metrics` and `/healthz` HTTP endpoints.

The cache-first design exists for exporters that poll systems such as Harbor,
cloud APIs, or other services where collection can be slower or less reliable
than a Prometheus scrape. Instead of pushing processed metrics to Pushgateway,
the exporter can keep the last successful snapshot in memory and let Prometheus
scrape it. Real-time metrics are still possible by refreshing the cache on
demand or very frequently, but that is not the most convenient mode this
library is optimized for.

The default listen port is `9090`. For Docker exporters, the intended mode is
to run the process directly as an unprivileged user such as `nobody` and listen
on this non-privileged port.

## Status

`promlite` is an MVP package. The public API focuses on:

- gauges, counters, and info-style metrics
- HELP and TYPE lines
- labels and Prometheus label escaping
- strict metric and label name validation
- gzip-compressed cached responses
- `/metrics` and `/healthz`
- optional periodic refresh
- exporter self-metrics

The package intentionally avoids persistent metric registries, histograms,
summaries, exemplars, OpenMetrics negotiation, TLS, middleware, and async
framework integration.

## Install

The package uses `zlib` via Nim's zlib bindings, so a system `zlib` development library is required to build it (for example `zlib` / `zlib-devel`).

After the package is published to Nimble:

```bash
nimble install promlite
```

From a local checkout:

```bash
nimble install
```

Then:

```nim
import promlite
```

## Quick Start

```nim
import std/times
import promlite

proc collect(m: var MetricsBuilder) =
  m.help("my_app_items_total", "Number of processed items")
  m.counter("my_app_items_total", 123)

  m.help("my_app_cache_ready", "Whether cache is ready")
  m.gauge("my_app_cache_ready", 1)

  m.gauge("my_app_last_refresh_timestamp_seconds", epochTime())
  m.info("my_app_build_info", labels = {"version": "dev"})

let exporter = newExporter(
  refreshIntervalSeconds = 60,
  collector = collect
)

exporter.run()
```

`GET /metrics` serves the cached snapshot as gzip when the client sends
`Accept-Encoding: gzip`, with:

```http
Content-Type: text/plain; version=0.0.4; charset=utf-8
Content-Encoding: gzip
Content-Length: <compressed length>
```

`GET /healthz` returns `ok`.

## Snapshot Model

`promlite` favors fresh metric snapshots and atomic cache replacement over a
large persistent metric registry:

1. The collector builds a fresh `MetricsBuilder`.
2. `promlite` serializes the builder to Prometheus text format.
3. The plaintext is gzip-compressed.
4. The compressed response is swapped into the cache.
5. Scrapes read the cached response without rebuilding metrics.

If a refresh fails, the previous successful cached response stays live.

## Examples

```bash
nim c -r --threads:on --path:src examples/basic.nim
```

Periodic refresh uses a background thread, so compile exporters that set
`refreshIntervalSeconds > 0` with `--threads:on`.

## Vendored HTTP Core

The vendored darkhttpd-derived C core lives under `src/promlite/vendor/`.
It is package-internal plumbing for in-memory HTTP responses and is not exposed
as the public Nim API.

The public package API intentionally does not expose darkhttpd concepts.

## License

`promlite` is distributed under the MIT license.

The vendored darkhttpd-derived C code under `src/promlite/vendor/` is
distributed under the ISC license:

```text
Copyright (c) 2003-2025 Emil Mikulic <emikulic@gmail.com>
```

## Tests

```bash
nimble test
```
