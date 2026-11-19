#!/usr/bin/env bash
# Secure FTPS (explicit TLS) deploy of dist/ via lftp.
#
# Usage:
#   scripts/deploy-ftp.sh            # dry run (shows what would change)
#   scripts/deploy-ftp.sh --apply    # upload for real
#   scripts/deploy-ftp.sh --apply --delete   # also remove remote files not in dist/
#
# Shows a single live-updating status line while running, then a summary of
# the files targeted for change. Asks for confirmation when not on master/main.
#
# Config (env vars, none are secrets except the password):
#   FTP_HOST        default: ftps4.us.freehostia.com
#   FTP_USER        REQUIRED, your FTP login (kept out of the repo on purpose)
#   FTP_REMOTE_DIR  REQUIRED, e.g. /public_html
#   FTP_PASS        optional; else read from macOS Keychain item "jcc-ftp",
#                   else prompted (hidden). Never put it in a file in the repo.
#
# One-time Keychain setup. -T "" trusts no app, so every read must be approved
# in a macOS dialog (choose "Allow", never "Always Allow"):
#   security delete-generic-password -a "$FTP_USER" -s jcc-ftp 2>/dev/null
#   security add-generic-password -a "$FTP_USER" -s jcc-ftp -T "" -w
#
# Security model:
#   - TLS is mandatory (ftp:ssl-force): lftp aborts before sending the
#     password if the server will not negotiate TLS or its certificate/hostname
#     fails verification. Run scripts/test-deploy-ftp.sh to check this.
#   - Password reaches lftp only via LFTP_PASSWORD (open --env-password), so it
#     is not in argv, not in the lftp command text, and not in lftp's URLs.
#   - FTP_PASS is removed from the environment before `npm run build`.
#   - Any unrecognised lftp output is scrubbed of user:pass@ before printing.
set -euo pipefail

cd "$(dirname "$0")/.."

HOST="${FTP_HOST:-ftps4.us.freehostia.com}"
USER_NAME="${FTP_USER:?Set FTP_USER (your FTP login)}"
REMOTE_DIR="${FTP_REMOTE_DIR:?Set FTP_REMOTE_DIR (e.g. /public_html)}"

# Take the password out of the environment now, so the build's child
# processes (Astro, plugins, npm deps) never inherit it.
PASS="${FTP_PASS:-}"
unset FTP_PASS

APPLY=0
DELETE=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --delete) DELETE=1 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

command -v lftp >/dev/null || { echo "lftp missing: brew install lftp" >&2; exit 1; }

# --- Branch guard -----------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [ "$BRANCH" != "master" ] && [ "$BRANCH" != "main" ]; then
  echo "WARNING: on branch '$BRANCH', not master/main."
  echo "         The deployed site will be built from this branch."
  ans=""
  read -r -p "Continue anyway? [y/N] " ans || true
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# --- Temp files -------------------------------------------------------------
BUILD_LOG="$(mktemp)"
ACTIONS="$(mktemp)"
trap 'rm -f "$BUILD_LOG" "$ACTIONS"' EXIT

# --- Live status line -------------------------------------------------------
if [ -t 1 ]; then
  TTY=1
  COLS="$(tput cols 2>/dev/null || echo 80)"
else
  TTY=0
  COLS=80
fi

# status "text": rewrite the current line (or plain line when not a TTY)
status() {
  if [ "$TTY" -eq 1 ]; then
    local s="$1"
    [ "${#s}" -ge "$COLS" ] && s="${s:0:$((COLS - 2))}…"
    printf '\r\033[K%s' "$s"
  else
    printf '%s\n' "$1"
  fi
}
# endstatus: clear the live line
endstatus() { [ "$TTY" -eq 1 ] && printf '\r\033[K' || true; }

# --- Build ------------------------------------------------------------------
status "Building site..."
if ! npm run build >"$BUILD_LOG" 2>&1; then
  endstatus
  echo "Build failed:" >&2
  tail -n 40 "$BUILD_LOG" >&2
  exit 1
fi
endstatus
echo "Build OK (branch: $BRANCH)"

[ -f dist/index.html ] || { echo "dist/index.html missing, aborting" >&2; exit 1; }

# --- Password: env (captured above) -> Keychain -> hidden prompt -------------
if [ -z "$PASS" ] && command -v security >/dev/null; then
  PASS="$(security find-generic-password -a "$USER_NAME" -s jcc-ftp -w 2>/dev/null || true)"
fi
if [ -z "$PASS" ]; then
  read -r -s -p "FTP password for $USER_NAME@$HOST: " PASS
  echo
fi

OPTS="--reverse --only-newer --parallel=2 --verbose"
[ "$DELETE" -eq 1 ] && OPTS="$OPTS --delete"
if [ "$APPLY" -eq 0 ]; then
  OPTS="$OPTS --dry-run"
  echo "DRY RUN (use --apply to upload)"
fi

# redact: strip credentials from any ftp(s)://user:pass@ URL in a line
redact() {
  printf '%s\n' "$1" | sed -E 's#(ftps?://[^/:@[:space:]]*):[^@[:space:]]*@#\1:***@#g'
}

# --- Run lftp, parse its output into live status + action list --------------
# The password is handed over in LFTP_PASSWORD (read by open --env-password);
# it is never part of argv, the lftp script text, or the session URL.
# `cd` before mirror forces login + TLS + path check up front, so a bad
# password or missing dir fails loudly instead of printing an empty plan.
# lftp verbose lines parsed:
#   Transferring file `X'      -> upload X
#   Removing old file `X'      -> remove X (before overwrite, or --delete)
#   Making directory `X'       -> mkdir X
#   Removing old directory `X' -> rmdir X
status "Connecting to $HOST..."
set +e
LFTP_PASSWORD="$PASS" lftp <<EOF 2>&1 | while IFS= read -r line; do
set cmd:fail-exit yes
set ftp:ssl-allow yes
set ftp:ssl-force yes
set ftp:ssl-auth TLS
set ftp:ssl-protect-data yes
set ftp:ssl-protect-list yes
set ssl:verify-certificate yes
set ssl:check-hostname yes
set ftp:sync-mode yes
set net:max-retries 2
set net:timeout 20
open --env-password -u "$USER_NAME" ftp://$HOST
cd "$REMOTE_DIR"
mirror $OPTS --exclude-glob .DS_Store dist/ .
bye
EOF
  case "$line" in
    "Transferring file \`"*)
      f="${line#*\`}"; f="${f%\'}"
      printf 'T\t%s\n' "$f" >>"$ACTIONS"
      status "$([ "$APPLY" -eq 1 ] && echo Uploading || echo Checking): $f" ;;
    "Removing old file \`"*)
      f="${line#*\`}"; f="${f%\'}"
      printf 'R\t%s\n' "$f" >>"$ACTIONS"
      status "Replacing: $f" ;;
    "Making directory \`"*)
      f="${line#*\`}"; f="${f%\'}"
      printf 'M\t%s\n' "$f" >>"$ACTIONS"
      status "Creating dir: $f" ;;
    "Removing old directory \`"*)
      f="${line#*\`}"; f="${f%\'}"
      printf 'X\t%s\n' "$f" >>"$ACTIONS"
      status "Removing dir: $f" ;;
    # dry-run echoes the underlying commands; ignore that noise
    "get "*|"put "*|"rm "*|"rmdir "*|"mkdir "*|"chmod "*|"") ;;
    *)
      endstatus
      redact "$line" >&2 ;;
  esac
done
RC="${PIPESTATUS[0]}"
set -e
endstatus

if [ "$RC" -ne 0 ]; then
  echo "lftp failed (exit $RC). Check output above." >&2
  exit "$RC"
fi

# --- Summary ----------------------------------------------------------------
# A file with both R and T = overwritten; T only = new; R only = deleted.
awk -F'\t' -v apply="$APPLY" '
  $1=="T" { t[$2]=1; order[++n]=$2 }
  $1=="R" { r[$2]=1; if (!($2 in seen)) { seen[$2]=1; rorder[++m]=$2 } }
  $1=="M" { dirs[++d]=$2 }
  $1=="X" { rdirs[++x]=$2 }
  END {
    for (i=1;i<=n;i++) { f=order[i]; if (f in r) upd[++u]=f; else new[++w]=f }
    for (i=1;i<=m;i++) { f=rorder[i]; if (!(f in t)) del[++k]=f }
    verb = apply ? "Changed" : "Would change"
    print ""
    print "== " verb ": " u+0 " updated, " w+0 " new, " k+0 " deleted, " d+0 " dirs created, " x+0 " dirs removed =="
    cap=100
    sec("Updated", upd, u, cap, "~")
    sec("New", new, w, cap, "+")
    sec("Deleted", del, k, cap, "-")
    sec("Dirs created", dirs, d, cap, "+")
    sec("Dirs removed", rdirs, x, cap, "-")
    if (u+w+k+d+x == 0) print "Nothing to do: remote already up to date."
  }
  function sec(title, arr, cnt, cap, mark,   i) {
    if (cnt+0 == 0) return
    print title " (" cnt "):"
    for (i=1;i<=cnt && i<=cap;i++) print "  " mark " " arr[i]
    if (cnt > cap) print "  ... and " (cnt-cap) " more"
  }
' "$ACTIONS"

[ "$APPLY" -eq 0 ] && echo && echo "Dry run only. Re-run with --apply to upload."
exit 0
