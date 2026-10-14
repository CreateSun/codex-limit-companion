# Changelog

## 0.0.4 — 2026-10-14

- Removed simulated foreground paste and Return keystrokes. Existing paste settings are disabled on startup; historical paste logs remain readable.
- Added software update checks at launch and every six hours, a top-of-panel update banner, manual download, and optional automatic downloading (off by default). Installation always asks for confirmation and defers while session messages are being sent.
- Updates use only the project's official GitHub release assets. Version, SHA-256, bundle identity, architecture, minimum OS version and signature integrity are checked before installation. A helper replaces the app after exit and rolls back copy/launch-command failures. Existing preferences and history remain outside the app bundle.
- Automatic installation supports a writable `/Applications` or `~/Applications` installation on Apple Silicon. Other locations and Intel builds use manual/source updates. Packages remain ad-hoc signed, not Apple-notarized. Successful `open` means launch was requested, not a guarantee against later crashes.
- Recovery uses hysteresis: any window at <=1% remaining (or a server restriction) arms waiting; all observed windows must have >=5% remaining and no server restriction on two successful reads separated by at least 45 seconds (normally 60). A gap over 150 seconds, errors, or a fall below 5% restarts confirmation. Missing/changed windows invalidate the episode. One message per selected session per confirmed recovery episode; no automatic send retries.
- Starting with healthy quota does not send a message. The 5% buffer reduces edge-case failures but cannot guarantee sufficient quota for the entire resumed task.
