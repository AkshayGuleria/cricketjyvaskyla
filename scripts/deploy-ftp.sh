#!/usr/bin/env bash
# Secure FTPS (explicit TLS) deploy of dist/ via lftp.
#
# Usage:
#   scripts/deploy-ftp.sh            # dry run (shows what would change)
#   scripts/deploy-ftp.sh --apply    # upload for real
#   scripts/deploy-ftp.sh --apply --delete   # also remove remote files not in dist/
#   scripts/deploy-ftp.sh --full ... # ignore the record of the last deploy and
#                                    # treat every file as changed
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
#   FTP_CA_FILE     optional CA bundle to verify the server against instead of
#                   the system's (used by the offline test). Certificate and
#                   hostname checks stay on either way.
#
# One-time Keychain setup. -T "" trusts no app, so every read must be approved
# in a macOS dialog (choose "Allow", never "Always Allow"):
#   security delete-generic-password -a "$FTP_USER" -s jcc-ftp 2>/dev/null
#   security add-generic-password -a "$FTP_USER" -s jcc-ftp -T "" -w
#
# Security model:
#   - TLS is mandatory (ftp:ssl-force): lftp aborts before sending the
#     password if the server will not negotiate TLS or its certificate/hostname
#     fails verification.
#   - lftp runs with --norc, so no rc file (~/.lftprc, ~/.config/lftp/rc,
#     $LFTP_HOME/rc, the system lftp.conf) can weaken these settings, e.g.
#     with a host-scoped "set ssl:verify-certificate/HOST no", which would
#     beat the plain "set ssl:verify-certificate yes" below.
#   - Data connections must be encrypted too. lftp silently falls back to
#     cleartext data if the server rejects PROT P, so a preflight session
#     (login only, no data connection) checks that PROT P was accepted before
#     anything is listed or uploaded, and the mirror session's own debug log
#     is checked the same way afterwards. That second check can only detect
#     a refusal after the fact: the run then fails and the record of the
#     deploy is not saved.
#   - Password reaches lftp only via LFTP_PASSWORD (open --env-password), so it
#     is not in argv, not in the lftp command text, and not in lftp's URLs.
#   - FTP_PASS is removed from the environment before `npm run build`.
#   - Any unrecognised lftp output is scrubbed of user:pass@ before printing.
#   Run scripts/test-deploy-ftp.sh after changing this script.
set -euo pipefail

cd "$(dirname "$0")/.."

HOST="${FTP_HOST:-ftps4.us.freehostia.com}"
USER_NAME="${FTP_USER:?Set FTP_USER (your FTP login)}"
REMOTE_DIR="${FTP_REMOTE_DIR:?Set FTP_REMOTE_DIR (e.g. /public_html)}"
CA_FILE="${FTP_CA_FILE:-}"
if [ -n "$CA_FILE" ]; then
  case "$CA_FILE" in *'"'*|*$'\n'*) echo "FTP_CA_FILE must not contain quotes or newlines" >&2; exit 2 ;; esac
  [ -f "$CA_FILE" ] && [ -r "$CA_FILE" ] || { echo "FTP_CA_FILE not readable: $CA_FILE" >&2; exit 2; }
fi

# Take the password out of the environment now, so the build's child
# processes (Astro, plugins, npm deps) never inherit it.
PASS="${FTP_PASS:-}"
unset FTP_PASS

APPLY=0
DELETE=0
FULL=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --delete) DELETE=1 ;;
    --full) FULL=1 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# --delete removes every remote file that is not in dist/. At the FTP root
# (or the login directory) that can include things outside the web site.
# The path is resolved lexically first ("", "." and ".." segments), so
# /www/.. or www/.. cannot slip past the check; "!" means it climbs above
# the root or login directory.
if [ "$DELETE" -eq 1 ]; then
  norm="$(printf '%s\n' "$REMOTE_DIR" | awk -F/ '{
    n = 0
    for (i = 1; i <= NF; i++) {
      if ($i == "" || $i == ".") continue
      if ($i == "..") { if (n == 0) { print "!"; exit } n--; continue }
      seg[++n] = $i
    }
    out = ""; for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") seg[i]
    print out
  }')"
  case "$norm" in
    ""|"!"|"~")
      echo "Refusing --delete with FTP_REMOTE_DIR=$REMOTE_DIR: once . and .. are resolved" >&2
      echo "that is (or is above) the FTP root or login directory, which may hold more" >&2
      echo "than the web site. Set FTP_REMOTE_DIR to the web root folder." >&2
      exit 2 ;;
  esac
fi

command -v lftp >/dev/null || { echo "lftp missing: brew install lftp" >&2; exit 1; }
command -v node >/dev/null || { echo "node missing" >&2; exit 1; }

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
# One private (0700) directory, removed on any exit including Ctrl-C. Named
# under $TMPDIR explicitly: macOS mktemp without a template ignores it.
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-ftp.XXXXXX")"
trap '[ -n "$TMP_DIR" ] && rm -rf -- "$TMP_DIR"' EXIT
BUILD_LOG="$TMP_DIR/build.log"
ACTIONS="$TMP_DIR/actions"
PRE_OUT="$TMP_DIR/preflight.out"
PRE_DEBUG="$TMP_DIR/preflight.debug"
MIRROR_DEBUG="$TMP_DIR/mirror.debug"
: >"$ACTIONS"

# Record of the last successful deploy to this host + directory (gitignored,
# lives under node_modules/.cache). See scripts/deploy-ftp-state.mjs.
STATE_FILE="node_modules/.cache/deploy-ftp/$(printf '%s' "$HOST$REMOTE_DIR" | tr -c 'A-Za-z0-9._-' '_').json"

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

# redact: strip credentials from any ftp(s)://user:pass@ URL in a line
redact() {
  printf '%s\n' "$1" | sed -E 's#(ftps?://[^/:@[:space:]]*):[^@[:space:]]*@#\1:***@#g'
}

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

# Give unchanged files back the mtime they had at the last deploy, so
# --only-newer uploads only what actually changed.
if [ "$FULL" -eq 1 ]; then
  echo "--full: treating every file as changed."
else
  node scripts/deploy-ftp-state.mjs restore dist "$STATE_FILE"
fi

# --- Password: env (captured above) -> Keychain -> hidden prompt -------------
if [ -z "$PASS" ] && command -v security >/dev/null; then
  PASS="$(security find-generic-password -a "$USER_NAME" -s jcc-ftp -w 2>/dev/null || true)"
fi
if [ -z "$PASS" ]; then
  read -r -s -p "FTP password for $USER_NAME@$HOST: " PASS
  echo
fi

# --- lftp environment -------------------------------------------------------
# The output parser below matches lftp's English messages, so force English
# messages without changing the character set used for file names.
LFTP_CTYPE="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"

# Settings shared by both lftp sessions. No secrets in here.
LFTP_SETTINGS="set cmd:fail-exit yes
set ftp:ssl-allow yes
set ftp:ssl-force yes
set ftp:ssl-auth TLS
set ftp:ssl-protect-data yes
set ftp:ssl-protect-list yes
set ssl:verify-certificate yes
set ssl:check-hostname yes
set ftp:sync-mode yes
set net:max-retries 2
set net:timeout 20"
[ -n "$CA_FILE" ] && LFTP_SETTINGS="$LFTP_SETTINGS
set ssl:ca-file \"$CA_FILE\""

# prot_ok DEBUG_LOG: succeed only if, in an lftp "debug 9" log, every control
# connection had PROT P accepted (2xx) before it sent any command that opens
# a data connection, and at least one PROT P was accepted. lftp pipelines
# commands, so replies are paired with commands in order (FIFO). The log has
# no connection ids, so this needs one control connection at a time (mirror
# runs with --parallel=1); overlapping connections fail the check. (A failed
# connect attempt, e.g. ::1 refused before 127.0.0.1 is tried, is logged as
# closed before the next one starts.)
prot_ok() {
  awk '
    function reset() { head = 1; tail = 0; ml = ""; prot_sent = 0 }
    function pop(code,   c) {
      if (head > tail) return
      c = q[head]; delete q[head]; head++
      if (c ~ /^PROT /) { if (code ~ /^2/) ok++; else bad = 1 }
    }
    BEGIN { reset() }
    /^---- Connecting to / { if (open) bad = 1; open = 1; reset(); next }
    /^---- Closing control socket/ { open = 0; next }
    /^---> / {
      c = substr($0, 6); q[++tail] = c
      if (c ~ /^PROT / && c != "PROT P") bad = 1
      if (c == "PROT P") prot_sent = 1
      if (c ~ /^(STOR|STOU|APPE|RETR|LIST|NLST|MLSD)( |$)/ && !prot_sent) bad = 1
      next
    }
    /^<--- / {
      r = substr($0, 6)
      if (ml != "") { if (substr(r, 1, 4) == ml " ") { ml = ""; pop(substr(r, 1, 3)) } next }
      if (r ~ /^[0-9][0-9][0-9]-/) { ml = substr(r, 1, 3); next }
      if (r ~ /^1[0-9][0-9]/) next
      if (r ~ /^[0-9][0-9][0-9]/) pop(substr(r, 1, 3))
    }
    END {
      for (i = head; i <= tail; i++) if (q[i] ~ /^PROT /) bad = 1
      exit (ok > 0 && !bad) ? 0 : 1
    }
  ' "$1"
}

# --- Preflight: login over TLS, check PROT P was accepted, check the dir -----
# lftp sends PROT P during login (protect-data and protect-list are both on),
# so this session never opens a data connection. The debug log masks the
# password ("PASS XXXX"); it is a private temp file removed on exit.
status "Checking TLS on $HOST..."
set +e
LC_ALL= LANGUAGE= LC_MESSAGES=C LC_CTYPE="$LFTP_CTYPE" LFTP_PASSWORD="$PASS" \
  lftp --norc >"$PRE_OUT" 2>&1 <<EOF
$LFTP_SETTINGS
debug -o "$PRE_DEBUG" 9
open --env-password -u "$USER_NAME" ftp://$HOST
cd "$REMOTE_DIR"
bye
EOF
PRE_RC=$?
set -e
endstatus
if [ "$PRE_RC" -ne 0 ]; then
  while IFS= read -r line; do redact "$line" >&2; done <"$PRE_OUT"
  echo "Could not log in over TLS or open $REMOTE_DIR (lftp exit $PRE_RC). Nothing was uploaded." >&2
  exit 1
fi
if ! prot_ok "$PRE_DEBUG"; then
  echo "The server did not accept PROT P, so data connections would not be encrypted." >&2
  echo "Refusing to list or upload anything. Nothing was uploaded." >&2
  exit 1
fi
echo "TLS OK: logged in over TLS, server accepted PROT P, $REMOTE_DIR exists."

# --overwrite: upload over the old copy instead of deleting it first (lftp's
#   default), so an upload the server refuses leaves the old file in place.
#   It does not make uploads atomic: servers truncate the file when the upload
#   starts, so a failure part way still leaves that one file incomplete.
# --no-perms: do not send SITE CHMOD; some hosts refuse it, and the host's
#   default permissions are what a static site needs.
# --parallel=1: one control connection, so prot_ok can pair replies with
#   commands in the debug log (it has no connection ids).
OPTS="--reverse --only-newer --overwrite --no-perms --parallel=1 --verbose"
[ "$DELETE" -eq 1 ] && OPTS="$OPTS --delete"
if [ "$APPLY" -eq 0 ]; then
  OPTS="$OPTS --dry-run"
  echo "DRY RUN (use --apply to upload)"
fi

# Before anything on the server changes, forget the recorded state of every
# file this build changed. A failed or interrupted upload can leave the server
# holding this build's version of such a file; the record must not then claim
# the previous version is there, or a later deploy of that version (a
# rollback) would skip it.
[ "$APPLY" -eq 1 ] && node scripts/deploy-ftp-state.mjs prune dist "$STATE_FILE"

# Never upload, overwrite or --delete these. .DS_Store is macOS litter; the
# rest are files the host or other tools manage in the web root (a glob
# without a slash matches at any depth, "x/" matches a directory).
EXCLUDES="--exclude-glob .DS_Store --exclude-glob .htaccess --exclude-glob .ftpquota"
EXCLUDES="$EXCLUDES --exclude-glob .well-known/ --exclude-glob cgi-bin/"

# --- Run lftp, parse its output into live status + action list --------------
# The password is handed over in LFTP_PASSWORD (read by open --env-password);
# it is never part of argv, the lftp script text, or the session URL.
# lftp verbose lines parsed (printed in both dry-run and apply mode):
#   Transferring file `X'      -> upload X
#   Overwriting old file `X'   -> X exists remotely and is replaced
#   Removing old file `X'      -> remove X (--delete)
#   Making directory `X'       -> mkdir X
#   Removing old directory `X' -> rmdir X
status "Comparing with $HOST..."
set +e
LC_ALL= LANGUAGE= LC_MESSAGES=C LC_CTYPE="$LFTP_CTYPE" LFTP_PASSWORD="$PASS" \
  lftp --norc <<EOF 2>&1 | while IFS= read -r line; do
$LFTP_SETTINGS
debug -o "$MIRROR_DEBUG" 9
open --env-password -u "$USER_NAME" ftp://$HOST
cd "$REMOTE_DIR"
mirror $OPTS $EXCLUDES dist/ .
bye
EOF
  case "$line" in
    "Transferring file \`"*)
      f="${line#*\`}"; f="${f%\'}"
      printf 'T\t%s\n' "$f" >>"$ACTIONS"
      status "$([ "$APPLY" -eq 1 ] && echo Uploading || echo Checking): $f" ;;
    "Overwriting old file \`"*)
      f="${line#*\`}"; f="${f%\'}"
      printf 'R\t%s\n' "$f" >>"$ACTIONS"
      status "Replacing: $f" ;;
    "Removing old file \`"*)
      f="${line#*\`}"; f="${f%\'}"
      printf 'R\t%s\n' "$f" >>"$ACTIONS"
      status "Deleting: $f" ;;
    "Making directory \`"*)
      f="${line#*\`}"; f="${f%\'}"
      printf 'M\t%s\n' "$f" >>"$ACTIONS"
      status "Creating dir: $f" ;;
    "Removing old directory \`"*)
      f="${line#*\`}"; f="${f%\'}"
      printf 'X\t%s\n' "$f" >>"$ACTIONS"
      status "Removing dir: $f" ;;
    # dry-run also echoes the underlying commands; the lines above cover them
    "get "*|"put "*|"rm "*|"rmdir "*|"mkdir "*|"chmod "*|"") ;;
    *)
      endstatus
      redact "$line" >&2 ;;
  esac
done
RC="${PIPESTATUS[0]}"
set -e
endstatus

# Did every connection of the mirror session keep its data connections
# encrypted? Only checked afterwards; see prot_ok.
PROT_OK=1
prot_ok "$MIRROR_DEBUG" || PROT_OK=0

# Remember what is now on the server, so the next deploy skips unchanged files.
# Only after a fully successful upload: after a failed or partial run, the
# files this build changed stay out of the record (see prune above), so they
# are compared again next time.
[ "$RC" -eq 0 ] && [ "$PROT_OK" -eq 1 ] && [ "$APPLY" -eq 1 ] &&
  node scripts/deploy-ftp-state.mjs save dist "$STATE_FILE"

# --- Summary ----------------------------------------------------------------
# A file with both R and T = updated (overwritten); T only = new;
# R only = deleted. After a failure it lists what was attempted.
if [ "$RC" -ne 0 ]; then
  [ "$APPLY" -eq 1 ] && VERB="Attempted before the failure" || VERB="Would change (incomplete)"
elif [ "$APPLY" -eq 1 ]; then
  VERB="Changed"
else
  VERB="Would change"
fi
awk -F'\t' -v verb="$VERB" -v failed="$([ "$RC" -ne 0 ] && echo 1 || echo 0)" '
  $1=="T" { t[$2]=1; order[++n]=$2 }
  $1=="R" { r[$2]=1; if (!($2 in seen)) { seen[$2]=1; rorder[++m]=$2 } }
  $1=="M" { dirs[++d]=$2 }
  $1=="X" { rdirs[++x]=$2 }
  END {
    for (i=1;i<=n;i++) { f=order[i]; if (f in r) upd[++u]=f; else new[++w]=f }
    for (i=1;i<=m;i++) { f=rorder[i]; if (!(f in t)) del[++k]=f }
    print ""
    print "== " verb ": " u+0 " updated, " w+0 " new, " k+0 " deleted, " d+0 " dirs created, " x+0 " dirs removed =="
    cap=100
    sec("Updated", upd, u, cap, "~")
    sec("New", new, w, cap, "+")
    sec("Deleted", del, k, cap, "-")
    sec("Dirs created", dirs, d, cap, "+")
    sec("Dirs removed", rdirs, x, cap, "-")
    if (u+w+k+d+x == 0 && !failed) print "Nothing to do: remote already up to date."
  }
  function sec(title, arr, cnt, cap, mark,   i) {
    if (cnt+0 == 0) return
    print title " (" cnt "):"
    for (i=1;i<=cnt && i<=cap;i++) print "  " mark " " arr[i]
    if (cnt > cap) print "  ... and " (cnt-cap) " more"
  }
' "$ACTIONS"

if [ "$PROT_OK" -eq 0 ]; then
  echo >&2
  echo "WARNING: the server did not accept PROT P on every connection (or the check" >&2
  echo "could not confirm it), so some listings or file transfers may NOT have been" >&2
  echo "encrypted and could have been read or altered in transit." >&2
  [ "$APPLY" -eq 1 ] && echo "The record of this deploy was not saved. Check the live site." >&2
  echo "Ask the host why PROT P was refused before deploying again." >&2
fi
if [ "$RC" -ne 0 ]; then
  echo >&2
  echo "lftp failed (exit $RC). Check output above." >&2
  if [ "$APPLY" -eq 1 ]; then
    echo "The server may be in a mixed state (some files from this build, some older):" >&2
    echo "re-run the same command, or use --full if that does not fix it." >&2
  fi
  exit "$RC"
fi

[ "$PROT_OK" -eq 0 ] && exit 1

[ "$APPLY" -eq 0 ] && echo && echo "Dry run only. Re-run with --apply to upload."
exit 0
