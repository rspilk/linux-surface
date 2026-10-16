#!/usr/bin/env python3
"""
Mirror kernel-surface RPMs from GitHub Releases into a signed dnf repository.

Every INTERVAL seconds, this looks for fedora-<N>-* releases of GITHUB_REPO,
downloads the packages needed to install the kernel, signs them with a local
GPG key, and rebuilds the repository metadata. Only the newest KEEP releases
per Fedora version are kept.

Layout (DATA_DIR, default /data):
  repo/                             served by nginx
    fedora/f<N>/*.rpm, repodata/
    RPM-GPG-KEY-linux-surface-fork
    linux-surface-fork.repo
  state.json                        which files belong to which release

Usage: sync.py [--once]
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

GITHUB_REPO = os.environ["GITHUB_REPO"]
REPO_URL = os.environ["REPO_URL"].rstrip("/")
FEDORA_VERSIONS = os.environ.get("FEDORA_VERSIONS", "43").split()
KEEP = int(os.environ.get("KEEP", "3"))
INTERVAL = int(os.environ.get("INTERVAL", "1800"))

DATA_DIR = os.environ.get("DATA_DIR", "/data")
REPO_DIR = os.path.join(DATA_DIR, "repo")
STATE_FILE = os.path.join(DATA_DIR, "state.json")
GNUPGHOME = os.environ.setdefault("GNUPGHOME", "/gnupg")

KEY_NAME = "linux-surface fork repository signing key"
KEY_FILE = "RPM-GPG-KEY-linux-surface-fork"
REPO_FILE = "linux-surface-fork.repo"

TAG_RE = re.compile(r"^fedora-(\d+)-(.+)$")

# The packages needed to install the kernel. The *-matched and *-internal
# packages are left out on purpose, see the top-level README.
SUBPACKAGES = {"", "-core", "-modules", "-modules-core", "-modules-extra",
               "-devel", "-default-watchdog"}
ASSET_RE = re.compile(r"^kernel-surface(-core|-modules|-modules-core|"
                      r"-modules-extra|-devel|-default-watchdog)?-\d[^/]*\.rpm$")


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def run(*cmd):
    subprocess.run(cmd, check=True)


def api(path):
    req = urllib.request.Request(
        "https://api.github.com" + path,
        headers={"Accept": "application/vnd.github+json",
                 "User-Agent": "linux-surface-dnf-mirror"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def download(asset, dest):
    tmp = dest + ".part"
    sha = hashlib.sha256()
    req = urllib.request.Request(asset["browser_download_url"],
                                 headers={"User-Agent": "linux-surface-dnf-mirror"})
    with urllib.request.urlopen(req, timeout=300) as resp, open(tmp, "wb") as f:
        while chunk := resp.read(1 << 20):
            sha.update(chunk)
            f.write(chunk)

    digest = asset.get("digest") or ""
    if digest.startswith("sha256:") and digest[7:] != sha.hexdigest():
        os.unlink(tmp)
        raise RuntimeError(f"checksum mismatch for {asset['name']}")

    os.replace(tmp, dest)


def ensure_key():
    """Create the signing key on first run and publish its public half."""
    os.makedirs(GNUPGHOME, exist_ok=True)
    os.chmod(GNUPGHOME, 0o700)

    def fingerprint():
        out = subprocess.run(["gpg", "--batch", "--with-colons", "--list-secret-keys", KEY_NAME],
                             capture_output=True, text=True).stdout
        fprs = [line.split(":")[9] for line in out.splitlines() if line.startswith("fpr:")]
        return fprs[0] if fprs else None

    fpr = fingerprint()
    if not fpr:
        log("generating repository signing key")
        run("gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
            "--quick-gen-key", KEY_NAME, "rsa4096", "sign", "never")
        fpr = fingerprint()

    os.makedirs(REPO_DIR, exist_ok=True)
    with open(os.path.join(REPO_DIR, KEY_FILE), "wb") as f:
        f.write(subprocess.run(["gpg", "--batch", "--armor", "--export", fpr],
                               capture_output=True, check=True).stdout)
    return fpr


def write_repo_file():
    with open(os.path.join(REPO_DIR, REPO_FILE), "w") as f:
        f.write(f"""[linux-surface-fork]
name=linux-surface fork (Fedora $releasever)
baseurl={REPO_URL}/fedora/f$releasever/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey={REPO_URL}/{KEY_FILE}
skip_if_unavailable=True
metadata_expire=1h
""")


def complete_assets(release):
    """Return the wanted assets, or None while the release is still uploading."""
    assets = [a for a in release["assets"] if ASSET_RE.match(a["name"])]
    found = {ASSET_RE.match(a["name"]).group(1) or "" for a in assets}
    return assets if found == SUBPACKAGES else None


def sync_version(fedora, releases, state, fpr):
    """Bring fedora/f<fedora> up to date. Returns True if anything changed."""
    outdir = os.path.join(REPO_DIR, "fedora", f"f{fedora}")
    staging = os.path.join(DATA_DIR, "staging")
    os.makedirs(outdir, exist_ok=True)

    candidates = []
    for rel in releases:
        m = TAG_RE.match(rel["tag_name"])
        if not m or m.group(1) != fedora or rel["draft"]:
            continue
        assets = complete_assets(rel)
        if assets is None:
            log(f"{rel['tag_name']}: incomplete, skipping for now")
            continue
        candidates.append((rel["published_at"], rel["tag_name"], assets))

    keep = sorted(candidates, reverse=True)[:KEEP]
    keep_tags = {tag for _, tag, _ in keep}
    changed = False

    for _, tag, assets in keep:
        if tag in state:
            continue

        log(f"{tag}: downloading {len(assets)} packages")
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging)
        paths = []
        for asset in assets:
            path = os.path.join(staging, asset["name"])
            download(asset, path)
            paths.append(path)

        log(f"{tag}: signing")
        run("rpmsign", "--addsign", "--define", f"_gpg_name {fpr}",
            "--define", f"_gpg_path {GNUPGHOME}", *paths)

        for path in paths:
            os.replace(path, os.path.join(outdir, os.path.basename(path)))
        state[tag] = [os.path.basename(p) for p in paths]
        changed = True

    for tag in [t for t in state if TAG_RE.match(t).group(1) == fedora and t not in keep_tags]:
        log(f"{tag}: removing")
        for name in state.pop(tag):
            try:
                os.unlink(os.path.join(outdir, name))
            except FileNotFoundError:
                pass
        changed = True

    if changed or not os.path.exists(os.path.join(outdir, "repodata", "repomd.xml")):
        log(f"f{fedora}: rebuilding metadata")
        run("createrepo_c", "--quiet", "--update", outdir)
        repomd = os.path.join(outdir, "repodata", "repomd.xml")
        if os.path.exists(repomd + ".asc"):
            os.unlink(repomd + ".asc")
        run("gpg", "--batch", "--yes", "--local-user", fpr,
            "--detach-sign", "--armor", repomd)
        changed = True

    return changed


def sync_once(fpr):
    state = {}
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            state = json.load(f)

    releases = api(f"/repos/{GITHUB_REPO}/releases?per_page=50")
    for fedora in FEDORA_VERSIONS:
        sync_version(fedora, releases, state, fpr)

    with open(STATE_FILE + ".tmp", "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    os.replace(STATE_FILE + ".tmp", STATE_FILE)


def main():
    fpr = ensure_key()
    write_repo_file()
    log(f"mirroring {GITHUB_REPO} for Fedora {' '.join(FEDORA_VERSIONS)}, signing key {fpr}")

    while True:
        try:
            sync_once(fpr)
        except Exception as e:  # keep the loop alive across network errors
            log(f"sync failed: {e}")
            if "--once" in sys.argv:
                raise

        if "--once" in sys.argv:
            return
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
