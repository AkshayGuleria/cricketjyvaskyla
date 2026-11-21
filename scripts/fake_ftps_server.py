"""Fake explicit-FTPS server for scripts/test-deploy-ftp.sh. Test use only.

Serves an in-memory filesystem over FTP with AUTH TLS on the control channel
and PROT P (TLS) on data channels, so the real deploy script can be run end
to end without touching the network.

Usage:
  python3 -I fake_ftps_server.py FLAGS CERTDIR STATEDIR PASSWORD

FLAGS is a comma-separated list ("ok" for none). It is written to
STATEDIR/flags and re-read on every command, so a test can change the
server's behaviour between runs by rewriting that file:
  notls           advertises AUTH TLS but refuses it
  noprot          accepts AUTH TLS but refuses PROT P (data would be cleartext)
  failstor=NAME   STOR of a file whose basename is NAME is refused up front
                  (553, like a permission or quota check); the file is untouched
  nochmod         refuses SITE CHMOD
  noutime         accepts SITE UTIME but ignores it (mtime stays upload time)
  clockahead=SECS the server's clock runs SECS seconds fast (upload times)
  protfirst       accepts PROT P on the first connection that asks for it,
                  refuses it on every later one
  slowstor=NAME   STOR of a file whose basename is NAME waits 30 s before
                  reading the data (to interrupt an upload mid-transfer)

Like real FTP servers, STOR truncates the target as soon as the upload
starts and writes data as it arrives, so an upload that fails or is cut off
part way leaves a partial file.

CERTDIR holds cert.pem / key.pem (the test chooses whether the client trusts
them). STATEDIR receives:
  port        the TCP port the server listens on (written once ready)
  log         one line per event: commands (PASS masked) with a tls= flag,
              and DATA lines describing each data connection
  fs.json     the filesystem, written after every change: {path: [size, mtime]}
              plus "dir" entries
STATEDIR/seed.json, if present at start, preloads files: {path: "content"}.
"""
import calendar
import json
import os
import posixpath
import socket
import ssl
import sys
import threading
import time
import traceback

INITIAL_FLAGS, CERTDIR, STATEDIR, PASSWORD = sys.argv[1:5]
KNOWN_FLAGS = {"ok", "notls", "noprot", "failstor", "nochmod", "noutime", "protfirst", "slowstor",
               "clockahead"}
LOCK = threading.Lock()
PROT_P_ACCEPTED = [0]  # connections that were granted PROT P (for protfirst)
FLAGS_FILE = os.path.join(STATEDIR, "flags")


def parse_flags(text):
    out = {}
    for item in text.strip().split(","):
        if item:
            name, _, value = item.partition("=")
            out[name] = value
    return out


def flag(name):
    """Value of flag NAME ("" if set without a value), or None if not set."""
    with open(FLAGS_FILE) as fh:
        return parse_flags(fh.read()).get(name)


unknown = set(parse_flags(INITIAL_FLAGS)) - KNOWN_FLAGS
if unknown:
    sys.exit("unknown flag(s): %s" % ", ".join(sorted(unknown)))
with open(FLAGS_FILE, "w") as fh:
    fh.write(INITIAL_FLAGS)
# path -> {"dir": True} | {"data": bytes, "mtime": float}
FS = {"/": {"dir": True}, "/www": {"dir": True}}

seed = os.path.join(STATEDIR, "seed.json")
if os.path.exists(seed):
    for p, content in json.load(open(seed)).items():
        parent = posixpath.dirname(p)
        while parent not in FS:
            FS[parent] = {"dir": True}
            parent = posixpath.dirname(parent)
        FS[p] = {"data": content.encode(), "mtime": time.time() - 3600}

LOG = open(os.path.join(STATEDIR, "log"), "a", buffering=1)


def log(line):
    with LOCK:
        LOG.write(line + "\n")


def dump_fs():
    out = {}
    for p, e in FS.items():
        out[p] = "dir" if e.get("dir") else [len(e["data"]), e["mtime"]]
    tmp = os.path.join(STATEDIR, "fs.json.tmp")
    json.dump(out, open(tmp, "w"), indent=1, sort_keys=True)
    os.replace(tmp, os.path.join(STATEDIR, "fs.json"))


CTX = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
CTX.load_cert_chain(os.path.join(CERTDIR, "cert.pem"), os.path.join(CERTDIR, "key.pem"))
# No TLS 1.3 session tickets: Python's server writes them lazily on the first
# read, which fails with EPIPE when lftp has already closed a short data
# connection, and breaks the session. Real FTPS servers do not have this issue.
CTX.num_tickets = 0


def server_now():
    return time.time() + float(flag("clockahead") or 0)


def mtime_str(t):
    return time.strftime("%Y%m%d%H%M%S", time.gmtime(t))


class Session:
    def __init__(self, sock):
        self.sock = sock
        self.tls = False
        self.prot = "C"
        self.cwd = "/"
        self.authed = False
        self.user = None
        self.pasv = None
        self.f = sock.makefile("rwb", buffering=0)

    def send(self, s):
        self.f.write((s + "\r\n").encode())

    def path(self, arg):
        return posixpath.normpath(posixpath.join(self.cwd, arg or "."))

    def open_data(self, what):
        if not self.pasv:
            self.send("425 Use PASV/EPSV first")
            return None
        self.send("150 Opening data connection")
        d, _ = self.pasv.accept()
        self.pasv.close()
        self.pasv = None
        if self.prot == "P":
            d = CTX.wrap_socket(d, server_side=True)
        log("DATA %s tls=%d" % (what, 1 if self.prot == "P" else 0))
        return d

    def close_data(self, d):
        try:
            if isinstance(d, ssl.SSLSocket):
                d = d.unwrap()
        except Exception:
            pass
        d.close()

    def listing(self, p):
        entries = []
        prefix = p.rstrip("/") + "/"
        for q, e in sorted(FS.items()):
            if q != p and q.startswith(prefix) and "/" not in q[len(prefix):]:
                name = q[len(prefix):]
                if e.get("dir"):
                    entries.append("type=dir;modify=%s; %s" % (mtime_str(time.time()), name))
                else:
                    entries.append("type=file;size=%d;modify=%s; %s"
                                   % (len(e["data"]), mtime_str(e["mtime"]), name))
        return entries

    def run(self):
        self.send("220 fake ftps")
        while True:
            line = self.f.readline()
            if not line:
                return
            cmd = line.decode(errors="replace").rstrip("\r\n")
            verb, _, arg = cmd.partition(" ")
            verb = verb.upper()
            shown = "PASS ***" if verb == "PASS" else cmd
            log("C: %s tls=%d" % (shown, 1 if self.tls else 0))
            if not self.handle(verb, arg):
                return

    def handle(self, verb, arg):
        if verb == "FEAT":
            self.f.write(b"211-Features:\r\n AUTH TLS\r\n PBSZ\r\n PROT\r\n EPSV\r\n PASV\r\n"
                         b" MLST type*;size*;modify*;\r\n SIZE\r\n MDTM\r\n UTF8\r\n211 End\r\n")
        elif verb == "AUTH":
            if flag("notls") is not None:
                self.send("534 TLS refused")
                return True
            self.send("234 Proceed with TLS")
            try:
                self.sock = CTX.wrap_socket(self.sock, server_side=True)
            except Exception as e:
                log("TLS handshake rejected by client: %s" % e)
                return False
            self.tls = True
            self.f = self.sock.makefile("rwb", buffering=0)
        elif verb == "PBSZ":
            self.send("200 PBSZ=0")
        elif verb == "PROT":
            with LOCK:
                later = flag("protfirst") is not None and PROT_P_ACCEPTED[0] > 0 and self.prot != "P"
            if arg.upper() == "P" and (flag("noprot") is not None or later):
                self.send("536 PROT P not supported")
            elif arg.upper() in ("P", "C"):
                if arg.upper() == "P" and self.prot != "P":
                    with LOCK:
                        PROT_P_ACCEPTED[0] += 1
                self.prot = arg.upper()
                self.send("200 PROT %s" % self.prot)
            else:
                self.send("504 bad PROT")
        elif verb == "USER":
            self.user = arg
            self.send("331 Password required")
        elif verb == "PASS":
            if arg == PASSWORD:
                self.authed = True
                self.send("230 Logged in")
            else:
                self.send("530 Login incorrect.")
        elif verb == "QUIT":
            self.send("221 Bye")
            return False
        elif verb in ("SYST",):
            self.send("215 UNIX Type: L8")
        elif verb in ("OPTS", "TYPE", "MODE", "STRU", "NOOP", "ALLO"):
            self.send("200 OK")
        elif not self.authed:
            self.send("530 Please login")
        elif verb == "PWD":
            self.send('257 "%s"' % self.cwd)
        elif verb == "CWD":
            p = self.path(arg)
            with LOCK:
                ok = FS.get(p, {}).get("dir")
            if ok:
                self.cwd = p
                self.send("250 OK")
            else:
                self.send("550 Can't change directory to %s: No such file or directory" % p)
        elif verb == "CDUP":
            self.cwd = posixpath.dirname(self.cwd) or "/"
            self.send("250 OK")
        elif verb in ("PASV", "EPSV"):
            self.pasv = socket.socket()
            self.pasv.bind(("127.0.0.1", 0))
            self.pasv.listen(1)
            port = self.pasv.getsockname()[1]
            if verb == "EPSV":
                self.send("229 Entering Extended Passive Mode (|||%d|)" % port)
            else:
                self.send("227 Entering Passive Mode (127,0,0,1,%d,%d)" % (port >> 8, port & 255))
        elif verb in ("MLSD", "LIST", "NLST"):
            p = self.path(arg if arg and not arg.startswith("-") else ".")
            with LOCK:
                exists = FS.get(p, {}).get("dir")
                entries = self.listing(p) if exists else []
            if not exists:
                self.send("550 No such directory")
                return True
            if verb == "NLST":
                entries = [e.split("; ", 1)[1] for e in entries]
            d = self.open_data(verb + " " + p)
            if d is None:
                return True
            d.sendall("".join(e + "\r\n" for e in entries).encode())
            self.close_data(d)
            self.send("226 Transfer complete")
        elif verb == "MLST":
            p = self.path(arg)
            with LOCK:
                e = FS.get(p)
            if not e:
                self.send("550 No such file")
            elif e.get("dir"):
                self.send("250-Listing\r\n type=dir; %s\r\n250 End" % p)
            else:
                self.send("250-Listing\r\n type=file;size=%d;modify=%s; %s\r\n250 End"
                          % (len(e["data"]), mtime_str(e["mtime"]), p))
        elif verb == "SIZE":
            with LOCK:
                e = FS.get(self.path(arg))
            if e and not e.get("dir"):
                self.send("213 %d" % len(e["data"]))
            else:
                self.send("550 No such file")
        elif verb == "MDTM":
            with LOCK:
                e = FS.get(self.path(arg))
            if e and not e.get("dir"):
                self.send("213 %s" % mtime_str(e["mtime"]))
            else:
                self.send("550 No such file")
        elif verb == "STOR":
            p = self.path(arg)
            if flag("failstor") == posixpath.basename(p):
                self.send("553 Simulated: upload refused")
                return True
            d = self.open_data("STOR " + p)
            if d is None:
                return True
            with LOCK:
                FS[p] = {"data": b"", "mtime": server_now()}
                dump_fs()
            if flag("slowstor") == posixpath.basename(p):
                time.sleep(30)
            while True:
                b = d.recv(65536)
                if not b:
                    break
                with LOCK:
                    FS[p]["data"] += b
            self.close_data(d)
            with LOCK:
                FS[p]["mtime"] = server_now()
                dump_fs()
            self.send("226 Transfer complete")
        elif verb == "DELE":
            p = self.path(arg)
            with LOCK:
                ok = p in FS and not FS[p].get("dir")
                if ok:
                    del FS[p]
                    dump_fs()
            self.send("250 Deleted" if ok else "550 No such file")
        elif verb == "MKD":
            p = self.path(arg)
            with LOCK:
                FS.setdefault(p, {"dir": True})
                dump_fs()
            self.send('257 "%s" created' % p)
        elif verb == "RMD":
            p = self.path(arg)
            with LOCK:
                ok = FS.get(p, {}).get("dir")
                if ok:
                    del FS[p]
                    dump_fs()
            self.send("250 Removed" if ok else "550 No such directory")
        elif verb == "SITE":
            parts = arg.split(" ", 2)
            if parts[0].upper() == "CHMOD" and flag("nochmod") is not None:
                self.send("550 SITE CHMOD not allowed")
                return True
            if parts[0].upper() == "UTIME" and len(parts) == 3 and flag("noutime") is None:
                # lftp: SITE UTIME YYYYMMDDHHMMSS path  (sets remote mtime, UTC)
                p = self.path(parts[2])
                t = calendar.timegm(time.strptime(parts[1], "%Y%m%d%H%M%S"))
                with LOCK:
                    if p in FS and not FS[p].get("dir"):
                        FS[p]["mtime"] = t
                        dump_fs()
            self.send("200 OK")
        else:
            self.send("502 Command not implemented")
        return True


def serve(conn):
    s = Session(conn)
    try:
        s.run()
    except Exception as e:
        log("session error: %r at %s" % (e, " <- ".join(
            "%s:%d" % (fr.name, fr.lineno) for fr in reversed(traceback.extract_tb(e.__traceback__)))))
    finally:
        try:
            s.sock.close()
        except Exception:
            pass


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
with LOCK:
    dump_fs()
with open(os.path.join(STATEDIR, "port.tmp"), "w") as fh:
    fh.write(str(srv.getsockname()[1]))
os.replace(os.path.join(STATEDIR, "port.tmp"), os.path.join(STATEDIR, "port"))
while True:
    c, _ = srv.accept()
    c.settimeout(20)
    threading.Thread(target=serve, args=(c,), daemon=True).start()
