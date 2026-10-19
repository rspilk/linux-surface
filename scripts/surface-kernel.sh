#!/usr/bin/env bash
#
# surface-kernel.sh - manage the linux-surface fork kernel on this laptop.
#
# Usage: surface-kernel.sh <command> [options]
#
# Commands:
#   status                 Show running/installed kernels, what the mirror and GitHub
#                          have, the latest CI build, and missing kmods.
#   update [--all] [--no-verify] [--reboot]
#                          Install the newest kernel-surface from the mirror, then make
#                          sure akmods built and installed every kmod for it.
#                            --all        upgrade the whole system, not only the kernel
#                            --no-verify  skip the Secure Boot signature check
#                            --reboot     reboot when done (only if the new kernel is
#                                         the default boot entry)
#   verify [VERSION]       Check that kernel-surface VERSION (e.g. 7.2.11-3, default:
#                          newest on the mirror) is signed with this fork's Secure Boot key.
#   kmods [KVER]           Install any kmods missing for KVER (default: newest installed
#                          kernel-surface), from akmods' cache or by rebuilding.
#   ark                    Show the newest kernel-ark tags next to the fork's PACKAGE_TAG.
#   check-patches [TAG]    Apply patches/<series>/ and the spec patches to kernel-ark TAG
#                          (default: the fork's PACKAGE_TAG) in a scratch worktree, to
#                          catch conflicts before a 1h40 CI build.
#   release (--rebuild | --kernel-tag TAG) [--fedora "43 44"] [--wait] [-y]
#                          Bump the release in the fork, commit, push, and tag it so
#                          GitHub Actions builds it.
#                            --rebuild         same kernel, PACKAGE_RELEASE + 1
#                            --kernel-tag TAG  new kernel-ark tag (e.g. kernel-7.2.12-0),
#                                              PACKAGE_RELEASE reset to 1
#                            --fedora "N ..."  Fedora versions to build (default: this one)
#                            --wait            then run 'wait' for this Fedora version
#                            -y                don't ask for confirmation
#   wait [VERSION] [--no-sync]
#                          Follow the GitHub build of fedora-<this Fedora>-VERSION
#                          (default: the fork's current PACKAGE_TAG/RELEASE) until it
#                          finishes, then sync the mirror and wait until it serves it.
#                            --no-sync   don't trigger the mirror; wait for its own check
#   sync-mirror [VERSION]  Make the mirror check for new releases now (over ssh), and
#                          wait until it serves VERSION if given.
#   help                   Show this help. '<command> --help' works too.
#
# Examples:
#   surface-kernel.sh                                    # same as 'status'
#   surface-kernel.sh ark                                # is there a newer Fedora kernel?
#   surface-kernel.sh check-patches kernel-7.2.12-0      # do the patches still apply?
#   surface-kernel.sh release --kernel-tag kernel-7.2.12-0 --wait
#   surface-kernel.sh release --rebuild --wait           # rebuild after a patch change
#   surface-kernel.sh update --reboot                    # install it on this laptop
#   surface-kernel.sh release --rebuild --fedora "43 44" # build for two Fedora versions
#
# Needs:
#   update, kmods          sudo on this laptop
#   release                push access to the fork (SSH key), a clean git tree
#   wait, sync-mirror      ssh to MIRROR_SSH, with docker access there
#
# Settings: environment variables, or lines like MIRROR_URL=... in
# ~/.config/surface-kernel.env (read first; the environment wins):
#   REPO_DIR     the fork's local clone (default: the clone this script is in)
#   GITHUB_REPO  owner/name on GitHub (default: rspilk/linux-surface)
#   MIRROR_URL   the dnf mirror, e.g. https://repo.example.com
#   MIRROR_SSH   host running the mirror, for wait/sync-mirror
#   MIRROR_DIR   mirror folder on that host (default: ~/dnf-mirror)
#   ARK_DIR      local kernel-ark clone for check-patches (default: ark/ next to
#                the fork's clone; cloned there if missing, ~5 GB)
#   ARK_URL      https://gitlab.com/cki-project/kernel-ark.git

set -euo pipefail

CONFIG="$HOME/.config/surface-kernel.env"
if [[ -f "$CONFIG" ]]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_]+$ && -z "${!key:-}" ]] && export "$key=$value"
    done < "$CONFIG"
fi

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
GITHUB_REPO="${GITHUB_REPO:-rspilk/linux-surface}"
MIRROR_URL="${MIRROR_URL:-}"
ARK_URL="${ARK_URL:-https://gitlab.com/cki-project/kernel-ark.git}"
ARK_DIR="${ARK_DIR:-$(dirname "$REPO_DIR")/ark}"
MIRROR_SSH="${MIRROR_SSH:-}"
MIRROR_DIR="${MIRROR_DIR:-~/dnf-mirror}"

CERT="$REPO_DIR/pkg/keys/surface.crt"
BUILD_PY="$REPO_DIR/pkg/fedora/kernel-surface/build-linux-surface.py"
FEDORA="$(. /etc/os-release && echo "$VERSION_ID")"
ARCH="$(uname -m)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    [[ "${YES:-0}" == 1 ]] && return 0
    read -r -p "$1 [y/N] " reply
    [[ "$reply" == [yY]* ]]
}

github_api() {
    curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$GITHUB_REPO$1"
}

# Versions (VERSION-RELEASE without .surface.fcNN) on the mirror, oldest first
mirror_versions() {
    [[ -n "$MIRROR_URL" ]] || return 0
    curl -fsSL "$MIRROR_URL/fedora/f$FEDORA/" 2>/dev/null \
        | grep -oE "kernel-surface-core-[0-9][^\"]*\.$ARCH\.rpm" \
        | sed -E "s/^kernel-surface-core-//; s/\.surface\.fc[0-9]+\.$ARCH\.rpm$//" \
        | sort -uV
}

# Installed kernel-surface versions, oldest first
installed_versions() {
    rpm -q kernel-surface-core --qf '%{VERSION}-%{RELEASE}\n' 2>/dev/null \
        | sed -E 's/\.surface\.fc[0-9]+$//' | sort -V
}

kver_of() { echo "$1.surface.fc$FEDORA.$ARCH"; }

newest_installed_kver() {
    local v
    v="$(installed_versions | tail -1)"
    [[ -n "$v" ]] && kver_of "$v"
}

# Print "name" for every akmod whose kmod is missing for the given kernel
missing_kmods() {
    local kver="$1" akmod name
    for akmod in $(rpm -qa 'akmod-*' --qf '%{NAME}\n' | sort); do
        name="${akmod#akmod-}"
        rpm -q "kmod-$name-$kver" &>/dev/null || echo "$name"
    done
}

wait_for_akmods() {
    local waited=0
    while pgrep -x akmods >/dev/null || pgrep -f akmodsbuild >/dev/null; do
        ((waited == 0)) && echo "  waiting for akmods to finish building..."
        sleep 5
        waited=$((waited + 5))
        ((waited > 900)) && { warn "akmods still running after 15 minutes"; return; }
    done
}

cmd_status() {
    bold "Kernels"
    echo "  running:   $(uname -r)"
    echo "  installed: $(installed_versions | tr '\n' ' ')"
    local def
    if def="$(sudo -n grubby --default-kernel 2>/dev/null)"; then
        echo "  default:   ${def#/boot/vmlinuz-}"
    else
        echo "  default:   (run 'sudo grubby --default-kernel' to see)"
    fi

    bold "Available"
    local mirror newest_installed
    mirror="$(mirror_versions | tr '\n' ' ')"
    echo "  mirror f$FEDORA: ${mirror:-unreachable}"
    newest_installed="$(installed_versions | tail -1)"
    local newest_mirror
    newest_mirror="$(mirror_versions | tail -1)"
    if [[ -n "$newest_mirror" ]]; then
        if [[ "$(printf '%s\n%s\n' "$newest_installed" "$newest_mirror" | sort -V | tail -1)" != "$newest_installed" ]]; then
            warn "$newest_mirror is newer than what's installed; run: $0 update"
        else
            ok "newest mirror version is installed"
        fi
    fi

    github_api "/releases?per_page=20" 2>/dev/null | python3 -c "
import json, sys
fedora = sys.argv[1]
rels = [r for r in json.load(sys.stdin) if r['tag_name'].startswith(f'fedora-{fedora}-')]
print('  github:    ' + (rels[0]['tag_name'] + ' (' + rels[0]['published_at'][:16].replace('T', ' ') + ' UTC)' if rels else 'no releases'))
" "$FEDORA" || warn "couldn't reach GitHub"

    bold "Latest CI build"
    github_api "/actions/runs?per_page=1" 2>/dev/null | python3 -c "
import json, sys
r = json.load(sys.stdin)['workflow_runs'][0]
print(f\"  {r['head_branch']}: {r['status']} {r['conclusion'] or ''}  (started {r['created_at'][:16].replace('T', ' ')} UTC)\")
print(f\"  {r['html_url']}\")
" || warn "couldn't reach GitHub"

    bold "Fork"
    if [[ -f "$BUILD_PY" ]]; then
        echo "  $(grep -E '^PACKAGE_(TAG|RELEASE) = ' "$BUILD_PY" | tr -d '"' | tr '\n' ' ')"
        echo "  $(git -C "$REPO_DIR" status -sb | head -1)"
    else
        warn "repo not found at $REPO_DIR"
    fi

    bold "kmods"
    local kver missing
    for kver in $(uname -r) $(newest_installed_kver); do
        missing="$(missing_kmods "$kver" | tr '\n' ' ')"
        if [[ -n "$missing" ]]; then
            warn "$kver missing: $missing (run: $0 kmods $kver)"
        else
            ok "$kver: all kmods installed"
        fi
    done | sort -u
}

# Verify the Secure Boot signature of kernel-surface VERSION from the mirror
cmd_verify() {
    local version="${1:-$(mirror_versions | tail -1)}"
    [[ -n "$version" ]] || die "no version given and the mirror is unreachable"
    [[ -f "$CERT" ]] || die "certificate not found: $CERT"

    local kver rpmfile tmp
    kver="$(kver_of "$version")"
    rpmfile="kernel-surface-core-$kver.rpm"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"; trap - RETURN' RETURN

    bold "Verifying $kver"
    curl -fsSL -o "$tmp/$rpmfile" "$MIRROR_URL/fedora/f$FEDORA/$rpmfile" \
        || curl -fsSL -o "$tmp/$rpmfile" \
            "https://github.com/$GITHUB_REPO/releases/download/fedora-$FEDORA-$version/$rpmfile" \
        || die "couldn't download $rpmfile"
    (cd "$tmp" && rpm2cpio "$rpmfile" | cpio -idm --quiet "./lib/modules/$kver/vmlinuz") \
        || die "no vmlinuz in $rpmfile"

    # Pull the Authenticode signatures out of the PE certificate table
    python3 -I - "$tmp/lib/modules/$kver/vmlinuz" "$tmp" <<'EOF'
import struct, sys
data = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', data, 0x3c)[0]
assert data[pe:pe + 4] == b'PE\0\0', 'not a PE image'
opt = pe + 24
dd = opt + (112 if struct.unpack_from('<H', data, opt)[0] == 0x20b else 96)
off, size = struct.unpack_from('<II', data, dd + 8 * 4)
i, n = off, 0
while i < off + size:
    length = struct.unpack_from('<I', data, i)[0]
    open(f'{sys.argv[2]}/sig{n}.der', 'wb').write(data[i + 8:i + length])
    n += 1
    i += (length + 7) & ~7
EOF

    local expected found=0 sig fpr
    expected="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2)"
    for sig in "$tmp"/sig*.der; do
        [[ -e "$sig" ]] || continue
        fpr="$(openssl pkcs7 -inform der -in "$sig" -print_certs 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
        if [[ "$fpr" == "$expected" ]] \
            && openssl smime -verify -inform der -in "$sig" -noverify -binary -out /dev/null 2>/dev/null; then
            found=1
        fi
    done

    if ((found)); then
        ok "signed with this fork's Secure Boot key ($expected)"
    else
        fail "NOT signed with this fork's key - don't install it, it won't boot with Secure Boot on"
        return 1
    fi
}

cmd_kmods() {
    local kver="${1:-$(newest_installed_kver)}" name rpmfile
    [[ -n "$kver" ]] || die "no kernel-surface installed"
    wait_for_akmods

    bold "kmods for $kver"
    local missing
    missing="$(missing_kmods "$kver")"
    if [[ -z "$missing" ]]; then
        ok "all kmods installed"
        return
    fi

    for name in $missing; do
        rpmfile="$(ls -t /var/cache/akmods/"$name"/kmod-"$name"-"$kver"-*.rpm 2>/dev/null | head -1 || true)"
        if [[ -n "$rpmfile" ]]; then
            echo "  $name: installing the package akmods already built"
            sudo dnf install -y "$rpmfile"
        else
            echo "  $name: rebuilding with akmods"
            sudo akmods --force --kernels "$kver"
        fi
    done

    missing="$(missing_kmods "$kver")"
    [[ -z "$missing" ]] && ok "all kmods installed" || fail "still missing: $missing"
}

cmd_update() {
    local all=0 verify=1 reboot=0
    while (($#)); do
        case "$1" in
            --all) all=1 ;;
            --no-verify) verify=0 ;;
            --reboot) reboot=1 ;;
            *) die "unknown option for update: $1" ;;
        esac
        shift
    done

    local before newest
    before="$(installed_versions | tail -1)"
    newest="$(mirror_versions | tail -1)"
    [[ -n "$newest" ]] || warn "mirror unreachable; dnf will skip it"

    if ((verify)) && [[ -n "$newest" && "$newest" != "$before" ]]; then
        cmd_verify "$newest"
    fi

    bold "Upgrading"
    if ((all)); then
        sudo dnf upgrade --refresh
    else
        sudo dnf upgrade --refresh 'kernel-surface*'
    fi

    local after
    after="$(installed_versions | tail -1)"
    if [[ "$after" == "$before" ]]; then
        ok "kernel-surface already up to date ($after)"
    else
        ok "installed kernel-surface $after"
    fi

    cmd_kmods "$(kver_of "$after")"

    bold "Boot"
    local def
    def="$(sudo grubby --default-kernel)"
    if [[ "$def" == "/boot/vmlinuz-$(kver_of "$after")" ]]; then
        ok "default boot kernel: ${def#/boot/vmlinuz-}"
    else
        warn "default boot kernel is ${def#/boot/vmlinuz-}, not $(kver_of "$after")"
        warn "fix with: sudo grubby --set-default /boot/vmlinuz-$(kver_of "$after")"
        reboot=0
    fi

    if [[ "$(uname -r)" == "$(kver_of "$after")" ]]; then
        ok "already running it, no reboot needed"
    elif ((reboot)); then
        echo "  rebooting..."
        sudo systemctl reboot
    else
        echo "  reboot to start $(kver_of "$after")"
    fi
}

# VERSION-RELEASE the fork is currently set to build, e.g. 7.2.11-3
fork_version() {
    [[ -f "$BUILD_PY" ]] || die "repo not found at $REPO_DIR"
    local tag rel
    tag="$(grep -E '^PACKAGE_TAG = ' "$BUILD_PY" | cut -d'"' -f2)"
    rel="$(grep -E '^PACKAGE_RELEASE = ' "$BUILD_PY" | cut -d'"' -f2)"
    tag="${tag#kernel-}"
    echo "${tag%-0}-$rel"
}

mirror_has() { mirror_versions | grep -qxF "$1"; }

cmd_sync_mirror() {
    local version="${1:-}"
    [[ -n "$MIRROR_SSH" ]] || die "MIRROR_SSH isn't set (see $CONFIG)"
    bold "Mirror"
    if [[ -n "$version" ]] && mirror_has "$version"; then
        ok "already serving $version"
        return
    fi
    echo "  asking $MIRROR_SSH to check for new releases"
    ssh "$MIRROR_SSH" "cd $MIRROR_DIR && docker compose restart sync >/dev/null" \
        || die "couldn't restart the sync container on $MIRROR_SSH"
    [[ -n "$version" ]] || { ok "sync restarted"; return; }

    local waited=0
    until mirror_has "$version"; do
        sleep 15
        waited=$((waited + 15))
        ((waited > 900)) && die "mirror still doesn't have $version after 15 minutes; check: ssh $MIRROR_SSH 'cd $MIRROR_DIR && docker compose logs --tail 20 sync'"
    done
    ok "serving $version"
}

cmd_wait() {
    local version="" sync=1
    while (($#)); do
        case "$1" in
            --no-sync) sync=0 ;;
            *) version="$1" ;;
        esac
        shift
    done
    version="${version:-$(fork_version)}"
    local tag="fedora-$FEDORA-$version"

    bold "Waiting for build $tag"
    local state last=""
    while :; do
        state="$(github_api "/actions/runs?per_page=20" 2>/dev/null | python3 -c "
import json, sys
runs = [r for r in json.load(sys.stdin)['workflow_runs'] if r['head_branch'] == sys.argv[1]]
if not runs:
    print('missing')
else:
    r = runs[0]
    print(r['status'], r['conclusion'] or '-', r['html_url'])
" "$tag" || echo "unreachable")"
        case "$state" in
            completed\ success*) ok "build succeeded"; break ;;
            completed*) fail "build finished: $state"; return 1 ;;
            missing) [[ "$last" == missing ]] || echo "  no run for $tag yet (was the tag pushed?)" ;;
            unreachable) ;;
            *) [[ "$state" == "$last" ]] || echo "  $state" ;;
        esac
        last="$state"
        sleep 60
    done

    if ((sync)); then
        cmd_sync_mirror "$version"
    else
        bold "Mirror"
        echo "  waiting for the mirror's own check (up to 30 minutes)"
        until mirror_has "$version"; do sleep 60; done
        ok "serving $version"
    fi
    cmd_verify "$version"
    ok "ready; install with: $0 update"
}

cmd_ark() {
    [[ -f "$BUILD_PY" ]] || die "repo not found at $REPO_DIR"
    local current series
    current="$(grep -E '^PACKAGE_TAG = ' "$BUILD_PY" | cut -d'"' -f2)"
    series="$(echo "$current" | sed -E 's/^kernel-([0-9]+\.[0-9]+)\..*/\1/')"

    bold "kernel-ark"
    echo "  fork builds:    $current"
    local tags
    tags="$(git ls-remote --tags "$ARK_URL" 'refs/tags/kernel-*' \
        | grep -oE 'kernel-[0-9]+\.[0-9]+\.[0-9]+-0$' | sort -uV)"
    echo "  newest $series.x:   $(echo "$tags" | grep -F "kernel-$series." | tail -1)"
    echo "  newest overall: $(echo "$tags" | tail -1)"
    local newest_series
    newest_series="$(echo "$tags" | tail -1 | sed -E 's/^kernel-([0-9]+\.[0-9]+)\..*/\1/')"
    if [[ "$newest_series" != "$series" ]]; then
        warn "Fedora has moved to $newest_series; that needs patches/$newest_series and configs/surface-$newest_series.config first"
    fi
}

cmd_check_patches() {
    [[ -f "$BUILD_PY" ]] || die "repo not found at $REPO_DIR"
    local tag="${1:-$(grep -E '^PACKAGE_TAG = ' "$BUILD_PY" | cut -d'"' -f2)}" series
    series="$(echo "$tag" | sed -E 's/^kernel-([0-9]+\.[0-9]+)\..*/\1/')"
    [[ -d "$REPO_DIR/patches/$series" ]] || die "no patches/$series yet"
    [[ -f "$REPO_DIR/configs/surface-$series.config" ]] || warn "no configs/surface-$series.config yet"

    if [[ ! -d "$ARK_DIR/.git" ]]; then
        echo "  cloning kernel-ark to $ARK_DIR (one time, ~5 GB)"
        git clone -q --no-checkout "$ARK_URL" "$ARK_DIR"
    fi
    git -C "$ARK_DIR" fetch -q "$ARK_URL" "+refs/tags/$tag:refs/tags/$tag" || die "$tag doesn't exist in kernel-ark"

    local wt
    wt="$(mktemp -d)/ark"
    git -C "$ARK_DIR" worktree add -q --detach "$wt" "$tag"
    trap 'git -C "$ARK_DIR" worktree remove --force "$wt"; trap - RETURN' RETURN

    # Same order as build-ark.py: Surface patches, then the spec patches
    bold "Applying patches to $tag"
    local p failed=0
    for p in "$REPO_DIR"/patches/"$series"/*.patch "$REPO_DIR"/pkg/fedora/kernel-surface/patches/*.patch; do
        if git -C "$wt" am -q -3 "$p" >/dev/null 2>&1; then
            ok "$(basename "$p")"
        else
            fail "$(basename "$p") doesn't apply:"
            git -C "$wt" diff --name-only --diff-filter=U | sed 's/^/      conflict: /'
            git -C "$wt" am --abort
            failed=1
            break
        fi
    done
    ((failed)) && return 1
    ok "all patches apply; also check the ID collisions listed in MAINTAINING.md"
}

cmd_release() {
    local mode="" tag="" fedoras="$FEDORA" wait=0
    while (($#)); do
        case "$1" in
            --rebuild) mode=rebuild ;;
            --kernel-tag) mode=tag; tag="${2:-}"; shift ;;
            --fedora) fedoras="${2:-}"; shift ;;
            --wait) wait=1 ;;
            -y) YES=1 ;;
            *) die "unknown option for release: $1" ;;
        esac
        shift
    done
    [[ -n "$mode" ]] || die "release needs --rebuild or --kernel-tag TAG"
    [[ -f "$BUILD_PY" ]] || die "repo not found at $REPO_DIR"
    [[ -z "$(git -C "$REPO_DIR" status --porcelain)" ]] || die "uncommitted changes in $REPO_DIR"

    local cur_tag cur_rel new_tag new_rel
    cur_tag="$(grep -E '^PACKAGE_TAG = ' "$BUILD_PY" | cut -d'"' -f2)"
    cur_rel="$(grep -E '^PACKAGE_RELEASE = ' "$BUILD_PY" | cut -d'"' -f2)"

    if [[ "$mode" == rebuild ]]; then
        new_tag="$cur_tag"
        new_rel=$((cur_rel + 1))
    else
        [[ "$tag" =~ ^kernel-[0-9]+\.[0-9]+\.[0-9]+-0$ ]] || die "tag should look like kernel-7.2.12-0"
        git ls-remote --exit-code --tags "$ARK_URL" "refs/tags/$tag" >/dev/null \
            || die "$tag doesn't exist in kernel-ark"
        local major
        major="$(echo "$tag" | sed -E 's/^kernel-([0-9]+\.[0-9]+)\..*/\1/')"
        [[ -d "$REPO_DIR/patches/$major" && -f "$REPO_DIR/configs/surface-$major.config" ]] \
            || die "no patches/$major or configs/surface-$major.config yet; port the patches first"
        new_tag="$tag"
        new_rel=1
    fi

    local version="${new_tag#kernel-}"
    version="${version%-0}-$new_rel"
    bold "Release"
    echo "  $cur_tag release $cur_rel  ->  $new_tag release $new_rel"
    echo "  builds: $(for f in $fedoras; do printf 'fedora-%s-%s ' "$f" "$version"; done)"
    confirm "Commit, push and tag?" || die "cancelled"

    sed -i -E "s/^PACKAGE_TAG = \".*\"/PACKAGE_TAG = \"$new_tag\"/; s/^PACKAGE_RELEASE = \".*\"/PACKAGE_RELEASE = \"$new_rel\"/" "$BUILD_PY"
    git -C "$REPO_DIR" commit -q -am "Update Fedora kernels to v$version"
    git -C "$REPO_DIR" push -q origin HEAD
    # shellcheck disable=SC2086
    (cd "$REPO_DIR" && bash scripts/tag-release.sh $fedoras)
    ok "pushed and tagged"

    if ((wait)); then
        [[ " $fedoras " == *" $FEDORA "* ]] || { warn "--wait only follows this machine's Fedora ($FEDORA)"; return; }
        cmd_wait "$version"
    else
        echo "  follow the build with: $0 wait $version"
    fi
}

usage() { sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-status}"
shift || true
for arg in "$@"; do
    [[ "$arg" == -h || "$arg" == --help ]] && { usage; exit 0; }
done
case "$cmd" in
    status) cmd_status ;;
    update) cmd_update "$@" ;;
    verify) cmd_verify "$@" ;;
    kmods) cmd_kmods "$@" ;;
    ark) cmd_ark ;;
    check-patches) cmd_check_patches "$@" ;;
    release) cmd_release "$@" ;;
    wait) cmd_wait "$@" ;;
    sync-mirror) cmd_sync_mirror "$@" ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
esac
