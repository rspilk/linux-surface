# Maintaining this fork

This page covers the routine work: building new kernels, changing patches, moving to a new kernel series, and upgrading Fedora.
Most of it goes through `scripts/surface-kernel.sh`.

## Setup (once per machine)

1. Clone the fork with its SSH remote, so you can push.
2. Optional: link the helper into your `PATH`:

   ```sh
   ln -s "$PWD/scripts/surface-kernel.sh" ~/.local/bin/surface-kernel
   ```

3. If you run the dnf mirror from [`contrib/dnf-mirror`](contrib/dnf-mirror), create `~/.config/surface-kernel.env`:

   ```sh
   MIRROR_URL=https://<your mirror>
   MIRROR_SSH=<host running the mirror containers>
   ```

   Without it, everything except `wait`, `sync-mirror`, and the mirror lines in `status` still works.

Run `surface-kernel.sh help` for every command and option.

## Keys and secrets

Keep backups of these three things. Losing one means re-enrolling or re-importing keys on every machine.

| What | Where | Used for |
|---|---|---|
| Secure Boot private key | GitHub secret `SURFACE_SB_KEY` (base64 of the key matching `pkg/keys/surface.crt`) | Signing the kernel so it boots with Secure Boot on |
| Mirror GPG key | `gnupg/` in the mirror folder on the server | Signing the dnf repository |
| Package GPG key (optional) | GitHub secret `LINUX_SURFACE_GPG_KEY` | Signing the RPMs on the Releases page |

The certificate in `pkg/keys/surface.cer` must stay enrolled in MOK.
Check with `mokutil --list-enrolled | grep 'linux-surface fork'`.

## New kernel in the same series (for example, 7.2.11 to 7.2.12)

Fedora tags a new `kernel-ark` release every week or two.

```sh
surface-kernel.sh ark                                # is there a newer tag?
surface-kernel.sh check-patches kernel-7.2.12-0      # do the patches still apply?
surface-kernel.sh release --kernel-tag kernel-7.2.12-0 --fedora "43 44" --wait
surface-kernel.sh update --reboot                    # install it on this laptop
```

`release` sets `PACKAGE_TAG`, resets `PACKAGE_RELEASE` to 1, commits, pushes, and tags one build per Fedora version.
Each build takes about 1 hour 40 minutes on GitHub Actions.
`--wait` follows the build for this machine's Fedora version, syncs the mirror, and checks the Secure Boot signature.

If `check-patches` reports a conflict, see [Fix a patch that doesn't apply](#fix-a-patch-that-doesnt-apply).

## Change or add a patch

Each file in `patches/<series>/` is a series of commits in `git format-patch` (mbox) format, one file per feature area.
To fix something, add a commit to the matching file:

1. In a `kernel-ark` clone, check out the tag and apply the current patches:

   ```sh
   cd ark
   git checkout -B work kernel-7.2.11-0
   git am -3 ../linux-surface/patches/7.2/*.patch
   ```

2. Make the change, build or test it as you like, and commit it with a kernel-style message (`subsystem: driver: Do the thing`).
3. Append the commit to the matching patch file:

   ```sh
   git format-patch -1 --stdout >> ../linux-surface/patches/7.2/0013-cameras.patch
   ```

4. Check that everything still applies, then commit the fork and rebuild:

   ```sh
   surface-kernel.sh check-patches
   git -C ../linux-surface commit -am "patches/7.2: cameras: Do the thing"
   surface-kernel.sh release --rebuild --fedora "43 44" --wait
   ```

`--rebuild` keeps the kernel version and increases `PACKAGE_RELEASE`.

To test a driver change without waiting for CI, build only that module against the running kernel.
`kernel-surface-devel` is installed for this.
For example, from the `ark` tree:

```sh
make -C /lib/modules/$(uname -r)/build M=$PWD/drivers/media/i2c modules
sudo rmmod ov13858 && sudo insmod drivers/media/i2c/ov13858.ko
```

Secure Boot refuses unsigned modules.
Sign the module with `/usr/src/kernels/$(uname -r)/scripts/sign-file sha256 <key> pkg/keys/surface.crt ov13858.ko`, using your backup of the Secure Boot private key.

## Fix a patch that doesn't apply

When `check-patches` names a failing patch, Fedora's tree changed under it.

1. Apply up to the failing patch by hand in the `ark` clone:

   ```sh
   git checkout -B work kernel-7.2.12-0
   git am -3 ../linux-surface/patches/7.2/*.patch     # stops at the failing commit
   ```

2. Resolve the conflict in the listed files, then `git add` them and run `git am --continue`.
   Repeat for every commit that stops.
3. Regenerate the whole patch directory from the result.
   Each file holds the commits for one feature, in order, so regenerate one file at a time.
   Find the file's first and last commit by matching `git log --oneline --reverse kernel-7.2.12-0..` against `grep '^Subject:' ../linux-surface/patches/7.2/<file>.patch`, then:

   ```sh
   git format-patch --stdout <first>^..<last> > ../linux-surface/patches/7.2/0013-cameras.patch
   ```
4. Run `check-patches` again until it passes.

## New kernel series (for example, 7.2 to 7.3)

`surface-kernel.sh ark` warns when Fedora moves to a new series.
`release` refuses a tag until the patches for its series exist.

1. Look for a 7.3 port in upstream's pull requests at [linux-surface/linux-surface](https://github.com/linux-surface/linux-surface/pulls), or in forks.
   If there's none, start from `patches/7.2/` and fix each file as in the previous section.
2. Create `patches/7.3/` and `configs/surface-7.3.config` (usually a copy of the 7.2 config).
3. Run `surface-kernel.sh check-patches kernel-7.3.0-0` until it passes.
4. Check for silent collisions. These compile without errors and break things:
   - In `0010-surface-typecover.patch` and `0015-hid-surface.patch`, the hid-multitouch class IDs and quirk bits against `drivers/hid/hid-multitouch.c`.
   - In `0003-mwifiex.patch`, the btusb `driver_info` bits against `drivers/bluetooth/btusb.c`.
5. Re-apply the fork's own fixes on top, if the port doesn't have them.
   List them with `git log --oneline -- patches/7.2/`.
6. If the `kernel-ark` spec file changed, `check-patches` fails on one of `pkg/fedora/kernel-surface/patches/`.
   Fix it the same way, in the `redhat/` folder of the `ark` tree.
7. Release with `--kernel-tag kernel-7.3.0-0`.
   Keep the previous kernel installed until the new one has run for a few days.

## Upgrade Fedora (for example, 43 to 44)

### Before the upgrade

1. Build the kernel for the new version.
   The workflow `.github/workflows/fedora-<N>.yml` must exist; copy the previous one and change the three version numbers if it doesn't.

   ```sh
   bash scripts/tag-release.sh 44              # builds the current version for Fedora 44 only
   ```

2. Add the version to the mirror.
   In the mirror's `.env`, set `FEDORA_VERSIONS=43 44`, then run `docker compose up -d sync`.
   `restart` doesn't reread `.env`.
3. Check that the mirror serves the new build:

   ```sh
   curl -s <MIRROR_URL>/fedora/f44/ | grep kernel-surface-core
   ```

4. Until you finish upgrading, release with `--fedora "43 44"` so both versions get each kernel.

### The upgrade

```sh
sudo dnf upgrade --refresh
sudo dnf system-upgrade download --releasever=44
sudo dnf system-upgrade reboot
```

Stock Fedora kernels stay excluded: the `excludepkgs` settings on the `fedora` and `updates` repositories carry over, and the fork repository's URL follows `$releasever`.
If `system-upgrade` reports a kernel conflict, add `--allowerasing` only after reading what it removes.

### After the upgrade

1. Check the kernel and kmods: `surface-kernel.sh status`.
   If a kmod is missing, run `surface-kernel.sh kmods`.
2. Front camera colour: Fedora 44 ships libcamera 0.7.2.
   Delete the edited `/usr/share/libcamera/ipa/simple/ov5693.yaml` from Fedora 43 (no package owns it), and put [linux-surface#2302](https://github.com/linux-surface/linux-surface/pull/2302)'s unedited `ov5693.yaml` in `~/.config/libcamera/ipa/simple/`.
3. Test touch, pen, Type Cover, Wi-Fi, sound, and both cameras.
4. Stop building for the old version: release with `--fedora "44"` from now on, and set `FEDORA_VERSIONS=44` on the mirror once you no longer need its kernels.

## Troubleshooting

| Problem | What to do |
|---|---|
| New kernel doesn't boot | Choose the previous kernel in the GRUB menu (hold Shift or press Esc at power-on). Then `sudo grubby --set-default /boot/vmlinuz-<previous version>` and remove the bad one with `sudo dnf remove 'kernel-surface*-<version>*'`. |
| "bad shim signature" or Secure Boot error | The kernel isn't signed with this fork's key. Check with `surface-kernel.sh verify <version>`. Usually the `SURFACE_SB_KEY` secret is missing or wrong in GitHub. |
| VirtualBox, v4l2loopback, or another kmod missing after an update | `surface-kernel.sh kmods`. akmods doesn't retry on its own after a failed install. |
| Touch doesn't work | `systemctl status 'iptsd@*'` and `journalctl -b -u 'iptsd@*'`. Downgrade with `sudo dnf downgrade iptsd` if a new version broke it. |
| GNOME doesn't start; journal shows `libwacom ... bus_to_str: code should not be reached` | Stock `libwacom` replaced `libwacom-surface`. From a TTY (Ctrl+Alt+F3): `sudo dnf install --allowerasing libwacom-surface libwacom-surface-data`, then `sudo systemctl restart gdm`. Keep `libwacom-surface*` allowed in the upstream repository. |
| A stock Fedora kernel shows up in an update | Check `excludepkgs` in `/etc/dnf/repos.override.d/99-config_manager.repo`. |
| Upstream linux-surface repository offers its kernel | Its section in `/etc/yum.repos.d/linux-surface.repo` needs `excludepkgs=kernel-surface*` (or `includepkgs=iptsd`). |
| CI build fails | Open the run from `surface-kernel.sh status` and search the log for `error:`. Compile errors usually mean a patch applied but no longer fits the new kernel's code. |
| CI fails at the end of "Build packages" with `Allocation of hmac(sha512) cipher failed` | The runner's kernel can't compute `sha512hmac` for the build container. The build job is pinned to `ubuntu-24.04` for this reason. If that image is retired, try `ubuntu-latest` again. |
| Camera picture is upside down after another app used it | libcamera resets the sensor flips when a second program opens the camera. Close every camera app and reopen one. |
