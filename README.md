# Radio

A tiny macOS menu bar app for listening to Slovenian radio stations.

Stations: Val 202, Radio Prvi, Radio Ars, Radio Sora, Rock Radio, Radio Si.

## Build

Requires macOS 14+ and Xcode command line tools.

```sh
./build.sh
open build/Radio.app
```

`build.sh` compiles the Swift package in release mode, wraps it in `Radio.app` with `Info.plist` and the station logos from `Resources/`, and ad-hoc signs it.

## Layout

- `Sources/Radio/` – SwiftUI app: menu bar UI, `AVPlayer` wrapper, station list, login item toggle
- `Resources/` – app icon and station logos
- `Tools/` – scripts used to generate the app icon
