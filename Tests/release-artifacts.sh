#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TASK="$(mktemp -d)"
TASK="$(cd "$TASK" && pwd -P)"
trap 'rm -rf "$TASK"' EXIT
mkdir -p "$TASK/tools" "$TASK/output with spaces/Sim.app"
APP="$TASK/output with spaces/Sim.app"
printf 'keep-existing-archive\n' > "$TASK/output with spaces/Sim-notarize.zip"
cat > "$TASK/release.env" <<'ENV'
AGENT_SIGNING_IDENTITY='fixture identity'
AGENT_NOTARY_PROFILE='fixture profile'
ENV
cat > "$TASK/tools/uname" <<'TOOL'
#!/bin/bash
echo Darwin
TOOL
cat > "$TASK/tools/codesign" <<'TOOL'
#!/bin/bash
printf 'codesign\n' >> "$FIXTURE_LOG"
printf '%s\n' "$@" >> "$FIXTURE_LOG"
TOOL
cat > "$TASK/tools/ditto" <<'TOOL'
#!/bin/bash
printf 'ditto\n' >> "$FIXTURE_LOG"
printf '%s\n' "$@" >> "$FIXTURE_LOG"
last="${!#}"
printf 'fixture-zip\n' > "$last"
TOOL
cat > "$TASK/tools/xcrun" <<'TOOL'
#!/bin/bash
printf 'xcrun\n' >> "$FIXTURE_LOG"
printf '%s\n' "$@" >> "$FIXTURE_LOG"
if [ "$1" = notarytool ]; then
 [ -f "$3" ] || exit 2
 [ "${FIXTURE_NOTARY_FAILURE:-0}" = 0 ] || exit 3
fi
TOOL
cat > "$TASK/tools/spctl" <<'TOOL'
#!/bin/bash
printf 'spctl\n' >> "$FIXTURE_LOG"
printf '%s\n' "$@" >> "$FIXTURE_LOG"
TOOL
chmod +x "$TASK"/tools/*
export PATH="$TASK/tools:$PATH" AGENT_RELEASE_ENV="$TASK/release.env" FIXTURE_LOG="$TASK/calls"
"$ROOT/scripts/sign" "$APP"
"$ROOT/scripts/notarize" "$APP"
grep -Fx "$APP" "$FIXTURE_LOG" >/dev/null
if grep -F "$ROOT/release/Sim.app" "$FIXTURE_LOG"; then echo 'Wrong artifact selected' >&2; exit 1; fi
[ "$(cat "$TASK/output with spaces/Sim-notarize.zip")" = keep-existing-archive ]
[ -z "$(find "$TASK/output with spaces" -maxdepth 1 -name '.sim-notarize.*' -print)" ]
if FIXTURE_NOTARY_FAILURE=1 "$ROOT/scripts/notarize" "$APP"; then echo 'Failed notarization accepted' >&2; exit 1; fi
[ -z "$(find "$TASK/output with spaces" -maxdepth 1 -name '.sim-notarize.*' -print)" ]
for step in sign notarize install; do
 if "$ROOT/scripts/$step" "$TASK/missing.app"; then echo "Missing artifact accepted: $step" >&2; exit 1; fi
 if "$ROOT/scripts/$step" "$APP" extra; then echo "Extra argument accepted: $step" >&2; exit 1; fi
done
# Exercise the real release orchestration against disposable step implementations.
mkdir -p "$TASK/pipeline/scripts"
cp "$ROOT/scripts/release" "$TASK/pipeline/scripts/release"
cat > "$TASK/pipeline/scripts/build" <<'TOOL'
#!/bin/bash
set -euo pipefail
printf 'build\n' >> "$PIPELINE_LOG"
mkdir "$1"
mkdir "$1/Sim.app"
TOOL
cat > "$TASK/pipeline/scripts/sign" <<'TOOL'
#!/bin/bash
set -euo pipefail
step="$(basename "$0")"
[ "$1" = "$EXPECTED_APP" ] || exit 4
printf '%s\n' "$step" >> "$PIPELINE_LOG"
if [ "$step" = sign ] && [ "${PIPELINE_FAIL_SIGN:-0}" = 1 ]; then exit 5; fi
TOOL
cp "$TASK/pipeline/scripts/sign" "$TASK/pipeline/scripts/notarize"
cp "$TASK/pipeline/scripts/sign" "$TASK/pipeline/scripts/install"
chmod +x "$TASK"/pipeline/scripts/*
export PIPELINE_LOG="$TASK/pipeline.log" EXPECTED_APP="$TASK/selected output/Sim.app"
"$TASK/pipeline/scripts/release" "$TASK/selected output"
[ "$(cat "$PIPELINE_LOG")" = "$(printf 'build\nsign\nnotarize\ninstall')" ]
: > "$PIPELINE_LOG"
EXPECTED_APP="$TASK/failed output/Sim.app"
export EXPECTED_APP
if PIPELINE_FAIL_SIGN=1 "$TASK/pipeline/scripts/release" "$TASK/failed output"; then echo 'Release continued after failed signing' >&2; exit 1; fi
[ "$(cat "$PIPELINE_LOG")" = "$(printf 'build\nsign')" ]
printf 'PASS: selected release path, existing ZIP preservation, notarization failure cleanup and argument rejection (fixture tools only)\n'
