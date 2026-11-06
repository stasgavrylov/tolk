#!/bin/bash
# Exercises the real publisher against a local stand-in for the external GitHub CLI.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tolk-release-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PUBLISHER="$ROOT/scripts/publish-release.sh"
if [ ! -x "$PUBLISHER" ]; then
  echo "Missing executable release publisher: scripts/publish-release.sh" >&2
  exit 1
fi
mkdir "$WORK/bin" "$WORK/artifacts"
printf 'verified disk image\n' > "$WORK/artifacts/Tolk.dmg"
export GH_REPO=test-owner/test-repo GITHUB_REF_NAME=v1.0
export PATH="$WORK/bin:$PATH"

cat > "$WORK/bin/gh" <<'GH'
#!/bin/bash
set -euo pipefail
state=$(cat "$STATE_DIR/state")
case "$1 $2" in
  'api --paginate')
    [ "$3" = "repos/test-owner/test-repo/releases" ]
    [ ! -e "$STATE_DIR/fail-api" ] || exit 42
    printf 'v0.9\tfalse\n'
    case "$state" in
      draft) printf 'v1.0\ttrue\n' ;;
      public) printf 'v1.0\tfalse\n' ;;
      absent) ;;
      *) exit 1 ;;
    esac
    ;;
  'release create')
    [ "$3" = v1.0 ]
    [ "$state" = absent ] || { echo 'release already exists' >&2; exit 1; }
    case " $* " in
      *' --draft '*) printf draft > "$STATE_DIR/state" ;;
      *) printf public > "$STATE_DIR/state" ;;
    esac
    ;;
  'release upload')
    [ "$3" = v1.0 ]
    [ "$state" != absent ]
    shift 3
    clobber=false
    files=()
    for argument in "$@"; do
      case "$argument" in
        --clobber) clobber=true ;;
        Tolk.dmg|Tolk.dmg.sha256) files+=("$argument") ;;
        *) exit 1 ;;
      esac
    done
    for file in "${files[@]}"; do
      [ ! -e "$STATE_DIR/$file" ] || "$clobber"
      cp "$file" "$STATE_DIR/$file"
      # Failure after the first upload leaves an incomplete draft to recover.
      [ ! -e "$STATE_DIR/fail-upload" ] || exit 42
    done
    ;;
  'release edit')
    [ "$3" = v1.0 ]
    (cd "$STATE_DIR" && shasum -a 256 -c Tolk.dmg.sha256 >/dev/null)
    case " $* " in *' --draft=false '*) printf public > "$STATE_DIR/state" ;; esac
    case " $* " in *' --latest '*) printf v1.0 > "$STATE_DIR/latest" ;; esac
    ;;
  *) echo "Unexpected GitHub command: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$WORK/bin/gh"

new_case() {
  export STATE_DIR="$WORK/$1"
  mkdir "$STATE_DIR"
  printf '%s' "$2" > "$STATE_DIR/state"
}
expect_published() {
  [ "$(cat "$STATE_DIR/state")" = public ]
  [ "$(cat "$STATE_DIR/latest")" = v1.0 ]
  cmp "$WORK/artifacts/Tolk.dmg" "$STATE_DIR/Tolk.dmg"
  (cd "$STATE_DIR" && shasum -a 256 -c Tolk.dmg.sha256 >/dev/null)
}

new_case existing-draft draft
printf 'incomplete old upload\n' > "$STATE_DIR/Tolk.dmg"
"$PUBLISHER" "$WORK/artifacts"
expect_published
echo 'PASS: existing draft resumes and replaces incomplete draft assets'

new_case fresh absent
"$PUBLISHER" "$WORK/artifacts"
expect_published
echo 'PASS: new release publishes both verified assets and becomes latest'

new_case partial-upload absent
touch "$STATE_DIR/fail-upload"
if "$PUBLISHER" "$WORK/artifacts"; then exit 1; fi
[ "$(cat "$STATE_DIR/state")" = draft ]
[ ! -e "$STATE_DIR/latest" ]
rm "$STATE_DIR/fail-upload"
"$PUBLISHER" "$WORK/artifacts"
expect_published
echo 'PASS: partial upload stays unpublished and a retry recovers'

new_case api-failure absent
touch "$STATE_DIR/fail-api"
if "$PUBLISHER" "$WORK/artifacts"; then exit 1; fi
[ "$(cat "$STATE_DIR/state")" = absent ]
[ ! -e "$STATE_DIR/Tolk.dmg" ]
echo 'PASS: API failure is not mistaken for an absent release'

new_case already-public public
printf 'existing public download\n' > "$STATE_DIR/Tolk.dmg"
cp "$STATE_DIR/Tolk.dmg" "$STATE_DIR/original.dmg"
if "$PUBLISHER" "$WORK/artifacts"; then exit 1; fi
[ "$(cat "$STATE_DIR/state")" = public ]
cmp "$STATE_DIR/original.dmg" "$STATE_DIR/Tolk.dmg"
[ ! -e "$STATE_DIR/Tolk.dmg.sha256" ]
echo 'PASS: public release assets cannot be overwritten'
