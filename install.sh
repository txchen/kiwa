#!/bin/sh
# Installs the kiwa binary from a GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/txchen/kiwa/master/install.sh | sh
#
# Environment:
#   KIWA_VERSION      release to install, such as 0.1.0 (default: the latest)
#   KIWA_INSTALL_DIR  where to put kiwa (default: ~/.local/bin)
#   KIWA_BASE_URL     where the release assets live (default: GitHub)
set -eu

repo=txchen/kiwa
install_dir=${KIWA_INSTALL_DIR:-"$HOME/.local/bin"}

fail() {
    echo "kiwa install: $*" >&2
    exit 1
}

target() {
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux)
            case "$arch" in
                x86_64 | amd64) echo x86_64-linux-musl ;;
                aarch64 | arm64) echo aarch64-linux-musl ;;
                *) fail "no release for Linux on $arch" ;;
            esac
            ;;
        Darwin)
            # A shell under Rosetta reports x86_64 on an Apple silicon Mac.
            if [ "$arch" = arm64 ] || [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
                echo aarch64-macos
            else
                fail "no release for Intel Macs; Kiwa needs Apple silicon"
            fi
            ;;
        *) fail "no release for $os" ;;
    esac
}

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1" || fail "could not download $1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1" || fail "could not download $1"
    else
        fail "needs curl or wget"
    fi
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        fail "needs sha256sum or shasum to verify the download"
    fi
}

asset="kiwa-$(target).tar.gz"
if [ -n "${KIWA_BASE_URL:-}" ]; then
    base=$KIWA_BASE_URL
elif [ -n "${KIWA_VERSION:-}" ]; then
    base="https://github.com/$repo/releases/download/v${KIWA_VERSION#v}"
else
    base="https://github.com/$repo/releases/latest/download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fetch "$base/$asset" "$tmp/$asset"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"
want=$(awk -v f="$asset" '$2 == f || $2 == "./" f { print $1 }' "$tmp/SHA256SUMS")
[ -n "$want" ] || fail "SHA256SUMS does not list $asset"
[ "$(sha256 "$tmp/$asset")" = "$want" ] || fail "checksum mismatch for $asset"

tar -xzf "$tmp/$asset" -C "$tmp" kiwa
mkdir -p "$install_dir"
# Replace by rename, so that a running kiwa server keeps its old binary.
cp "$tmp/kiwa" "$install_dir/.kiwa.new"
chmod 755 "$install_dir/.kiwa.new"
mv -f "$install_dir/.kiwa.new" "$install_dir/kiwa"

echo "installed $("$install_dir/kiwa" --version) to $install_dir/kiwa"
case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) echo "add $install_dir to your PATH to run kiwa" ;;
esac
if "$install_dir/kiwa" ls >/dev/null 2>&1; then
    echo "a kiwa server is running; if it is an older version, run kiwa kill-server to restart it (the layout is restored)"
fi
