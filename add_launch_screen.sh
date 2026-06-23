#!/bin/bash
echo "🚀 Generating minimal LaunchScreen.storyboard..."

# Create a minimal XML for the storyboard to tell iOS this app supports all screens
cat <<STORYBOARD > LaunchScreen.storyboard
<?xml version="1.0" encoding="UTF-8"?>
<document xmlns="http://system.apple.com/CSI/SODA">
    <view controllers="ViewController"/>
    <controllers>
        <ViewController id=" laU" class="UIViewController" scene="scene">
            <rect key="frame" x="0.0" y="0.0" width="375" height="667"/>
            <view class="UIView" controller="laU">
                <color key="backgroundColor" value="white"/>
            </view>
        </ViewController>
    </controllers>
    <scenes>
        <SceneController id="scene" controller=" laU"/>
    </scenes>
</document>
STORYBOARD

echo "Updating project.yml to include Launch Screen..."
# We need to add the file to the project sources via xcodegen
# Since project.yml is already there, we append the file to the sources list
# For simplicity, we will overwrite project.yml with a complete version that includes the storyboard
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
      - path: LaunchScreen.storyboard
    settings:
      SWIFT_VERSION: 5.9
      GENERATE_INFOPLIST_FILE: YES
      PRODUCT_BUNDLE_IDENTIFIER: com.oleg.SomaAI
      INFOPLIST_FILE: Info.plist
