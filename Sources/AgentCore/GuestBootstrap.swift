import Foundation

public enum GuestBootstrap {
    public static let sessionScript = #"""
#!/usr/bin/env bash
set -euo pipefail
umask 077

WORKER=${1:?worker required}
shift
[[ "$WORKER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid worker" >&2; exit 64; }
SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
EXPECTED_SEQ=""
EXPECTED_HEAD=""
REQUIRE_FULL=false
if [ "${1:-}" = --require-full ]; then REQUIRE_FULL=true; shift; fi
if [ "${1:-}" = --session ]; then
  [ "$#" -ge 5 ] || { echo "session, prior sequence and prior head required" >&2; exit 64; }
  SESSION_ID=$2
  EXPECTED_SEQ=$3
  EXPECTED_HEAD=$4
  shift 4
fi
[[ "$SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid session" >&2; exit 64; }
[ "$#" -gt 0 ] || { echo "agent guest supervisor: command required" >&2; exit 64; }

AUDIT_ROOT=/var/lib/agent-audit
DIR="$AUDIT_ROOT/sessions/$WORKER/$SESSION_ID"
mkdir -p "$AUDIT_ROOT/sessions/$WORKER"
mkdir "$DIR"
chmod 0700 "$AUDIT_ROOT" "$AUDIT_ROOT/sessions" "$AUDIT_ROOT/sessions/$WORKER" "$DIR"
REL="sessions/$WORKER/$SESSION_ID"

# Every launch is anchored before untrusted code can run. A torn write leaves
# evidence that verification rejects; it is never silently repaired or removed.
record() {
  local PHASE=$1 INPUT=$2 MANIFEST=$3 DIGEST=$4
  exec 9>"$AUDIT_ROOT/chain.lock"
  flock 9
  PREV=$(if [ -e "$AUDIT_ROOT/HEAD" ]; then cat "$AUDIT_ROOT/HEAD"; else printf '%064d' 0; fi)
  SEQ=$(if [ -e "$AUDIT_ROOT/sequence" ]; then cat "$AUDIT_ROOT/sequence"; else echo 0; fi)
  [[ "$PREV" =~ ^[0-9a-f]{64}$ && "$SEQ" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "malformed audit head" >&2; exit 2; }
  if [ "$PHASE" = start ] && [ -n "$EXPECTED_SEQ" ]; then
    [ "$SEQ" = "$EXPECTED_SEQ" ] && [ "$PREV" = "$EXPECTED_HEAD" ] || { echo "audit head changed before launch" >&2; exit 2; }
  fi
  SEQ=$((SEQ + 1))
  {
    printf 'sequence=%s\n' "$SEQ"
    printf 'previous=%s\n' "$PREV"
    printf 'worker=%s\n' "$WORKER"
    printf 'session=%s\n' "$SESSION_ID"
    printf 'phase=%s\n' "$PHASE"
    cat "$DIR/$MANIFEST"
  } > "$DIR/$INPUT"
  HEAD=$(sha256sum "$DIR/$INPUT" | awk '{print $1}')
  printf '%s\n' "$HEAD" > "$DIR/$DIGEST"
  printf '%s\t%s\t%s\t%s\n' "$SEQ" "$HEAD" "$REL" "$PHASE" >> "$AUDIT_ROOT/chain.log"
  printf '%s\n' "$HEAD" > "$AUDIT_ROOT/HEAD"
  printf '%s\n' "$SEQ" > "$AUDIT_ROOT/sequence"
  sync
  flock -u 9
  exec 9>&-
}

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

if $REQUIRE_FULL; then
  [ "$(cat "$DIR/isolation-mode")" = userns-root ] &&
  [ "$(cat "$DIR/audit-mode")" = full ] && command -v script >/dev/null 2>&1 || {
    echo "full audit unavailable; refusing fallback before vendor launch" >&2; exit 2;
  }
fi

(
  cd "$DIR"
  find . -type f ! -name start.manifest.sha256 -print0 | sort -z | xargs -0 sha256sum > start.manifest.sha256
)
record start start.input start.manifest.sha256 start.HEAD

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

record complete chain.input manifest.sha256 HEAD
exit "$RC"
"""#

    public static let verifyScript = #"""
#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT=/var/lib/agent-audit
ZERO=$(printf '%064d' 0)
fail() { echo "$*" >&2; exit 2; }
SNAPSHOT=false
REQUIRE_FULL=false
if [ "${1:-}" = --require-full ]; then REQUIRE_FULL=true; shift; fi
TARGET=""
if [ "${1:-}" = --snapshot ]; then
  [ "$#" -eq 1 ] || fail "invalid snapshot arguments"
  SNAPSHOT=true
elif [ "$#" -gt 0 ]; then
  [ "$#" -eq 5 ] && [ "$1" = --session ] || fail "invalid session arguments"
  [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$3" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid session identity"
  TARGET="sessions/$2/$3"
  PRIOR_SEQ=$4
  PRIOR_HEAD=$5
  [[ "$PRIOR_SEQ" =~ ^(0|[1-9][0-9]*)$ && "$PRIOR_HEAD" =~ ^[0-9a-f]{64}$ ]] || fail "invalid prior head"
fi
[ -d "$ROOT" ] || fail "no audit ledger"
exec 9>"$ROOT/chain.lock"
flock 9
shopt -s nullglob dotglob
STARTED=$'\n'
COMPLETED=$'\n'
PREV="$ZERO"
EXPECTED_SEQ=1
TARGET_START=false
TARGET_END=false

if [ -f "$ROOT/chain.log" ]; then
  # Preserve the old three-column completed entries. New entries bind their
  # phase into the digest and must transition exactly once from start to complete.
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    IFS=$'\t' read -r SEQ HEAD REL PHASE EXTRA <<< "$LINE"
    [[ "$HEAD" =~ ^[0-9a-f]{64}$ && "$REL" =~ ^sessions/[^/]+/[^/]+$ ]] || fail "malformed chain entry"
    # Legacy worker names were not restricted to the modern identifier grammar.
    # Accept a single safe path component, never traversal or extra components.
    LEGACY_WORKER=${REL#sessions/}; LEGACY_WORKER=${LEGACY_WORKER%%/*}
    LEGACY_SESSION=${REL##*/}
    case "$LEGACY_WORKER" in .|..) fail "unsafe legacy worker";; esac
    case "$LEGACY_SESSION" in .|..) fail "unsafe legacy session";; esac
    if [ -n "$PHASE" ]; then
      [[ "$REL" =~ ^sessions/[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid modern session identity"
    fi
    CANONICAL=$(printf '%s\t%s\t%s' "$SEQ" "$HEAD" "$REL")
    if [ -n "$PHASE" ]; then CANONICAL+=$(printf '\t%s' "$PHASE"); fi
    [ "$LINE" = "$CANONICAL" ] || fail "malformed chain columns"
    [ "$SEQ" = "$EXPECTED_SEQ" ] || fail "sequence break: expected $EXPECTED_SEQ got $SEQ"
    DIR="$ROOT/$REL"
    [ -d "$DIR" ] && [ ! -L "$DIR" ] || fail "missing session directory: $REL"
    WORKER=${REL#sessions/}
    WORKER=${WORKER%%/*}
    SESSION=${REL##*/}
    case "$COMPLETED" in *$'\n'"$REL"$'\n'*) fail "duplicate completed session: $REL";; esac
    case "$PHASE" in
      start)
        case "$STARTED" in *$'\n'"$REL"$'\n'*) fail "duplicate started session: $REL";; esac
        STARTED+="$REL"$'\n'
        INPUT=start.input; MANIFEST=start.manifest.sha256; DIGEST=start.HEAD
        if [ "$REL" = "$TARGET" ]; then
          [ "$SEQ" = "$((PRIOR_SEQ + 1))" ] && [ "$PREV" = "$PRIOR_HEAD" ] || fail "session start does not extend prior head"
          TARGET_START=true
        fi
        ;;
      complete|"")
        case "$STARTED" in
          *$'\n'"$REL"$'\n'*) [ "$PHASE" = complete ] || fail "legacy completion of new session";;
          *) [ -z "$PHASE" ] || fail "completion without start: $REL";;
        esac
        COMPLETED+="$REL"$'\n'
        INPUT=chain.input; MANIFEST=manifest.sha256; DIGEST=HEAD
        [ -s "$DIR/start" ] && [ -s "$DIR/end" ] && [ -s "$DIR/exit-code" ] || fail "incomplete session: $REL"
        if [ "$REL" = "$TARGET" ] && [ "$PHASE" = complete ]; then TARGET_END=true; fi
        ;;
      *) fail "invalid session phase";;
    esac
    [ -s "$DIR/$MANIFEST" ] || fail "missing session manifest: $REL"
    (cd "$DIR"; sha256sum -c "$MANIFEST" >/dev/null) || fail "session manifest verification failed: $REL"
    CALC=$({
      printf 'sequence=%s\n' "$SEQ"
      printf 'previous=%s\n' "$PREV"
      printf 'worker=%s\n' "$WORKER"
      printf 'session=%s\n' "$SESSION"
      if [ -n "$PHASE" ]; then printf 'phase=%s\n' "$PHASE"; fi
      cat "$DIR/$MANIFEST"
    } | sha256sum | awk '{print $1}')
    [ "$CALC" = "$HEAD" ] && [ "$(sha256sum "$DIR/$INPUT" | awk '{print $1}')" = "$HEAD" ] || fail "chain digest mismatch: $REL"
    [ "$(cat "$DIR/$DIGEST")" = "$HEAD" ] || fail "session HEAD mismatch: $REL"
    PREV="$HEAD"
    EXPECTED_SEQ=$((EXPECTED_SEQ + 1))
  done < "$ROOT/chain.log"
fi

# Reverse enumeration makes interrupted and unreferenced sessions visible even
# when chain.log still contains a valid older prefix. Never write in a session.
[ -d "$ROOT/sessions" ] || { [ "$EXPECTED_SEQ" = 1 ] || fail "missing sessions"; }
LINKS=$(find "$ROOT" -type l -print)
[ -z "$LINKS" ] || fail "symlink in audit ledger"
for WORKER_DIR in "$ROOT"/sessions/*; do
  [ -d "$WORKER_DIR" ] || fail "invalid worker directory"
  for DIR in "$WORKER_DIR"/*; do
    [ -d "$DIR" ] || fail "invalid session directory"
    REL=${DIR#"$ROOT/"}
    case "$COMPLETED" in *$'\n'"$REL"$'\n'*) ;; *) fail "incomplete or unreferenced session: $REL";; esac
  done
done

if [ "$EXPECTED_SEQ" = 1 ]; then
  $SNAPSHOT && [ ! -e "$ROOT/HEAD" ] && [ ! -e "$ROOT/sequence" ] && [ ! -e "$ROOT/chain.log" ] || fail "no completed audit sessions"
else
  [ "$(cat "$ROOT/HEAD")" = "$PREV" ] || fail "root HEAD mismatch"
  [ "$(cat "$ROOT/sequence")" = "$((EXPECTED_SEQ - 1))" ] || fail "root sequence mismatch"
fi
if [ -n "$TARGET" ]; then
  $TARGET_START && $TARGET_END || fail "requested session did not complete"
  if $REQUIRE_FULL; then
    [ "$(cat "$ROOT/$TARGET/isolation-mode")" = userns-root ] &&
    [ "$(cat "$ROOT/$TARGET/audit-mode")" = full ] || fail "requested full audit used fallback"
  fi
elif $REQUIRE_FULL; then
  fail "full audit verification requires a session"
fi
if $SNAPSHOT || [ -n "$TARGET" ]; then
  printf '%s %s\n' "$((EXPECTED_SEQ - 1))" "$PREV"
else
  printf '%s\n' "$PREV"
fi
"""#
}
