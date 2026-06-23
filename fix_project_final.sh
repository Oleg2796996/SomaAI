#!/bin/bash

echo "🚀 Starting SomaAI Project Recovery..."

# 1. Install xcodegen if missing (the most reliable way to generate xcodeproj from a config)
if ! command -v xcodegen &> /dev/null
then
    echo "Installing xcodegen via Homebrew..."
    brew install xcodegen
fi

# 2. Create a project.yml for xcodegen
# This is the "blueprint" that tells xcodegen how to build the .xcodeproj
cat <<PROJECT_YML > project.yml
name: SomaAI
options:
  iosDeploymentTarget: "17.0"

targets:
  SomaAI:
    type: application
    platform: iOS
    sources:
      - path: Sources/App
      - path: Sources/Models
      - path: Sources/Views
    settings:
      SWIFT_VERSION: 5.9
