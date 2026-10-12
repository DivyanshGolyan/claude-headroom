#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/Forecast.swift Tests/ForecastTests.swift -o build/forecast-tests
build/forecast-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/RefreshGate.swift Sources/HistoryStore.swift Tests/EfficiencyTests.swift -o build/efficiency-tests
build/efficiency-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/RefreshGate.swift Sources/RuntimeTimeline.swift Sources/HTTPDate.swift Tests/ClockDomainTests.swift -o build/clock-domain-tests
build/clock-domain-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/RefreshGate.swift Sources/RuntimeTimeline.swift Sources/ResponseTiming.swift Tests/ResponseTimingTests.swift -o build/response-timing-tests
build/response-timing-tests
mkdir -p build/StyleTests.app/Contents/MacOS build/StyleTests.app/Contents/Resources
cp Resources/Claude.svg build/StyleTests.app/Contents/Resources/
swiftc -swift-version 5 Sources/Forecast.swift Sources/StatusStyle.swift Sources/ClaudeMark.swift Tests/StyleTests.swift -o build/StyleTests.app/Contents/MacOS/style-tests
build/StyleTests.app/Contents/MacOS/style-tests
