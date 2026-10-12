# Codex Limit Companion

macOS menu-bar helper that reads the current Codex account's short usage window. It checks every 60 seconds and, after it observes a reached window recover, sends the recovery message to the **sessions you selected** via `codex queue`（可多选）, and can additionally paste into the foreground ChatGPT/Codex task（旧行为）.

## Run

```bash
git clone https://github.com/CreateSun/codex-limit-companion.git
cd codex-limit-companion
zsh build-app.sh
open CodexLimitCompanion.app
```

Prerequisites:

- macOS 14+ and Xcode/Swift 5.10+
- `codex` is installed and logged in with the same ChatGPT account
- Grant the launched executable access at **System Settings → Privacy & Security → Accessibility** when macOS requests it

The app locates Codex using `CODEX_CLI_PATH`, then `PATH`, then common home-directory installation locations (`~/.n/bin`, `~/.codex/bin`, `~/.local/bin`). It also adds the Node.js directory to its child-process environment for Finder launches.

## Controls

- The menu-bar title displays the **remaining** usage percentage of the 5-hour window（`Codex: 剩余 X%`），与 ChatGPT 客户端「剩余用量」口径一致。
- **发送到会话…** submenu lists all Codex sessions（来自 `thread/list`，取最近 100 个）with a checkmark per session; check the ones you want, one or many. 选择会持久化。
- **发送到已选会话** manually queues the recovery message to all selected sessions right away（测试用）。
- **额度恢复时自动发送到会话** is enabled by default: on limit recovery, queues the message to all selected sessions via `codex queue`（不依赖 UI 焦点）。
- **额度恢复时自动粘贴** is enabled by default: legacy behavior that pastes into the *foreground* task.
- **粘贴后自动发送** is enabled by default: after pasting, it presses Return to submit. Uncheck to paste only.
- **粘贴到 ChatGPT** pastes into the foreground task manually（也受「粘贴后自动发送」控制）。

### 会话定位方式

- 旧的「粘贴」方式**不会选择会话**：它只是激活 Codex/ChatGPT 窗口并把内容粘贴到**当前前台聚焦的那个任务**。多个会话并存时以当前窗口显示的任务为准——不可靠。
- 新的「发送到会话」方式通过 `codex queue --thread <id> --message <msg>` 定向投递，指定哪个会话就是哪个，可一次发给多个。

## Release 0.0.1

Download `CodexLimitCompanion-0.0.1-macos-arm64.zip` from [Releases](https://github.com/CreateSun/codex-limit-companion/releases/tag/v0.0.1), unzip it, and open `CodexLimitCompanion.app`. The app appears in the menu bar, not the Dock. The prebuilt app targets Apple Silicon and macOS 14 or later; Intel users can build from source on an Intel Mac.

This initial release is ad-hoc signed, not Apple-notarized. If macOS blocks the downloaded app, allow it in System Settings → Privacy & Security, or build it locally.

### Requirements and behavior

- Install and sign in to a Codex CLI that supports `codex app-server` and `codex queue`; check `codex queue --help` before use.
- Keep the companion running before quota recovery: it must first observe an exhausted window, then an available window. Starting it after recovery does not trigger a message.
- Select the intended sessions in **发送到会话…**. Selections are saved between launches.
- For targeted delivery, enable **额度恢复时自动发送到会话** and disable **额度恢复时自动粘贴** to avoid also submitting to the foreground task. Both modes are enabled by default.
- **发送到已选会话** sends immediately; it is not a dry run.
- Accessibility permission is needed only for the foreground paste mode.
- The current implementation monitors one short-window bucket and does not guarantee recovery of every model-specific or weekly limit. Failed sends are reported without automatic retry.
- Preferences stay in local macOS UserDefaults; credentials are handled by your local Codex CLI and are not included in this repository.
