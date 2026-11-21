#!/usr/bin/env bash
# Offline end-to-end test for scripts/deploy-ftp.sh.
#
# Runs a copy of the real deploy script (in a throwaway fake repo with a small
# synthetic dist/) against scripts/fake_ftps_server.py: a local FTPS server
# with TLS on control and data channels, signed by a throwaway test CA. No
# network, no real credentials, the real dist/ is never touched.
#
# Refusal cases (nothing may be uploaded, the password must not be sent):
#   - server refuses TLS
#   - server certificate not trusted, even though the user's lftp rc file
#     turns certificate checks off for this host
#   - server rejects PROT P (data connections would be cleartext)
#   - wrong password
#   - --delete with FTP_REMOTE_DIR at the FTP root (/, //, /., ., /www/..,
#     www/.., /www/../..)
#   - server accepts PROT P on the first connection only (checked after the
#     upload: the run must fail and the deploy record must not be saved)
# Success cases (summary and server state must match):
#   - dry run, dry run --delete, apply, no-op re-run after a rebuild,
#     single changed file, German locale, --full
# Failure handling:
#   - an upload the server refuses leaves the old file on the server, and the
#     run prints what it attempted
#   - rolling back after a failed upload re-uploads the files that changed
#   - a server that refuses SITE CHMOD still gets the files
#   - a server that ignores SITE UTIME gets no needless re-uploads
#   - --delete leaves host-managed files (.htaccess, .well-known/, cgi-bin/,
#     .ftpquota) alone
#   - Ctrl-C during an upload: exit 130, no temp files left, and the deploy
#     record does not claim the new version
#
# Usage: scripts/test-deploy-ftp.sh      (needs python3, lftp, openssl, node)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
for bin in python3 lftp openssl node; do
  command -v "$bin" >/dev/null || { echo "Missing: $bin" >&2; exit 2; }
done

WORK="$(mktemp -d)"
SRV_PID=""
stop_server() {
  if [ -n "$SRV_PID" ]; then kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; fi
  SRV_PID=""
}
cleanup() {
  stop_server
  if [ -n "${KEEP_WORK:-}" ]; then echo "Test files kept in $WORK"; return; fi
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf -- "$WORK"
}
trap cleanup EXIT

FAKE_PW="TestOnly-Pw-9z7Q"   # fake value; must never show up in any output

# --- Test CA + server certificate for "localhost" ---------------------------
mkdir -p "$WORK/certs"
(
  cd "$WORK/certs" || exit 1
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=deploy-ftp test CA" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -keyout ca.key -out ca.pem
  openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout key.pem -out srv.csr
  printf 'subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' >ext.cnf
  openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 1 -extfile ext.cnf -out cert.pem
) >/dev/null 2>&1 || { echo "Could not create test certificates" >&2; exit 2; }

# lftp reads $LFTP_HOME/rc unless started with --norc. This one plays a
# user's own lftp config that turns certificate checks off for the host; the
# deploy script must ignore it. The test CA is trusted via FTP_CA_FILE.
mkdir -p "$WORK/lftp-home"
printf '%s\n' 'set ssl:verify-certificate/localhost no' 'set ssl:check-hostname/localhost no' \
  >"$WORK/lftp-home/rc"

# --- Fake repo: copy of the deploy script + synthetic dist/ -----------------
FAKE="$WORK/repo"
mkdir -p "$FAKE/scripts" "$FAKE/dist/css" "$FAKE/dist/images" "$FAKE/dist/pdfs" "$WORK/bin" "$WORK/tmp"
cp "$REPO/scripts/deploy-ftp.sh" "$REPO/scripts/deploy-ftp-state.mjs" "$FAKE/scripts/"
printf '<h1>JCC</h1>\n' >"$FAKE/dist/index.html"
printf 'body { color: navy; }\n' >"$FAKE/dist/css/site.css"
head -c 4096 /dev/urandom >"$FAKE/dist/images/logo.png"
head -c 8192 /dev/urandom >"$FAKE/dist/pdfs/agm.pdf"
printf 'Jyväskylä\n' >"$FAKE/dist/jyväskylä.txt"
find "$FAKE/dist" -type f -exec touch -t 202001010000 {} +
rebuild() { find "$FAKE/dist" -type f -exec touch {} +; }   # Astro rewrites every file

# Stub npm so "npm run build" is a no-op.
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/npm"
chmod +x "$WORK/bin/npm"

# --- Helpers ----------------------------------------------------------------
STATE=""; PORT=""; OUT=""; RC=0; RUN=0
FAILS=0; CASE_FAILS=0

start_server() { # start_server FLAGS [seed-json]; exits 2 if it does not start
  STATE="$(mktemp -d "$WORK/state.XXXX")"
  [ -n "${2:-}" ] && printf '%s' "$2" >"$STATE/seed.json"
  python3 -I "$REPO/scripts/fake_ftps_server.py" "$1" "$WORK/certs" "$STATE" "$FAKE_PW" \
    2>>"$STATE/stderr" &
  SRV_PID=$!
  for _ in $(seq 100); do
    [ -s "$STATE/port" ] && break
    kill -0 "$SRV_PID" 2>/dev/null || break
    sleep 0.05
  done
  if [ ! -s "$STATE/port" ]; then
    echo "Fake FTPS server ($1) did not start within 5 s:" >&2
    sed 's/^/  /' "$STATE/stderr" >&2
    stop_server
    exit 2
  fi
  PORT="$(cat "$STATE/port")"
}

# deploy [deploy-ftp.sh args...]; sets OUT (output file) and RC.
# T_PASS / T_LC_ALL / T_LANG override the password and locale for one run;
# T_UNTRUSTED=1 leaves the test CA out (server certificate not trusted);
# T_DIR overrides FTP_REMOTE_DIR (default /www).
deploy() {
  RUN=$((RUN + 1)); OUT="$WORK/out.$RUN"
  local ca="$WORK/certs/ca.pem"
  [ "${T_UNTRUSTED:-}" = 1 ] && ca=""
  # "y" answers the branch guard (the fake repo is not a git checkout).
  echo y | PATH="$WORK/bin:$PATH" TMPDIR="$WORK/tmp" LFTP_HOME="$WORK/lftp-home" FTP_CA_FILE="$ca" \
    FTP_HOST="localhost:$PORT" FTP_USER=tester \
    FTP_PASS="${T_PASS:-$FAKE_PW}" FTP_REMOTE_DIR="${T_DIR:-/www}" LC_ALL="${T_LC_ALL:-}" LANG="${T_LANG:-${LANG:-}}" \
    "$FAKE/scripts/deploy-ftp.sh" "$@" >"$OUT" 2>&1
  RC=$?
}

begin() { echo "== $1"; CASE_FAILS=0; }
check() { # check "description" command...
  local desc="$1"; shift
  if "$@"; then echo "  PASS  $desc"; else echo "  FAIL  $desc"; FAILS=$((FAILS + 1)); CASE_FAILS=$((CASE_FAILS + 1)); fi
}
end() {
  if [ "$CASE_FAILS" -gt 0 ]; then
    echo "  --- server log (last 40 lines):"; tail -n 40 "$STATE/log" | sed "s/^/    /"
    echo "  --- script output:"; sed 's/^/    /' "$OUT"
  fi
}

failed()       { [ "$RC" -ne 0 ]; }
succeeded()    { [ "$RC" -eq 0 ]; }
out_has()      { grep -qF -- "$1" "$OUT"; }
out_lacks()    { ! grep -qF -- "$1" "$OUT"; }
log_has()      { grep -qE -- "$1" "$STATE/log"; }
log_lacks()    { ! grep -qE -- "$1" "$STATE/log"; }
pw_hidden()    { ! grep -qF -- "$FAKE_PW" "$OUT" "$STATE/log"; }
stor_count()   { grep -c '^C: STOR ' "$STATE/log"; }
# Only FEAT and AUTH TLS may happen before TLS; every data connection is TLS.
all_encrypted() {
  ! grep -E '^C: ' "$STATE/log" | grep ' tls=0$' | grep -qvE '^C: (FEAT|AUTH TLS) ' &&
    ! grep -qE '^DATA .* tls=0$' "$STATE/log"
}
remote_has() { python3 -I -c 'import json,sys; fs=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in fs else 1)' "$STATE/fs.json" "$1"; }
remote_lacks() { ! remote_has "$1"; }
# remote_size PATH: size in bytes of a file on the fake server, -1 if absent
remote_size() { python3 -I -c 'import json,sys; e=json.load(open(sys.argv[1])).get(sys.argv[2]); print(e[0] if isinstance(e, list) else -1)' "$STATE/fs.json" "$1"; }
local_size() { wc -c <"$FAKE/dist/$1" | tr -d ' '; }
# server_flags FLAGS: change the running fake server's behaviour (see its docstring)
server_flags() { printf '%s' "$1" >"$STATE/flags"; }
# The deploy script's record of the last deploy to the current fake server.
record_file() { echo "$FAKE/node_modules/.cache/deploy-ftp/localhost_${PORT}_www.json"; }
# record_lacks_current FILE: the record does not hold dist/FILE's current hash
record_lacks_current() { ! grep -qF "$(shasum -a 256 "$FAKE/dist/$1" | cut -d' ' -f1)" "$(record_file)"; }

# --- Harness self-check -----------------------------------------------------
begin "Harness: a fake server that cannot start is reported"
( start_server no-such-flag ) >"$WORK/harness.out" 2>&1
hrc=$?
check "start_server exits 2 (rc=$hrc)"          [ "$hrc" -eq 2 ]
check "says the server did not start"           grep -qF 'did not start' "$WORK/harness.out"
check "shows the server's error"                grep -qF 'unknown flag' "$WORK/harness.out"
end

# --- Refusal cases ----------------------------------------------------------
begin "Server refuses TLS"
start_server notls; deploy; stop_server
check "deploy fails (rc=$RC)"                   failed
check "client asked for TLS"                    log_has '^C: AUTH TLS'
check "server never received USER or PASS"      log_lacks '^C: (USER|PASS) '
check "nothing uploaded"                        log_lacks '^C: STOR '
check "password not in any output"              pw_hidden
end

begin "Server certificate not trusted (user rc says: don't check)"
start_server ok; T_UNTRUSTED=1 deploy; stop_server
check "deploy fails (rc=$RC)"                   failed
check "lftp rejected the certificate"           out_has 'Certificate verification'
check "server never received PASS"              log_lacks '^C: PASS '
check "nothing uploaded"                        log_lacks '^C: STOR '
check "password not in any output"              pw_hidden
end

begin "Server rejects PROT P (cleartext data)"
start_server noprot; deploy --apply; stop_server
check "deploy fails (rc=$RC)"                   failed
check "script explains the PROT P refusal"      out_has 'did not accept PROT P'
check "no data connection was opened"           log_lacks '^DATA '
check "nothing uploaded"                        log_lacks '^C: STOR '
check "password not in any output"              pw_hidden
end

begin "Server accepts PROT P on the first connection only"
start_server protfirst; deploy --apply; stop_server
check "preflight connection got PROT P"         out_has 'TLS OK'
check "a later data connection was cleartext"   log_has '^DATA .* tls=0$'
check "deploy fails (rc=$RC)"                   failed
check "script reports the unencrypted transfer" out_has 'may NOT have been'
check "deploy record not saved"                 [ ! -e "$(record_file)" ]
check "password not in any output"              pw_hidden
end

begin "Wrong password"
start_server ok; T_PASS="wrong-password" deploy --apply; stop_server
check "deploy fails (rc=$RC)"                   failed
check "script reports the login failure"        out_has 'Could not log in'
check "nothing uploaded"                        log_lacks '^C: STOR '
end

begin "--delete refused at the FTP root"
start_server ok
for d in / // /. . /www/.. www/.. /www/../..; do
  T_DIR="$d" deploy --apply --delete
  check "FTP_REMOTE_DIR=$d refused (rc=$RC)"      failed
  check "FTP_REMOTE_DIR=$d: reason given"         out_has 'Refusing --delete'
done
check "server never received USER"              log_lacks '^C: USER '
stop_server
end

# --- Success cases (one server, state carries over) -------------------------
# Host-managed files, which the site does not contain and --delete must keep.
HOST_FILES="/www/.htaccess /www/images/.htaccess /www/.ftpquota /www/.well-known/acme-challenge/t1 /www/cgi-bin/form.cgi"
start_server ok "$(printf '{"/www/stale.html": "left over from an old upload"'
  for f in $HOST_FILES; do printf ', "%s": "host file"' "$f"; done; printf '}')"

begin "Dry run on a fresh remote"
deploy
check "deploy succeeds (rc=$RC)"                succeeded
check "TLS preflight passed"                    out_has 'TLS OK'
check "summary: 5 new, 2 dirs (images/ exists)" out_has 'Would change: 0 updated, 5 new, 0 deleted, 2 dirs created'
check "summary lists the UTF-8 file name"       out_has '+ jyväskylä.txt'
check "nothing uploaded"                        log_lacks '^C: STOR '
check "everything after AUTH was encrypted"     all_encrypted
check "password not in any output"              pw_hidden
end

begin "Dry run --delete"
deploy --delete
check "deploy succeeds (rc=$RC)"                succeeded
check "summary: 1 deleted"                      out_has 'Would change: 0 updated, 5 new, 1 deleted'
check "summary lists stale.html"                out_has '- stale.html'
check "stale.html still on the server"          remote_has /www/stale.html
check "host-managed files not listed"           out_lacks 'htaccess'
end

begin "Apply"
deploy --apply
check "deploy succeeds (rc=$RC)"                succeeded
check "summary: 5 new"                          out_has 'Changed: 0 updated, 5 new, 0 deleted, 2 dirs created'
check "index.html on the server"                remote_has /www/index.html
check "nested file on the server"               remote_has /www/pdfs/agm.pdf
check "UTF-8 file name on the server"           remote_has '/www/jyväskylä.txt'
check "stale.html kept (no --delete)"           remote_has /www/stale.html
check "every login and transfer encrypted"      all_encrypted
check "password not in any output"              pw_hidden
end

begin "Rebuild with no content change"
rebuild; before="$(stor_count)"
deploy --apply
check "deploy succeeds (rc=$RC)"                succeeded
check "summary: nothing to do"                  out_has 'Nothing to do'
check "no file re-uploaded"                     [ "$(stor_count)" -eq "$before" ]
end

begin "One file changed"
rebuild; printf '<h1>JCC</h1><p>New season</p>\n' >"$FAKE/dist/index.html"
deploy
check "deploy succeeds (rc=$RC)"                succeeded
check "summary: 1 updated, 0 new"               out_has 'Would change: 1 updated, 0 new, 0 deleted'
check "summary lists index.html as updated"     out_has '~ index.html'
end

DE_LOCALE="$(locale -a 2>/dev/null | grep -iE '^de_DE\.utf-?8$' | head -n 1)"
if [ -n "$DE_LOCALE" ]; then
  begin "German locale ($DE_LOCALE)"
  T_LC_ALL="$DE_LOCALE" T_LANG="$DE_LOCALE" deploy
  check "deploy succeeds (rc=$RC)"              succeeded
  check "summary still parsed: 1 updated"       out_has 'Would change: 1 updated, 0 new, 0 deleted'
  end
else
  echo "== German locale: SKIPPED (de_DE.UTF-8 not installed)"
fi

begin "--full treats every file as changed"
rebuild
deploy --full
check "deploy succeeds (rc=$RC)"                succeeded
check "summary: 5 updated"                      out_has 'Would change: 5 updated, 0 new, 0 deleted'
end

# Build "B": dist/index.html is still the "New season" version from above,
# and site.css changes too. The server refuses the index.html upload (as for
# a permission or quota error), site.css succeeds.
begin "Upload refused: the live file is kept"
old_index="$(remote_size /www/index.html)"
printf 'body { color: maroon; }\n' >"$FAKE/dist/css/site.css"
server_flags failstor=index.html
deploy --apply
server_flags ok
check "deploy fails (rc=$RC)"                   failed
check "old index.html still on the server"      [ "$(remote_size /www/index.html)" = "$old_index" ]
check "new site.css reached the server"         [ "$(remote_size /www/css/site.css)" = "$(local_size css/site.css)" ]
check "summary of what was attempted"           out_has '~ css/site.css'
check "warns about a mixed state"               out_has 'mixed state'
end

# Roll back to build "A" (what the last successful deploy uploaded).
begin "Rollback after the failed upload"
printf '<h1>JCC</h1>\n' >"$FAKE/dist/index.html"
printf 'body { color: navy; }\n' >"$FAKE/dist/css/site.css"
rebuild
deploy --apply
check "deploy succeeds (rc=$RC)"                succeeded
check "summary lists site.css as updated"       out_has '~ css/site.css'
check "only the 2 files build B touched resent" out_has 'Changed: 2 updated, 0 new, 0 deleted'
check "old site.css back on the server"         [ "$(remote_size /www/css/site.css)" = "$(local_size css/site.css)" ]
end

begin "Server refuses SITE CHMOD"
printf '<h1>JCC</h1><p>Fixtures</p>\n' >"$FAKE/dist/index.html"
server_flags nochmod
deploy --apply
server_flags ok
check "deploy succeeds (rc=$RC)"                succeeded
check "summary: 1 updated"                      out_has 'Changed: 1 updated, 0 new, 0 deleted'
check "new index.html on the server"            [ "$(remote_size /www/index.html)" = "$(local_size index.html)" ]
end

# The remote mtime is then the upload time, not the local file's mtime.
begin "Server ignores SITE UTIME"
server_flags noutime
printf 'body { color: teal; }\n' >"$FAKE/dist/css/site.css"
deploy --apply
first_rc=$RC
rebuild; before="$(stor_count)"
deploy --apply
server_flags ok
check "first deploy succeeds (rc=$first_rc)"    [ "$first_rc" -eq 0 ]
check "rebuild deploy succeeds (rc=$RC)"        succeeded
check "summary: nothing to do"                  out_has 'Nothing to do'
check "no file re-uploaded"                     [ "$(stor_count)" -eq "$before" ]
end

begin "Apply --delete keeps host-managed files"
deploy --apply --delete
check "deploy succeeds (rc=$RC)"                succeeded
check "summary: 1 deleted"                      out_has 'Changed: 0 updated, 0 new, 1 deleted, 0 dirs created, 0 dirs removed'
check "stale.html deleted"                      remote_lacks /www/stale.html
for f in $HOST_FILES; do
  check "$f kept"                               remote_has "$f"
done
end

# Like pressing Ctrl-C in a terminal: SIGINT to the deploy's whole process
# group while the server is stalling on an upload. set -m gives the
# background job its own process group (and leaves SIGINT not ignored).
begin "Ctrl-C during an upload"
head -c 9000 /dev/urandom >"$FAKE/dist/pdfs/agm.pdf"
server_flags slowstor=agm.pdf
RUN=$((RUN + 1)); OUT="$WORK/out.$RUN"; mkdir -p "$WORK/tmp-int"
log_lines="$(wc -l <"$STATE/log")"
new_log_has() { tail -n "+$((log_lines + 1))" "$STATE/log" | grep -qE -- "$1"; }
set -m
PATH="$WORK/bin:$PATH" TMPDIR="$WORK/tmp-int" LFTP_HOME="$WORK/lftp-home" FTP_CA_FILE="$WORK/certs/ca.pem" \
  FTP_HOST="localhost:$PORT" FTP_USER=tester FTP_PASS="$FAKE_PW" FTP_REMOTE_DIR=/www \
  "$FAKE/scripts/deploy-ftp.sh" --apply <<<y >"$OUT" 2>&1 &
pid=$!
set +m
for _ in $(seq 200); do new_log_has '^DATA STOR /www/pdfs/agm.pdf' && break; sleep 0.05; done
stalled=0; new_log_has '^DATA STOR /www/pdfs/agm.pdf' && stalled=1
kill -INT -- "-$pid" 2>/dev/null
wait "$pid"; RC=$?
server_flags ok
check "upload of agm.pdf was in progress"       [ "$stalled" -eq 1 ]
check "deploy exits 130 (rc=$RC)"               [ "$RC" -eq 130 ]
check "no temp files left"                      [ -z "$(ls -A "$WORK/tmp-int")" ]
check "record does not claim the new agm.pdf"   record_lacks_current pdfs/agm.pdf
end

begin "Every run cleaned up its temp files"
check "no temp files left by any run"           [ -z "$(ls -A "$WORK/tmp")" ]
end

stop_server
echo
if [ "$FAILS" -eq 0 ]; then echo "All checks passed."; else echo "$FAILS check(s) FAILED."; exit 1; fi
