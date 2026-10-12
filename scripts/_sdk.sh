# Sourced by scripts that build against the core modules: one SDK for modules and their users.
# The macOS 26.5 SDK is preferred because the 27 SDK needs the SwiftUI macro plugin that only ships in Xcode.
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
SWIFT_TARGET="$(uname -m)-apple-macos15.0"
