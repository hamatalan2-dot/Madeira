# Madeira manual-game-library cleanup

This source bundle removes the Epic Games integration and Ubisoft Connect integration from the app target and source tree. The library screen is now manual-only: games are added by selecting an executable under Madeira's `wine/drive_c` folder, and their covers are chosen from local image files. Steam sign-in, Steam library, and Madeira Dock entry points are disabled/hidden; the Steam store search and the Steam game section are no longer exposed in the library UI.

## Validation performed

- Swift parser check (`swiftc -frontend -parse`) passed for the changed Swift files.
- `plutil -lint app/Madeira.xcodeproj/project.pbxproj` passed.
- No Epic or Ubisoft integration references remain in the app Swift sources or Xcode project (the word `Epic` may occur in unrelated system/API identifiers elsewhere).

## Important limitation

This bundle does **not** yet physically delete every legacy Steam/Dock implementation file. Some launch/session code in `ContentView.swift` and `Library.swift` is still coupled to those types; deleting those files before refactoring those call sites would create compile errors. Their user-facing entry points are disabled, and the manual library no longer displays Steam-owned/uninstalled games. A full physical removal requires a further coordinated refactor of those launch/session paths.

A full Xcode/iOS build was not run in this environment; the syntax and project-file checks are not a substitute for the macOS GitHub Actions IPA build.
