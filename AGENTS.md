# MonitorInput

- AppKit and SwiftUI menu-bar app for Apple Silicon and macOS 14.4+. `Sources/App` owns UI, `Sources/Core` owns preferences and switching logic, and `Sources/Hardware` owns monitor and display access.
- Keep patches focused. Add user-facing strings to both English and Russian in `Resources/Localizable.xcstrings`.
- Preserve serialized DDC/CI writes to VCP `0x60`, live identity and input checks, bounded retries, and readback. Cached readings are for display only.
- Work on `develop`. For releases, prepare `release/<version>`, fast-forward `main` and `develop`, and publish the tested DMG under tag `v<version>`.

```sh
xcodebuild -scheme MonitorInput -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/MonitorInputBuild build-for-testing
xcrun xctest /tmp/MonitorInputBuild/Build/Products/Release/MonitorInputTests.xctest
```
