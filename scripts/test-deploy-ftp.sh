#!/usr/bin/env bash
# Offline regression test for scripts/deploy-ftp.sh security guarantees.
# Runs the real deploy script against a local fake FTP server (no network,
# no real credentials) and asserts that the password is never sent or printed:
#
#   1. Server without TLS          -> script aborts, server never sees USER/PASS
#   2. Server with untrusted cert  -> script aborts, server never sees PASS
#      (lftp checks the cert right after the handshake, so USER may already
#      have gone out inside TLS; the username is not secret, the password is)
#
# Usage: scripts/test-deploy-ftp.sh      (needs python3, lftp, openssl, dist/)
set -uo pipefail

cd "$(dirname "$0")/.."

[ -f dist/index.html ] || { echo "Run 'npm run build' once first (dist/ missing)." >&2; exit 2; }
for bin in python3 lftp openssl; do
  command -v "$bin" >/dev/null || { echo "Missing: $bin" >&2; exit 2; }
done

WORK="$(mktemp -d)"
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_PW="TestOnly-Pw-9z7Q"   # fake value; must never show up anywhere

# Stub npm so the test does not rebuild the site.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/npm"
chmod +x "$WORK/bin/npm"

# Self-signed cert for test 2 (not trusted by the system CA store).
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=127.0.0.1" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

cat >"$WORK/fakeftp.py" <<'PY'
import socket, ssl, sys
mode, portfile, logfile, certdir = sys.argv[1:5]
log = open(logfile, "a", buffering=1)
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(4)
srv.settimeout(20)
open(portfile, "w").write(str(srv.getsockname()[1]))
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certdir + "/cert.pem", certdir + "/key.pem")
while True:
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        break
    conn.settimeout(10)
    f = conn.makefile("rwb", buffering=0)
    send = lambda s: f.write((s + "\r\n").encode())
    send("220 fake")
    try:
        while True:
            line = f.readline()
            if not line:
                break
            cmd = line.decode(errors="replace").strip()
            log.write("C: " + cmd + "\n")
            verb = cmd.split(" ")[0].upper()
            if verb == "FEAT":
                f.write(b"211-Features:\r\n AUTH TLS\r\n PBSZ\r\n PROT\r\n211 End\r\n")
            elif verb == "AUTH" and mode == "notls":
                send("534 TLS refused")
            elif verb == "AUTH" and mode == "selfsigned":
                send("234 go ahead")
                try:
                    conn = ctx.wrap_socket(conn, server_side=True)
                    f = conn.makefile("rwb", buffering=0)
                    send = lambda s: f.write((s + "\r\n").encode())
                    log.write("TLS handshake completed\n")
                except Exception as e:
                    log.write("TLS handshake rejected by client: %s\n" % e)
                    break
            elif verb == "USER":
                send("331 need password")
            elif verb == "PASS":
                send("530 login incorrect")
            elif verb == "QUIT":
                send("221 bye")
                break
            else:
                send("502 not implemented")
    except Exception:
        pass
    conn.close()
PY

FAILS=0
check() { # check "description" condition-exit-code
  if [ "$2" -eq 0 ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi
}

run_case() { # run_case mode title forbidden-commands-regex
  local mode="$1" title="$2" forbidden="$3"
  local portfile="$WORK/port.$mode" srvlog="$WORK/srv.$mode.log" out="$WORK/out.$mode.log"
  : >"$srvlog"
  python3 -I "$WORK/fakeftp.py" "$mode" "$portfile" "$srvlog" "$WORK" &
  SRV_PID=$!
  for _ in $(seq 50); do [ -s "$portfile" ] && break; sleep 0.1; done
  local port; port="$(cat "$portfile")"

  echo "== $title"
  # "y" answers the branch guard if not on master/main.
  echo y | PATH="$WORK/bin:$PATH" FTP_HOST="127.0.0.1:$port" FTP_USER=testuser \
    FTP_PASS="$FAKE_PW" FTP_REMOTE_DIR=/www scripts/deploy-ftp.sh >"$out" 2>&1
  local rc=$?
  kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

  [ "$rc" -ne 0 ];                                  check "deploy script exits non-zero (rc=$rc)" $?
  grep -q '^C: AUTH TLS' "$srvlog";                 check "client asked for TLS (AUTH TLS)" $?
  ! grep -qE "^C: ($forbidden)" "$srvlog";          check "server never received ${forbidden//|//}" $?
  ! grep -qF "$FAKE_PW" "$srvlog" "$out";           check "password not in server log or script output" $?
  if [ "$FAILS" -gt 0 ]; then
    echo "  --- server log:";  sed 's/^/    /' "$srvlog"
    echo "  --- script output:"; sed 's/^/    /' "$out"
  fi
}

run_case notls      "Server refuses TLS"                       'USER|PASS'
run_case selfsigned "Server presents an untrusted certificate" 'PASS'

echo
if [ "$FAILS" -eq 0 ]; then echo "All checks passed."; else echo "$FAILS check(s) FAILED."; exit 1; fi
