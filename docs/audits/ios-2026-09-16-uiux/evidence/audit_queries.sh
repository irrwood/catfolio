#!/usr/bin/env bash
# Every count quoted in README.md, reproducible from the repo root.
# Usage: bash docs/audits/ios-2026-09-16-uiux/evidence/audit_queries.sh
set -uo pipefail
cd "$(dirname "$0")/../../../.."          # repo root
SRC="CatfolioIOS/CatfolioIOS"

echo "== worktree =="
git rev-parse HEAD

echo
echo "== enforced design gate (expected: FAIL) =="
python3 scripts/check_ios_design.py > /dev/null 2>&1
echo "scripts/check_ios_design.py exit=$?"
python3 -m unittest v3_backend.tests.test_ios_design_rules 2>&1 | tail -3

echo
echo "== localization gate (expected: OK) =="
python3 scripts/check_ios_localizations.py

echo
echo "== fonts that bypass Typography =="
printf 'font(.system( ...) call sites      : %s\n' "$(grep -rn '\.font(\.system(' $SRC/*.swift | wc -l | tr -d ' ')"
printf 'Typography.number(size:)/text(size:): %s\n' "$(grep -rn 'Typography\.number(size:\|Typography\.text(size:' $SRC/*.swift | wc -l | tr -d ' ')"
printf 'font(.footnote/.caption/...) legacy : %s\n' "$(grep -rn '\.font(\.\(footnote\|caption\|caption2\|subheadline\|body\|headline\|title\)' $SRC/*.swift | wc -l | tr -d ' ')"
printf 'appText/appNumber/appCaps           : %s\n' "$(grep -rn '\.app\(Text\|Number\|Caps\)(' $SRC/*.swift | wc -l | tr -d ' ')"

echo
echo "== colour literals the checker cannot see =="
printf 'Color.<builtin> usages              : %s\n' "$(grep -rn 'Color\.\(red\|green\|blue\|orange\|yellow\|purple\|pink\|gray\|black\|white\)\b' $SRC/*.swift | wc -l | tr -d ' ')"
printf 'distinct cornerRadius values        : %s\n' "$(grep -rhoE 'cornerRadius: [0-9]+' $SRC/*.swift | sort -u | wc -l | tr -d ' ')"
printf 'distinct .padding numeric values    : %s\n' "$(grep -rhoE '\.padding\([^)]*\)' $SRC/*.swift | grep -oE '[0-9]+' | sort -u | wc -l | tr -d ' ')"
printf 'distinct spacing: values            : %s\n' "$(grep -rhoE 'spacing: [0-9]+' $SRC/*.swift | sort -u | wc -l | tr -d ' ')"

echo
echo "== accessibility =="
printf 'accessibilitySortPriority           : %s\n' "$(grep -rn 'accessibilitySortPriority' $SRC/*.swift | wc -l | tr -d ' ')"
printf 'accessibilityRepresentation         : %s\n' "$(grep -rn 'accessibilityRepresentation' $SRC/*.swift | wc -l | tr -d ' ')"
printf 'UIAccessibility.post(announcement)  : %s\n' "$(grep -rn 'UIAccessibility.post' $SRC/*.swift | wc -l | tr -d ' ')"
printf 'files mentioning reduceMotion       : %s of %s\n' "$(grep -rl 'accessibilityReduceMotion' $SRC/*.swift | wc -l | tr -d ' ')" "$(ls $SRC/*.swift | wc -l | tr -d ' ')"
printf 'files with .animation but no reduceMotion: %s\n' "$(for f in $(grep -rl 'withAnimation\|\.animation(' $SRC/*.swift); do grep -q accessibilityReduceMotion $f || echo x; done | wc -l | tr -d ' ')"

echo
echo "== adaptation =="
printf 'horizontalSizeClass / userInterfaceIdiom: %s\n' "$(grep -rn 'horizontalSizeClass\|userInterfaceIdiom' $SRC/*.swift | wc -l | tr -d ' ')"
printf '#Preview blocks                         : %s\n' "$(grep -rn '#Preview' $SRC/*.swift | wc -l | tr -d ' ')"
printf '.formatted( without explicit locale    : %s\n' "$(grep -rn '\.formatted(' $SRC/*.swift | grep -vc 'locale')"
printf 'refreshable modifiers                   : %s\n' "$(grep -rn 'refreshable' $SRC/*.swift | wc -l | tr -d ' ')"
