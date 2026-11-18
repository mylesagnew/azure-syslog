#!/usr/bin/env python3
"""Archive rotated remote syslog files to Azure Blob Storage, then prune local copies.

Runs hourly from systemd (syslog-archive.timer) as root.

* Finds rotated, compressed files under the remote log root (<root>/<sender>/*.gz).
* Uploads each one with the VM's managed identity (no keys) to
  <container>/<collector>/<sender>/<file>, Cool tier, with Content-MD5 so the
  service verifies integrity. Existing blobs are never overwritten.
* Deletes a local file only when it is older than local_days AND the blob is
  confirmed (same MD5). Files that never uploaded are kept and reported.

Configuration: /etc/syslog-archive.json (written by Ansible). Python stdlib only.
"""
import argparse
import base64
import email.utils
import hashlib
import http.client
import json
import os
import socket
import sys
import time
import urllib.parse
import urllib.request

API_VERSION = "2023-11-03"
IMDS = ("http://169.254.169.254/metadata/identity/oauth2/token"
        "?api-version=2018-02-01&resource=" + urllib.parse.quote("https://storage.azure.com/", safe=""))
MAX_SINGLE_PUT = 5000 * 1024 * 1024  # Put Blob limit


def log(level, msg):
    # journald -> rsyslog local ruleset -> AMA, so failures reach Log Analytics.
    print(f"<{ {'err': 3, 'warn': 4, 'info': 6}[level] }>{msg}", flush=True)


class Token:
    def __init__(self):
        self._value, self._expires = None, 0

    def get(self):
        if self._value and time.time() < self._expires - 300:
            return self._value
        req = urllib.request.Request(IMDS, headers={"Metadata": "true"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.load(resp)
        self._value, self._expires = data["access_token"], int(data["expires_on"])
        return self._value


def md5_b64(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return base64.b64encode(h.digest()).decode()


class Blob:
    def __init__(self, cfg, token):
        self.host = f"{cfg['account']}.{cfg['endpoint_suffix']}"
        self.container = cfg["container"]
        self.tier = cfg.get("tier", "Cool")
        self.token = token

    def _path(self, name):
        return "/" + urllib.parse.quote(self.container) + "/" + "/".join(
            urllib.parse.quote(p, safe="") for p in name.split("/"))

    def _headers(self, extra=None):
        h = {
            "Authorization": f"Bearer {self.token.get()}",
            "x-ms-version": API_VERSION,
            "x-ms-date": email.utils.formatdate(usegmt=True),
        }
        h.update(extra or {})
        return h

    def _request(self, method, name, headers, body=None):
        conn = http.client.HTTPSConnection(self.host, timeout=300)
        try:
            conn.request(method, self._path(name), body=body, headers=headers)
            resp = conn.getresponse()
            return resp.status, dict(resp.getheaders()), resp.read()
        finally:
            conn.close()

    def remote_md5(self, name):
        status, headers, _ = self._request("HEAD", name, self._headers())
        if status == 200:
            return {k.lower(): v for k, v in headers.items()}.get("content-md5")
        if status == 404:
            return None
        raise RuntimeError(f"HEAD {name}: HTTP {status}")

    def upload(self, path, name, md5):
        size = os.path.getsize(path)
        headers = self._headers({
            "x-ms-blob-type": "BlockBlob",
            "x-ms-access-tier": self.tier,
            "x-ms-blob-content-type": "application/gzip",
            "x-ms-meta-collector": socket.gethostname(),
            "Content-MD5": md5,
            "Content-Length": str(size),
            "If-None-Match": "*",  # never overwrite
        })
        with open(path, "rb") as fh:
            status, _, body = self._request("PUT", name, headers, body=fh)
        if status == 201:
            return "uploaded"
        if status == 409 and b"BlobAlreadyExists" in body:
            return "exists"
        raise RuntimeError(f"PUT {name}: HTTP {status} {body[:300]!r}")


def load_state(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError):
        return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=1, sort_keys=True)
    os.replace(tmp, path)


def candidates(root):
    for sender in sorted(os.listdir(root)):
        sdir = os.path.join(root, sender)
        if not os.path.isdir(sdir) or os.path.islink(sdir):
            continue
        for fname in sorted(os.listdir(sdir)):
            fpath = os.path.join(sdir, fname)
            if fname.endswith(".gz") and os.path.isfile(fpath) and not os.path.islink(fpath):
                yield sender, fname, fpath


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", default="/etc/syslog-archive.json")
    ap.add_argument("--dry-run", action="store_true", help="report only; no upload or delete")
    args = ap.parse_args()

    with open(args.config) as fh:
        cfg = json.load(fh)
    root, local_days = cfg["root"], float(cfg["local_days"])
    prefix = cfg.get("prefix") or socket.gethostname()
    state_path = cfg.get("state_file", "/var/lib/syslog-archive/state.json")
    state = load_state(state_path)
    blob = Blob(cfg, Token())
    now = time.time()
    counts = {"uploaded": 0, "exists": 0, "pruned": 0, "failed": 0, "held": 0}

    seen = set()
    for sender, fname, fpath in candidates(root):
        seen.add(fpath)
        name = f"{prefix}/{sender}/{fname}"
        try:
            md5 = state.get(fpath, {}).get("md5") or md5_b64(fpath)
            if not state.get(fpath, {}).get("archived"):
                if os.path.getsize(fpath) > MAX_SINGLE_PUT:
                    raise RuntimeError("file exceeds the 5000 MiB single-upload limit; lower logrotate maxsize")
                if args.dry_run:
                    log("info", f"would upload {fpath} -> {name}")
                    continue
                result = blob.upload(fpath, name, md5)
                if result == "exists" and blob.remote_md5(name) != md5:
                    raise RuntimeError(f"blob {name} exists with different content; local file kept")
                state[fpath] = {"md5": md5, "archived": True, "blob": name, "at": int(now)}
                save_state(state_path, state)
                counts[result] += 1
                log("info", f"{result}: {fpath} -> {name}")

            age_days = (now - os.path.getmtime(fpath)) / 86400
            if age_days > local_days and not args.dry_run:
                # Re-confirm the blob before deleting the only local copy.
                if blob.remote_md5(name) == md5:
                    os.remove(fpath)
                    state.pop(fpath, None)
                    save_state(state_path, state)
                    counts["pruned"] += 1
                    log("info", f"pruned local copy {fpath} ({age_days:.1f} days old)")
                else:
                    counts["held"] += 1
                    log("warn", f"kept {fpath}: archived copy not confirmed")
        except Exception as exc:  # keep going; report at the end
            counts["failed"] += 1
            log("err", f"archive failed for {fpath}: {exc}")

    for gone in [p for p in state if p not in seen]:
        state.pop(gone, None)
    if not args.dry_run:
        save_state(state_path, state)

    log("err" if counts["failed"] else "info",
        "summary " + " ".join(f"{k}={v}" for k, v in counts.items()))
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
