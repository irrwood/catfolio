# App icon

Source: user-provided `Catfolio-logo Exports 2`, imported on 2026-10-12.

Both Debug and Release use `Assets.xcassets/AppIconFish.appiconset`.
All images retain the supplied 1024 × 1024 composition and scale.

| Asset | Source export | Format preparation |
| --- | --- | --- |
| `icon-default.png` | `Catfolio-logo-iOS-Default-1024@1x.png` | Flatten transparent corners against white and remove alpha for the App Store icon. |
| `icon-dark.png` | `Catfolio-logo-iOS-Dark-1024@1x.png` | Original PNG, unchanged. |
| `icon-tinted.png` | `Catfolio-logo-iOS-TintedDark-1024@1x.png` | Convert to grayscale over black; iOS supplies the user's selected tint. |

The current asset catalog has Any, Dark and Tinted slots. The supplied Clear Light,
Clear Dark and Tinted Light PNG previews are not separate asset-catalog slots;
customizing all six appearances requires the original layered Icon Composer file.
See [Apple's asset catalog documentation](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).
