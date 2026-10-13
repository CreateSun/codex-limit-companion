# Development guide

macOS menu-bar helper that reads the current Codex account's short usage window. It checks every 60 seconds and, after it observes a reached window recover, sends the recovery message to the **sessions you selected** via `codex queue`（可多选）, and can additionally paste into the foreground ChatGPT/Codex task（旧行为）.

## Run

```bash
git clone https://github.com/CreateSun/codex-limit-companion.git
cd codex-limit-companion
zsh build-app.sh
open .build/package/CodexLimitCompanion.app
```

Prerequisites:

- macOS 14+; source builds require Xcode with the macOS 26 SDK
- `codex` is installed and logged in with the same ChatGPT account
- Accessibility permission is needed only when enabling foreground paste; targeted delivery does not require it

The app locates Codex using `CODEX_CLI_PATH`, then `PATH`, then common home-directory installation locations (`~/.n/bin`, `~/.codex/bin`, `~/.local/bin`). It also adds the Node.js directory to its child-process environment for Finder launches.

## Glass panel

The menu bar uses a GPT mark whose colored fill height represents the selected quota's remaining percentage. Teal means above 30%, orange 11–30%, and red 10% or lower. Unknown/error states are neutral. An optional numeric percentage can be enabled in Settings.

The Tab buttons have full-width 38-point hit areas. Settings rows align their descriptions to the leading edge and switches to the trailing edge.

Click the icon to open three pages:

- **额度概览**: choose the monitored quota bucket; see short and weekly windows, remaining percentages, reset timestamps and countdowns. All quota buckets returned by Codex are shown. Missing data stays unknown. The quota selector is hidden when only one bucket exists.
- **会话**: search recent sessions by title, project or ID, select multiple sessions, filter selected sessions, and clear selections. Sessions load only on first entry into this page, are cached for the app lifetime, and are updated using the manual refresh button. Reopening the panel never starts a session fetch, including after an error. Refreshing preserves the visible cached rows. Previously selected sessions outside the latest 100 results are identified and can be removed. Manual sending shows a confirmation with the message.
- **设置**: configure automatic targeted delivery, recovery notifications, menu-bar percentage, the recovery message, foreground paste, and submit-after-paste. Existing selections and settings are preserved.

On macOS 26+, the panel uses native SwiftUI Liquid Glass. On macOS 14–15 it uses a translucent material; Reduce Transparency is respected. Build the redesigned UI with an Xcode SDK supporting macOS 26.

Recovery tracks the selected quota bucket and waits until all its reported windows are available. Switching buckets or starting the app never counts as recovery. Other model buckets may still be limited. Errors retain the last successful data inside the panel but mark it stale and remove the menu-bar fill.

### Verification

```bash
swift test
# Optional: real local Codex reads only; sends no messages.
COMPANION_LIVE_CHECK=1 swift test --filter LiveReadTests
```

The GPT mark identifies the service monitored by this independent utility. OpenAI and ChatGPT marks belong to OpenAI; this app is not an official OpenAI product.

## Release 0.0.3

Download `CodexLimitCompanion-0.0.3-macos-arm64.zip` from [Releases](https://github.com/CreateSun/codex-limit-companion/releases/tag/v0.0.3), unzip it, and open `CodexLimitCompanion.app`. The app appears in the menu bar, not the Dock. The prebuilt app targets Apple Silicon and macOS 14 or later; Intel users can build from source on an Intel Mac.

This release is ad-hoc signed, not Apple-notarized. If macOS blocks the downloaded app, allow it in System Settings → Privacy & Security, or build it locally.

### Requirements and behavior

- Install and sign in to a Codex CLI that supports `codex app-server` and `codex queue`; check `codex queue --help` before use.
- Keep the companion running before quota recovery: it must first observe an exhausted window, then an available window. Starting it after recovery does not trigger a message.
- Select the intended sessions in **会话**. Selections are saved between launches.
- For targeted delivery, enable **恢复后发送到已选会话** and disable **额度恢复时自动粘贴** to avoid also submitting to the foreground task. Both modes are enabled by default.
- **立即发送到 … 个会话** asks for confirmation, then sends the message; it is not a dry run.
- Accessibility permission is needed only for the foreground paste mode.
- Automatic recovery follows all reported windows of the selected quota bucket; other model-specific buckets can remain limited. Failed sends are reported without automatic retry.
- Preferences stay in local macOS UserDefaults; credentials are handled by your local Codex CLI and are not included in this repository.

Quota polling and session reads reuse one background Codex App Server connection. The client waits for initialization, drains both output pipes, cancels completed request timers, and closes the connection on EOF, timeout, or app exit. The next explicit read can reconnect after a failure.

The app icon uses a gray GPT mark with blue fill fixed at 50%. Build output lives in `.build/package` to avoid registering multiple visible app copies. For everyday use, install only one copy in `/Applications/CodexLimitCompanion.app`.

The app runs only in the menu bar. Click its icon to toggle the anchored popover; click outside to dismiss. Reopening from Finder or Launchpad shows this same popover, never a detached window.

### Recovery history and estimated timing

**会话 → 恢复日志** keeps the latest 300 automatic recovery delivery records on this Mac. Each record includes the target session (when known), trigger time, exact message, and outcome. Queued means Codex accepted the message, not that the task finished. Foreground keyboard submission cannot confirm the target session or successful delivery and is labelled accordingly. History starts with this build; older events cannot be reconstructed. It is stored in `~/Library/Application Support/CodexLimitCompanion/recovery-history.json` with owner-only access and serialized background writes.

The overview shows the latest reset time among all exhausted windows as an estimate, with recovery checked every 60 seconds while running. Unknown or expired reset data is labelled unconfirmed. Actual delivery requires observing recovery and a configured automatic delivery route; sleep, network failures, or server restrictions can delay it.

On macOS Tahoe, check **System Settings → Menu Bar → Allow in the Menu Bar** if the icon is missing. Creating a status item successfully does not prove macOS has displayed it. The application does not substitute a standalone window for the menu bar popover.

On Tahoe, saved status-item placement is restored on the next main run-loop turn after creation. Popovers are presented only after the status window has a valid screen-top anchor; an unhosted status item must not open a panel at the bottom-left fallback position.

If the app's own Menu Bar switch is on but ControlCenter logs `Moving host to blocked list`, Tahoe may have associated the app with the developer host that launched it. On the development Mac, enabling **ChatGPT** in Menu Bar settings immediately produced `Unblocking host` for `local.codex.limit-companion` and restored a displayable item. This is an OS association workaround, not an app placement fix. Do not treat a valid proxy-window coordinate alone as proof that the icon is visible. Keep the host switch enabled until the system association is corrected; the app itself still uses the macOS system status bar.

## Distribution and website

To create a drag-to-Applications disk image from a signed bundle:

```bash
zsh scripts/package-dmg.sh .build/package/CodexLimitCompanion.app /absolute/path/CodexLimitCompanion.dmg
```

The script verifies the app signature, stages an Applications shortcut and install instructions, and creates and verifies a compressed DMG. It refuses to overwrite an existing output. The DMG is packaging only, not notarization.

GitHub Pages serves the static `docs/` directory from `main`. There is no JavaScript, tracking, external font or build dependency. Update the download versions in `README.md` and `docs/index.html` when publishing a new version. Product screenshots are actual UI captures; never commit private session titles or recovery messages.
