#!/bin/bash
echo "Starting Soma AI Project Setup..."

# 1. Correct Folder Structure for SPM
if [ -d "Source" ]; then
    echo "Renaming Source to Sources for SPM compliance..."
    mv Source Sources
fi

# 2. Create Package.swift with EXPLICIT swift-tools-version header
echo "Generating Package.swift..."
cat <<EOP > Package.swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SomaAI",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .executable(name: "SomaAI", targets: ["SomaAI"])
    ],
    targets: [
        .executableTarget(
            name: "SomaAI",
            dependencies: [],
            path: "Sources"
        )
    ]
)
EOP

echo "Project setup complete. You can now open this folder in Xcode."
