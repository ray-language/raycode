#!/bin/sh
# raycode installer. Downloads the prebuilt binary for this platform from the GitHub
# Release and installs it into a directory on your PATH.
#
#   curl -sSfL https://raw.githubusercontent.com/roberto-ayala/raycode/main/install.sh | sh
#
# Environment variables (all optional):
#   RAYCODE_VERSION   tag to install (e.g. v0.1.0). Default: the latest release.
#   RAYCODE_BIN_DIR   install directory. Default: $HOME/.local/bin
#   RAYCODE_REPO      owner/repo. Default: roberto-ayala/raycode
#   RAYCODE_DRY_RUN   if set, print the plan and download nothing (to test detection).
set -eu

REPO="${RAYCODE_REPO:-roberto-ayala/raycode}"
BIN_DIR="${RAYCODE_BIN_DIR:-$HOME/.local/bin}"

info() { printf '\033[1;34m→\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mnota:\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Detect the platform → Rust target triple ---------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux)  suffix="unknown-linux-gnu" ;;
  Darwin) suffix="apple-darwin" ;;
  MINGW*|MSYS*|CYGWIN*)
    err "raycode drives the terminal through the libc (termios, poll), so it only ships
       for Linux and macOS. Under Windows, use WSL." ;;
  *) err "unsupported operating system: $os" ;;
esac
case "$arch" in
  x86_64|amd64)  cpu="x86_64" ;;
  arm64|aarch64) cpu="aarch64" ;;
  *) err "unsupported architecture: $arch" ;;
esac
target="${cpu}-${suffix}"
asset="raycode-${target}.tar.gz"

# --- Resolve the download URL -------------------------------------------------
if [ -n "${RAYCODE_VERSION:-}" ]; then
  base="https://github.com/$REPO/releases/download/$RAYCODE_VERSION"
  version="$RAYCODE_VERSION"
else
  base="https://github.com/$REPO/releases/latest/download"
  version="latest"
fi
url="$base/$asset"

info "raycode · $target · $version"
info "asset:   $asset"
info "target:  $BIN_DIR"

if [ -n "${RAYCODE_DRY_RUN:-}" ]; then
  info "DRY RUN — url: $url"
  exit 0
fi

# --- Download -----------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  dl() { curl -sSfL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
else
  err "'curl' or 'wget' is required"
fi
command -v tar >/dev/null 2>&1 || err "'tar' is required"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "downloading…"
dl "$url" "$tmp/$asset" || err "could not download $url
       is there a Release with that asset? See https://github.com/$REPO/releases"

# --- Verify the checksum, when both the asset and a hashing tool are there ----
if dl "$url.sha256" "$tmp/$asset.sha256" 2>/dev/null; then
  expected="$(cut -d' ' -f1 <"$tmp/$asset.sha256")"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$tmp/$asset" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)"
  else
    actual=""
    warn "no 'sha256sum' nor 'shasum': checksum not verified"
  fi
  if [ -n "$actual" ]; then
    [ "$actual" = "$expected" ] || err "checksum mismatch for $asset
       expected: $expected
       actual:   $actual"
    info "checksum ok"
  fi
else
  warn "the release publishes no .sha256 for this asset: checksum not verified"
fi

info "extracting…"
tar -xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/raycode" ] || err "the package does not contain 'raycode'"

# --- Install ------------------------------------------------------------------
mkdir -p "$BIN_DIR"
install -m 0755 "$tmp/raycode" "$BIN_DIR/raycode" 2>/dev/null || {
  cp "$tmp/raycode" "$BIN_DIR/raycode"; chmod 0755 "$BIN_DIR/raycode";
}

# macOS quarantines anything downloaded by curl; strip it so Gatekeeper does not
# refuse the first run of an unsigned binary.
if [ "$os" = "Darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -d com.apple.quarantine "$BIN_DIR/raycode" 2>/dev/null || true
fi

info "installed: $BIN_DIR/raycode"

# --- PATH guidance ------------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*) info "run 'raycode' from any directory" ;;
  *) printf '\n\033[1;33mnota:\033[0m %s no está en tu PATH. Añádelo a tu shell:\n  export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR" ;;
esac
