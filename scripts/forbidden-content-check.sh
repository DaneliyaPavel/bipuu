#!/usr/bin/env bash
# Fails when the tree (or, with --history, any commit) contains the Coucou/Mochi identity,
# the original author's infrastructure identifiers, or protected media/asset file types.
# The pattern is written with bracketed letters so this file does not contain what it searches for.
# See docs/IP_MIGRATION.md. The files that must name them (to document the migration) are allow-listed.
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='cou[c]ou|mo[c]hi|notch ?bu[d]dy|lou[i]sraille|lou[i]s-cfm|256AUJ[9]555|rail[l]elouis|rhy[t]am'
ALLOW=(
  ':!LICENSE' ':!THIRD_PARTY_NOTICES.md'
  ':!docs/IP_MIGRATION.md' ':!docs/ARCHITECTURE_BASELINE.md' ':!docs/SECURITY_BASELINE.md'
  ':!docs/ROADMAP.md' ':!docs/PRODUCT_VISION.md' ':!docs/IDENTIFIERS.md' ':!docs/PHASE1_EXIT.md'
  ':!README.md' ':!CLAUDE.md' ':!CONTRIBUTING.md' ':!scripts/forbidden-content-check.sh'
)
fail=0

if hits=$(git grep -n -i -I -E "$PATTERN" -- . "${ALLOW[@]}"); then
  echo "Forbidden Coucou/Mochi/author identifiers found:"; echo "$hits"; fail=1
fi

# Protected asset file types must not be tracked (placeholder icons are generated PNGs under Assets.xcassets).
media=$(git ls-files | grep -iE '\.(wav|aiff?|caf|mp3|m4a|mp4|mov|gif|jpe?g|icns|ico|webp|p12|mobileprovision)$' || true)
png=$(git ls-files | grep -iE '\.png$' | grep -v '^Bipuu/Resources/Assets.xcassets/' || true)
if [ -n "$media$png" ]; then
  echo "Untracked-by-policy media files:"; echo "$media$png"; fail=1
fi

if [ "${1:-}" = "--history" ]; then
  bad=$(git rev-list --objects --all | awk 'NF>1{print $2}' \
        | grep -iE '\.(wav|aiff?|caf|mp3|m4a|mp4|mov|gif|jpe?g|icns|ico|webp|p12)$' || true)
  if [ -n "$bad" ]; then echo "Media files in history:"; echo "$bad"; fail=1; fi
fi

[ $fail -eq 0 ] && echo "forbidden-content check: clean"
exit $fail
