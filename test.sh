#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
python3 Tests/test_homebrew_release.py
python3 Tests/test_measure_app.py
swiftc -swift-version 5 Sources/Forecast.swift Tests/ForecastTests.swift -o build/forecast-tests
build/forecast-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/StatusPresentation.swift Tests/StatusPresentationTests.swift -o build/status-presentation-tests
build/status-presentation-tests
swiftc -swift-version 5 Sources/StatusMenu.swift Tests/MenuTriggerTests.swift -o build/menu-trigger-tests
build/menu-trigger-tests
swiftc -swift-version 5 Sources/SignInFlow.swift Tests/SignInFlowTests.swift -o build/sign-in-flow-tests
build/sign-in-flow-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/RefreshGate.swift Sources/HistoryStore.swift Tests/EfficiencyTests.swift -o build/efficiency-tests
build/efficiency-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/RefreshGate.swift Sources/RuntimeTimeline.swift Sources/StatusPresentation.swift Sources/HTTPDate.swift Tests/ClockDomainTests.swift -o build/clock-domain-tests
build/clock-domain-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/RefreshGate.swift Sources/RuntimeTimeline.swift Sources/StatusPresentation.swift Sources/ResponseTiming.swift Tests/ResponseTimingTests.swift -o build/response-timing-tests
build/response-timing-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/RefreshGate.swift Sources/RuntimeTimeline.swift Sources/StatusPresentation.swift Tests/DisplayScheduleTests.swift -o build/display-schedule-tests
build/display-schedule-tests
swiftc -swift-version 5 Sources/Forecast.swift Sources/StatusPresentation.swift Sources/RefreshGate.swift Sources/RuntimeTimeline.swift Sources/HistoryStore.swift Sources/HTTPDate.swift Sources/ResponseTiming.swift Sources/UsageClient.swift Sources/HeadroomProtocol.swift Sources/HeadroomEngine.swift Sources/LocalSocket.swift Sources/HeadroomServer.swift CLI/Command.swift Tests/HeadroomTests.swift -o build/headroom-tests
build/headroom-tests
mkdir -p build/StyleTests.app/Contents/MacOS build/StyleTests.app/Contents/Resources
cp Resources/Claude.svg build/StyleTests.app/Contents/Resources/
swiftc -swift-version 5 Sources/Forecast.swift Sources/StatusStyle.swift Sources/ClaudeMark.swift Tests/StyleTests.swift -o build/StyleTests.app/Contents/MacOS/style-tests
build/StyleTests.app/Contents/MacOS/style-tests
