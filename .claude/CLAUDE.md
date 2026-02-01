# Sol - Local Build Notes

## Build Commands

### Debug build
```bash
xcodebuild -workspace macos/sol.xcworkspace -scheme debug -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  SENTRY_DISABLE_AUTO_UPLOAD=true
```

### Release build
```bash
xcodebuild -workspace macos/sol.xcworkspace -scheme release -configuration Release build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  SENTRY_DISABLE_AUTO_UPLOAD=true
```

## Deploy Release Build

After a successful release build, deploy to the local install location:

```bash
pkill -x "sol" 2>/dev/null
sleep 1
rm -rf ~/.local/bin/Sol.app
cp -R ~/Library/Developer/Xcode/DerivedData/sol-gdvyshnnayltqpgxojdzmotahcny/Build/Products/Release/sol.app ~/.local/bin/Sol.app
open ~/.local/bin/Sol.app
```

The release app lives at `~/.local/bin/Sol.app`. The Homebrew cask version has been uninstalled.

## Yabai Scripting Addition

Sol uses yabai's scripting addition (SA) to move windows across Spaces. The SA is injected into Dock.app and provides a Unix socket at `/tmp/yabai-sa_<user>.socket`.

- Yabai is installed via Homebrew: `/opt/homebrew/bin/yabai`
- SA loads on login via LaunchAgent: `~/Library/LaunchAgents/com.yabai.load-sa.plist`
- Sudoers rule at `/private/etc/sudoers.d/yabai` allows passwordless `sudo yabai --load-sa`
- If yabai is upgraded, update the SHA256 hash in the sudoers file

### Required System Config
- SIP: fully disabled (`csrutil disable` from Recovery)
- Boot args: `-arm64e_preview_abi` (set via `sudo nvram boot-args=-arm64e_preview_abi`)

## Key Files (Local Modifications)

- `macos/sol-macOS/lib/SolNative.swift` — `openFile()` detects running apps and moves their window to current Space via yabai SA socket instead of switching Spaces. Uses CGWindowList fallback (largest window by area) when AX can't see windows on other Spaces. Path cleanup strips trailing `/` before `.app` suffix check, uses `URL(fileURLWithPath:)` for bundle resolution.
- `macos/sol-macOS/lib/SpacesMover.swift` — Connects to yabai SA socket, sends `WINDOW_TO_SPACE` opcode (0x13) with current space ID and window ID. Uses SkyLight dlsym for `CGSGetActiveSpace`.
- `macos/sol-macOS/managers/HotKeyManager.swift` — Added numpad Enter (keyCode 76) alongside main Return (keyCode 36).
- `src/stores/keystroke.store.ts` — Added `case 76:` fallthrough to `case 36:` for numpad Enter.
- `src/env.ts` — Stub file (gitignored), needed for Metro bundler: `export const SentryDSN = ''`

## Notes

- `src/env.ts` is gitignored. If missing, create it with `export const SentryDSN = ''`
- Debug logging writes to `/tmp/sol-debug.log` (can be removed later)
- The `solLog()` function in SolNative.swift and `SpacesMover.log()` write to that file
