#!/usr/bin/env bash

set -euxo pipefail

tag()
{
    DISTRO="${1:-}"
    VERSION="${2:-}"

    if [ -z "${DISTRO}" ]; then
        echo "DISTRO missing!"
        return 1
    fi

    if [ -z "${VERSION}" ]; then
        echo "VERSION missing!"
        return 1
    fi

    git tag -f "${DISTRO}-${VERSION}"
    git push --force origin "${DISTRO}-${VERSION}"
}

getfedoravar()
{
    VAR="${1:-}"

    if [ -z "${VAR}" ]; then
        echo "VAR is missing!"
        return 1
    fi

    grep -E "${VAR} = \"([^\"]+)\"" pkg/fedora/kernel-surface/build-linux-surface.py | sed "s|^${VAR} = \"||g" | sed 's|"$||g'
}

getfedora()
{
    VERSION="$(getfedoravar PACKAGE_TAG | cut -d'-' -f2)"
    RELEASE="$(getfedoravar PACKAGE_RELEASE)"

    if [ -z "${VERSION}" ]; then
        echo "VERSION missing!"
        return 1
    fi

    if [ -z "${RELEASE}" ]; then
        echo "RELEASE missing!"
        return 1
    fi

    echo "${VERSION}-${RELEASE}"
}

# Tag the Fedora releases given as arguments, or the one this machine runs.
# Each tag triggers a full kernel build, so only tag what you need.
FEDORA_VERSIONS="${*:-$(. /etc/os-release && echo "${VERSION_ID}")}"

for FEDORA in ${FEDORA_VERSIONS}; do
    tag "fedora-${FEDORA}" "$(getfedora)"
done
