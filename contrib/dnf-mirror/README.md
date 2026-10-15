# dnf mirror for kernel-surface releases

This folder runs a small, signed dnf repository on your own server, so `sudo dnf upgrade` installs new `kernel-surface` releases.

It has two containers:

- **sync** checks this fork's GitHub Releases every 30 minutes.
  For each new `fedora-<N>-*` release, it downloads the packages needed to install the kernel, signs them with a local GPG key, and rebuilds the repository metadata.
  It keeps the newest three releases per Fedora version, so older kernels stay available as fallbacks.
- **web** is nginx, serving the repository over plain HTTP.
  Put it behind your reverse proxy for HTTPS.

The sync container only makes outbound requests to GitHub, so GitHub never needs to reach your network.
The signing key is generated on first start and never leaves the server.

## Set up the server

1. Copy this folder to the Docker host.
2. Create the configuration:

   ```sh
   cp .env.example .env
   ```

   Edit `.env`:
   - `GITHUB_REPO`: the fork to mirror, as `owner/name`.
   - `REPO_URL`: the URL your laptop uses to reach the repository through the reverse proxy.
   - `HTTP_PORT`: the host port for nginx, which your reverse proxy forwards to.

3. Start it:

   ```sh
   docker compose up -d --build
   docker compose logs -f sync
   ```

   The first run generates the signing key and downloads the current releases, about 200 MB each.

4. Point your reverse proxy at `http://<docker host>:<HTTP_PORT>`.

Back up the `gnupg/` folder.
If you lose it, the next start generates a new key, and every client has to import the new key.

## Set up a client

```sh
sudo dnf config-manager addrepo --from-repofile=<REPO_URL>/linux-surface-fork.repo
sudo dnf makecache
```

`dnf` asks you to confirm the signing key on first use.
Check that the fingerprint matches the one in `docker compose logs sync`.

New kernels then arrive with `sudo dnf upgrade`.
The repository file sets `skip_if_unavailable=True`, so `dnf` keeps working when the server isn't reachable.

`iptsd` isn't mirrored here.
Keep the upstream linux-surface repository for it, with `excludepkgs=kernel-surface*` in its section so it never replaces this kernel.

## Files

| File | Purpose |
|---|---|
| `sync.py` | Mirrors releases, signs packages, rebuilds metadata |
| `Dockerfile` | Fedora image with `createrepo_c`, `rpm-sign` and `gpg` |
| `compose.yaml` | The `sync` and `web` services |
| `nginx.conf` | Serves the repository with directory listings, hides dotfiles |
| `.env.example` | Configuration template; copy to `.env`, which git ignores |

Runtime data lives in `data/` (the repository and `state.json`) and `gnupg/` (the signing key). Git ignores both.
