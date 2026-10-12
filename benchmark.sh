#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 Sources/Forecast.swift Sources/StatusStyle.swift Benchmarks/Performance.swift -o build/performance-benchmark
build/performance-benchmark
