// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Atrium",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic (Foundation + CoreGraphics only): geometry, badge parsing, model, persistence.
        .target(name: "AtriumCore", path: "Sources/AtriumCore"),
        // The app (AppKit + SwiftUI + AX). Entry point: Sources/Atrium/main.swift
        .executableTarget(name: "Atrium", dependencies: ["AtriumCore"], path: "Sources/Atrium",
                          linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "AtriumCoreTests", dependencies: ["AtriumCore"], path: "Tests/AtriumCoreTests"),
    ]
)
