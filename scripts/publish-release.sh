#!/bin/bash
# Publish the tested disk image; retries may replace draft assets, never public ones.
set -euo pipefail
: "${GH_REPO:?Set GH_REPO to owner/repository}"
: "${GITHUB_REF_NAME:?Set GITHUB_REF_NAME to the version tag}"
cd "${1:?Usage: scripts/publish-release.sh <artifact-directory>}"
[ -s Tolk.dmg ]

# Listing succeeds with no matching release. Authentication/network errors must stop here.
releases=$(gh api --paginate "repos/$GH_REPO/releases" --jq '.[] | [.tag_name, (.draft | tostring)] | @tsv')
state=$(awk -F '\t' -v tag="$GITHUB_REF_NAME" '$1 == tag { print $2 }' <<< "$releases")
case "$state" in
  ''|true) ;;
  false)
    echo "Release $GITHUB_REF_NAME is already public; refusing to replace its assets. Use a new version tag." >&2
    exit 1
    ;;
  *) echo "Unexpected release state: $state" >&2; exit 1 ;;
esac

shasum -a 256 Tolk.dmg > Tolk.dmg.sha256
if [ -z "$state" ]; then
  gh release create "$GITHUB_REF_NAME" --verify-tag --draft \
    --title "Tolk ${GITHUB_REF_NAME#v}" \
    --notes $'Requires an Apple silicon Mac with macOS 26 or later. Open Tolk.dmg and drag Tolk to Applications.\n\nThis build is ad-hoc signed, not notarized. If macOS blocks it because the developer cannot be verified, only proceed if you trust this download. In System Settings, open Privacy & Security, click Open Anyway, then confirm Open.'
fi
gh release upload "$GITHUB_REF_NAME" Tolk.dmg Tolk.dmg.sha256 --clobber
gh release edit "$GITHUB_REF_NAME" --draft=false --latest
