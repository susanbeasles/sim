import Foundation

public enum GuestBootstrap {
    public static let sessionScript = #"""
#!/usr/bin/env bash
set -euo pipefail

WORKER=${1:?worker required}
shift
[ "$#" -gt 0 ] || { echo "agent guest supervisor: command required" >&2; exit 64; }

AUDIT_ROOT=/var/lib/agent-audit
SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
DIR="$AUDIT_ROOT/sessions/$WORKER/$SESSION_ID"
mkdir -p "$DIR"
chmod 0700 "$AUDIT_ROOT" "$AUDIT_ROOT/sessions" "$AUDIT_ROOT/sessions/$WORKER" "$DIR" 2>/dev/null || true

printf '%s\n' "$(date -u +%FT%TZ)" > "$DIR/start"
printf '%q ' "$@" > "$DIR/command.shell"
printf '\n' >> "$DIR/command.shell"
printf '%s\n' "$PWD" > "$DIR/cwd"
if [ -d .git ]; then
  git ls-files -z -c -o --exclude-standard 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null > "$DIR/tree.before.sha256" || true
fi

AGENT_UID=$(id -u agent 2>/dev/null || echo 1000)
AGENT_GID=$(id -g agent 2>/dev/null || echo 1000)

quote() { printf '%q' "$1"; }
CMD=""
for arg in "$@"; do
  q=$(quote "$arg")
  CMD+="$q "
done

BASE=(/usr/bin/env HOME=/home/agent USER=agent LOGNAME=agent)
if command -v setpriv >/dev/null 2>&1 && command -v unshare >/dev/null 2>&1 && \
   setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --clear-groups \
     unshare --user --map-root-user --pid --fork --mount-proc -- true >/dev/null 2>&1; then
  BASE+=(setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --clear-groups unshare --user --map-root-user --pid --fork --mount-proc --)
  echo userns-root > "$DIR/isolation-mode"
else
  BASE+=(runuser -u agent --)
  echo agent-user > "$DIR/isolation-mode"
fi

TRACE_CMD=""
for arg in "${BASE[@]}"; do TRACE_CMD+="$(quote "$arg") "; done
TRACE_CMD+="$CMD"

if command -v strace >/dev/null 2>&1; then
  TRACE_CMD="strace -ff -ttt -T -yy -s 65535 -o $(quote "$DIR/trace") $TRACE_CMD"
  echo full > "$DIR/audit-mode"
else
  echo control-only-no-strace > "$DIR/audit-mode"
fi

# util-linux script records every byte entering/leaving the PTY. The child is the
# fake-root/user-namespace process; these files remain owned by real VM root.
set +e
if command -v script >/dev/null 2>&1; then
  script -q -f -e \
    --log-in "$DIR/pty.in" \
    --log-out "$DIR/pty.out" \
    --log-timing "$DIR/pty.timing" \
    -c "$TRACE_CMD"
  RC=$?
else
  bash -lc "$TRACE_CMD"
  RC=$?
fi
set -e

printf '%s\n' "$RC" > "$DIR/exit-code"
printf '%s\n' "$(date -u +%FT%TZ)" > "$DIR/end"
if [ -d .git ]; then
  git ls-files -z -c -o --exclude-standard 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null > "$DIR/tree.after.sha256" || true
fi

(
  cd "$DIR"
  find . -type f ! -name manifest.sha256 ! -name chain.input ! -name HEAD -print0 | sort -z | xargs -0 sha256sum > manifest.sha256
)

exec 9>"$AUDIT_ROOT/chain.lock"
flock 9
PREV=$(cat "$AUDIT_ROOT/HEAD" 2>/dev/null || printf '%064d' 0)
SEQ=$(( $(cat "$AUDIT_ROOT/sequence" 2>/dev/null || echo 0) + 1 ))
REL="sessions/$WORKER/$SESSION_ID"
{
  printf 'sequence=%s\n' "$SEQ"
  printf 'previous=%s\n' "$PREV"
  printf 'worker=%s\n' "$WORKER"
  printf 'session=%s\n' "$SESSION_ID"
  cat "$DIR/manifest.sha256"
} > "$DIR/chain.input"
HEAD=$(sha256sum "$DIR/chain.input" | awk '{print $1}')
printf '%s\n' "$HEAD" > "$DIR/HEAD"
printf '%s\n' "$HEAD" > "$AUDIT_ROOT/HEAD"
printf '%s\n' "$SEQ" > "$AUDIT_ROOT/sequence"
printf '%s\t%s\t%s\n' "$SEQ" "$HEAD" "$REL" >> "$AUDIT_ROOT/chain.log"
flock -u 9
chmod -R go-rwx "$AUDIT_ROOT" 2>/dev/null || true
exit "$RC"
"""#

    public static let verifyScript = #"""
#!/usr/bin/env bash
set -euo pipefail
ROOT=/var/lib/agent-audit
ZERO=$(printf '%064d' 0)
[ -d "$ROOT" ] || { echo "no audit ledger" >&2; exit 1; }
[ -f "$ROOT/chain.log" ] || { echo "no completed audit sessions" >&2; exit 1; }

PREV="$ZERO"
EXPECTED_SEQ=1
while IFS=$'\t' read -r SEQ HEAD REL; do
  [ "$SEQ" = "$EXPECTED_SEQ" ] || { echo "sequence break: expected $EXPECTED_SEQ got $SEQ" >&2; exit 2; }
  DIR="$ROOT/$REL"
  [ -d "$DIR" ] || { echo "missing session directory: $REL" >&2; exit 2; }
  (
    cd "$DIR"
    sha256sum -c manifest.sha256 >/dev/null
  ) || { echo "session manifest verification failed: $REL" >&2; exit 2; }
  WORKER=$(sed -n 's/^worker=//p' "$DIR/chain.input" | head -n1)
  SESSION=$(sed -n 's/^session=//p' "$DIR/chain.input" | head -n1)
  {
    printf 'sequence=%s\n' "$SEQ"
    printf 'previous=%s\n' "$PREV"
    printf 'worker=%s\n' "$WORKER"
    printf 'session=%s\n' "$SESSION"
    cat "$DIR/manifest.sha256"
  } > "$DIR/.verify.input.$$"
  CALC=$(sha256sum "$DIR/.verify.input.$$" | awk '{print $1}')
  rm -f "$DIR/.verify.input.$$"
  [ "$CALC" = "$HEAD" ] || { echo "chain digest mismatch: $REL" >&2; exit 2; }
  [ "$(cat "$DIR/HEAD")" = "$HEAD" ] || { echo "session HEAD mismatch: $REL" >&2; exit 2; }
  PREV="$HEAD"
  EXPECTED_SEQ=$((EXPECTED_SEQ + 1))
done < "$ROOT/chain.log"

[ "$(cat "$ROOT/HEAD")" = "$PREV" ] || { echo "root HEAD mismatch" >&2; exit 2; }
[ "$(cat "$ROOT/sequence")" = "$((EXPECTED_SEQ - 1))" ] || { echo "root sequence mismatch" >&2; exit 2; }
printf '%s\n' "$PREV"
"""#
}
