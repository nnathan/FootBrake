# FootBrake

Shrink and trim iPhone videos with the hardware encoder. See `PLAN.md`.

Free software in the spirit of [HandBrake](https://handbrake.fr): no ads, no monetisation, no
telemetry. FootBrake will always respect its users.

## Devices

FootBrake runs on iPhone and iPad with iOS 16 or later. It has been tested on an iPhone 17 Pro
Max; the iPad version has only been checked in the simulator, as we don't have an iPad to test
on. iPad feedback is very welcome: please open an issue.

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

## Releasing

`Tools/release.sh` archives the app and uploads it to App Store Connect for TestFlight. It needs
a clean tree that's been pushed to GitHub, and uses the commit count as the build number. The
App Store listing text is in `AppStore/listing.md`.

## Licence

Copyright (C) 2026 Naveen Nathan

FootBrake is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License, version 3, as published by the Free Software Foundation
(SPDX: `GPL-3.0-only`). It is distributed in the hope that it will
be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See `LICENSE` for the full text.

Contributions are accepted under the terms in `CONTRIBUTING.md`. The FootBrake name and icon
are not covered by the licence; see `TRADEMARKS.md`.

FootBrake contains no code from HandBrake; its presets and VideoToolbox approach were studied
as a reference.
