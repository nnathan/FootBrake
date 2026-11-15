# FootBrake

Shrink and trim iPhone videos with the hardware encoder. See `PLAN.md`.

## Layout
- `FootBrake/`: SwiftUI iOS app (iOS 16+)
- `FootBrakeCore/`: Swift package holding the media engine, the `footbrake-cli` Mac test harness, and tests
- `Fixtures/make-fixtures.sh`: generates synthetic test clips into `Fixtures/out/` (needs Homebrew ffmpeg)
- `Config/`: build settings. Copy `Local.xcconfig.example` to `Local.xcconfig` and set your Team ID.

## Common commands
```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
(cd FootBrakeCore && swift test)                 # engine tests on the Mac
(cd FootBrakeCore && swift run footbrake-cli caps)
./Fixtures/make-fixtures.sh
open FootBrake.xcodeproj                         # run on iPhone from Xcode
```
