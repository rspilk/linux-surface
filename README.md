# linux-surface for Surface Pro 8 on Fedora

This repository is a personal fork of [linux-surface][upstream].
It builds one thing: a patched Fedora kernel (`kernel-surface`) for a Surface Pro 8, signed with this fork's own Secure Boot key.

It exists because upstream's Fedora packages stopped at kernel 6.19.8, while Fedora moved to the 7.x series.
For other devices, distributions, or user-space packages, use [upstream][upstream].

## Current status

| | |
|---|---|
| Kernel | 7.2.11, built from Fedora's `kernel-ark` tag `kernel-7.2.11-0` |
| Fedora | 43 (workflows for 44 and 45 exist but are untested) |
| Device | Surface Pro 8 |

Tested on the Surface Pro 8 with release `7.2.11-2`:

| Feature | Status |
|---|---|
| Boot with Secure Boot | Works |
| Touch and pen (ITHC + iptsd) | Works |
| Type Cover | Works |
| Wi-Fi, sound | Works |
| Front camera | Works, upright. Colour needs a libcamera tuning file (see below) |
| Rear camera | Works, upright, but red and blue are swapped (fix in `7.2.11-3`) |

### Camera colour

The cameras go through libcamera's software ISP, which needs a tuning file per sensor for good colour.
For the front camera (OV5693), use the tuning file from [linux-surface#2302][pr-2302]:

- **libcamera 0.7.2 or newer (Fedora 44+):** copy its `ov5693.yaml` to `~/.config/libcamera/ipa/simple/`.
- **libcamera 0.5.2 (Fedora 43):** 0.5.2 doesn't know the file's `Adjust` step and doesn't read `~/.config`.
  Replace `- Adjust:` with `- Lut:` and copy it to `/usr/share/libcamera/ipa/simple/ov5693.yaml`, then run `systemctl --user restart wireplumber`.

There's no tuning file for the rear camera (OV13858) yet.

## What's different from upstream

- **Kernel 7.2 patches** in `patches/7.2/`, from [linux-surface#2233][pr-2233], with `0013-cameras.patch` regenerated so it applies to Fedora's `kernel-ark` tree.
- **Surface Pro 8 camera fixes** from [#2171][pr-2171] (front camera streaming) and [#2227][pr-2227] (rear camera rotation), plus a fix for #2227 swapping red and blue on the rear camera.
- **Fedora only.** The Arch and Debian packaging, the package repository upload, and the autoupdate bots are removed.
- **Own Secure Boot key.** Kernels are signed with the certificate in [`pkg/keys/surface.cer`](pkg/keys/surface.cer), not upstream's.
- **Releases only.** RPMs are published as GitHub Releases. There's no dnf repository.

## Install

### 1. Enroll the Secure Boot certificate (once)

```sh
sudo mokutil --import pkg/keys/surface.cer
```

Set a one-time password, reboot, and in MokManager choose **Enroll MOK** → **Continue** → **Yes**, then enter the password.

### 2. Keep upstream from replacing the kernel

If the upstream `linux-surface` dnf repository is configured (it's still useful for `iptsd`), add this line to its section in `/etc/yum.repos.d/linux-surface.repo`:

```ini
excludepkgs=kernel-surface*
```

### 3. Install the RPMs

Download the RPMs from a `fedora-<fedora version>-<kernel version>-<release>` release on the [Releases](../../releases) page, then install these packages from the download folder:

```sh
V=7.2.11-3.surface.fc43.x86_64
sudo dnf install \
  ./kernel-surface-$V.rpm \
  ./kernel-surface-core-$V.rpm \
  ./kernel-surface-modules-$V.rpm \
  ./kernel-surface-modules-core-$V.rpm \
  ./kernel-surface-modules-extra-$V.rpm \
  ./kernel-surface-devel-$V.rpm \
  ./kernel-surface-default-watchdog-$V.rpm
```

Don't install the `*-matched` or `*-internal` packages.
The `-matched` ones require matching packages for every older `kernel-surface` you have installed, which fails when upstream's repository is excluded.

The `default-watchdog` package keeps the newest `kernel-surface` as the default boot entry.
Check it with `sudo grubby --default-kernel`.

For touch and pen input, also install `iptsd`.

To get new kernels through `sudo dnf upgrade` instead, run the self-hosted mirror in [`contrib/dnf-mirror`](contrib/dnf-mirror).

## Build a release

1. In `pkg/fedora/kernel-surface/build-linux-surface.py`, set `PACKAGE_TAG` to a [kernel-ark tag][ark-tags] such as `kernel-7.2.11-0`, and set `PACKAGE_RELEASE`.
   Use release `1` for a new kernel version, and increase it for rebuilds.
2. Commit and push to `main`.
3. Tag and push the release:

   ```sh
   bash scripts/tag-release.sh 43
   ```

   This creates the tag `fedora-43-<version>-<release>`, which starts the **Fedora 43** workflow.
   The build takes about 1 hour 40 minutes, and the RPMs appear on the Releases page.
   With no arguments, the script tags the Fedora version of the machine it runs on.

The workflow needs the repository secret `SURFACE_SB_KEY`: the base64-encoded private key that matches `pkg/keys/surface.crt`.
Without it, the kernel is signed with Red Hat test keys and won't boot with Secure Boot on.

### Moving to a new kernel version

When Fedora moves to a new kernel series (for example, 7.3):

1. Add `patches/<version>/` and `configs/surface-<version>.config`, usually from the matching upstream pull request.
2. Check that the patches apply with `git am -3` to the new `kernel-ark` tag.
   Fedora's tree carries backports that stable kernels don't have, so patches that apply to stable can still fail here.
3. In `0010-surface-typecover.patch` and `0015-hid-surface.patch`, check the hid-multitouch class IDs and quirk bits, and in `0003-mwifiex.patch` the btusb `driver_info` bits, against the new kernel's values.
   Collisions compile without errors and break things silently.
4. Rebase `pkg/fedora/kernel-surface/patches/` if the `kernel-ark` spec file changed.

## Repository layout

| Path | Contents |
|---|---|
| `patches/<version>/` | Surface kernel patches, one file per feature area |
| `configs/` | Kernel config fragments merged into Fedora's config |
| `pkg/fedora/kernel-surface/` | Build scripts and `kernel-ark` spec patches |
| `pkg/keys/` | Secure Boot certificate for this fork |
| `.github/workflows/fedora-*.yml` | Build and release workflows, one per Fedora version |
| `scripts/tag-release.sh` | Creates and pushes release tags |
| `contrib/dnf-mirror/` | Self-hosted, signed dnf repository that mirrors the releases |

Older patch directories (6.x) are kept from upstream for reference.

## Credits

The patches and packaging come from the [linux-surface][upstream] project and its contributors.
The 7.x port is from Apiznel ([#2233][pr-2233]), with fixes collected in [orthogonaleety/linux-surface][ortho].
The camera fixes are from Arsalan Naeem ([#2171][pr-2171]) and Eva Dixon ([#2227][pr-2227]).

## License

This repository contains patches, which are either derivative work targeting a specific already licensed source, i.e. parts of the Linux kernel, or introduce new parts to the Linux kernel.
These patches fall thus, if not explicitly stated otherwise, under the license of the source they are targeting, or if they introduce new code, the license they explicitly specify inside of the patch.
Please refer to the specific patch and source in question for further information.
License texts can be obtained at https://github.com/torvalds/linux/tree/master/LICENSES.

[upstream]: https://github.com/linux-surface/linux-surface
[ortho]: https://github.com/orthogonaleety/linux-surface
[pr-2171]: https://github.com/linux-surface/linux-surface/pull/2171
[pr-2227]: https://github.com/linux-surface/linux-surface/pull/2227
[pr-2233]: https://github.com/linux-surface/linux-surface/pull/2233
[pr-2302]: https://github.com/linux-surface/linux-surface/pull/2302
[ark-tags]: https://gitlab.com/cki-project/kernel-ark/-/tags
