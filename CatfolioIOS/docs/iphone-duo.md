# iPhone Duo navigation adaptation

## Navigation policy

- Expanded iPhone windows (both size classes regular) use the existing `NativeWorkspace`, exactly as iPad does: native split view, page links, holdings and search in the sidebar, and a detail navigation stack.
- Compact phone windows use the existing icon-only tabs and per-tab navigation stacks. Duo's native system decides the vertical tab-bar placement.
- `AdaptivePhoneWorkspace` retains both hosting controllers and attaches only the active one. Folding does not discard either hierarchy's local state; the workspace is created lazily on first expansion.
- The selected top-level destination is shared. Each layout retains its own navigation history, search and local controls; a pushed workspace page is restored when reopening the workspace, rather than transferred into the compact phone stack.
- The existing bottom-bar scroll animation applies only to a horizontal bottom bar. It does not move Duo's vertical bar.
- iPad and Mac continue to use their existing workspace directly. This does not change financial calculations.

## Toolchain and verification

Xcode was upgraded to **27.1 (27A9275)** and the **iOS 27.1 (24A94425)** runtime was installed on 2026-10-24. The deployment target remains iOS 18.

Dedicated simulator: `Catfolio Duo 验证` (`B613C9A1-721B-4BC3-94ED-A8CA35B72529`). Captures use the app's built-in demonstration portfolio, not a personal account.

The first real Duo run exposed that adapting phone tabs to a sidebar was not the requested iPad/Mac workspace. That approach has been replaced with the shared `NativeWorkspace`. Validation of the corrected workspace is in progress.

The design checker reports existing repository colour-budget violations; the adaptive container and root navigation are not flagged.

Additional release coverage beyond this fold/sidebar demonstration: Split View on either side, all Dynamic Type sizes, sheets and keyboard transitions, security-detail transitions, cancelled Back gestures, and all chart interactions around reserved regions.

## Apple references

- [Prepare your app for iPhone Duo](https://developer.apple.com/iphone-duo/prepare/)
- [Prepare your app for iPhone Duo — Tech Talk](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
