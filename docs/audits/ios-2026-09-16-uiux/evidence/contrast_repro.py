#!/usr/bin/env python3
"""WCAG 2.x contrast ratios for the tokens the app actually paints text with.

Reproduces the audit's contrast table. Values are transcribed from
CatfolioIOS/CatfolioIOS/DesignSystem.swift; the ratio maths is the WCAG 2.x
relative-luminance formula.
"""

def luminance(hex_colour: str) -> float:
    h = hex_colour.lstrip("#")
    channels = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    linear = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
              for c in channels]
    r, g, b = linear
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# (label, foreground, background, token source in DesignSystem.swift)
PAIRS = [
    ("gain() light   #008721 / white",       "#008721", "#FFFFFF", "CatfolioTheme.gain(for:.light)"),
    ("gain() light   #008721 / page",        "#008721", "#F2F2F7", "on systemGroupedBackground"),
    ("gainDefault    #34C759 / white",       "#34C759", "#FFFFFF", "CatfolioTheme.gainDefault"),
    ("Theme.positive #05AE5B / white",       "#05AE5B", "#FFFFFF", "CatfolioTheme.positive = green500"),
    ("loss() light   #E30045 / white",       "#E30045", "#FFFFFF", "CatfolioTheme.loss(for:.light)"),
    ("Theme.danger   #E30045 / white",       "#E30045", "#FFFFFF", "CatfolioTheme.danger = rose500"),
    ("CatfolioStyle.red    #E40014 / white", "#E40014", "#FFFFFF", "CatfolioStyle.red"),
    ("contributionRed      #D5312C / white", "#D5312C", "#FFFFFF", "CatfolioPalette.contributionRed"),
    ("CatfolioStyle.green  #2F8A3E / white", "#2F8A3E", "#FFFFFF", "CatfolioStyle.green"),
    ("contributionGreen    #00CC00 / white", "#00CC00", "#FFFFFF", "CatfolioPalette.contributionGreen"),
    ("Theme.warning  #EF7A00 / white",       "#EF7A00", "#FFFFFF", "CatfolioTheme.warning = orange500"),
    ("Theme.accent   #027DFF / white",       "#027DFF", "#FFFFFF", "CatfolioTheme.accent = blue500"),
    ("secondaryText  #8E8E93 / white",       "#8E8E93", "#FFFFFF", "SettingsTemplate.secondaryText"),
    ("readOnlyValue  40% label / white",     "#999999", "#FFFFFF", "SettingsTemplate.readOnlyValue"),
    ("tertiary text  .tertiary / white",     "#C7C7CC", "#FFFFFF", "SwiftUI .tertiary (approx)"),
    ("Home axis label white 16% over #9ADCFF", "#C8E6FF", "#9ADCFF", "PortfolioView.swift:1642"),
]

print(f"{'pair':<46} {'ratio':>6}  {'AA text 4.5':<11} {'AA large 3.0':<12} token")
print("-" * 104)
failures = []
for label, fg, bg, token in PAIRS:
    ratio = contrast(fg, bg)
    text_ok = "PASS" if ratio >= 4.5 else "FAIL"
    large_ok = "PASS" if ratio >= 3.0 else "FAIL"
    if text_ok == "FAIL":
        failures.append((label, ratio))
    print(f"{label:<46} {ratio:6.2f}  {text_ok:<11} {large_ok:<12} {token}")

print()
print(f"{len(failures)} of {len(PAIRS)} pairs below the 4.5:1 AA threshold for normal text.")
