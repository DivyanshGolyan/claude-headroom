#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/Forecast.swift Tests/ForecastTests.swift -o build/forecast-tests
build/forecast-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/StatusStyle.swift Tests/StyleTests.swift -o build/style-tests
build/style-tests
