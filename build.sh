#!/usr/bin/env bash
# Repackages Automattic's official WordPress.com Studio .deb as a pacman
# package. No AUR maintainer, no third-party code: the generated PKGBUILD only
# copies the extracted vendor tree into place.
#
#   build.sh resolve                               print url=/debver=/pkgver= for the latest release
#   build.sh build <url> <debver> <pkgrel> <outdir> download that .deb and build the package into <outdir>
set -euo pipefail

# HTTPS only, including every redirect hop.
CURL=(curl -fsSL --proto '=https' --proto-redir '=https' --max-redirs 5)

LATEST_URL="https://appscdn.wordpress.com/downloads/wordpress-com-studio/linux-x64/latest/update"
VENDOR_HOST="appscdn.wordpress.com"

DEB_PKG="studio"                 # Package: field in Automattic's .deb
PKG_NAME="wordpress-studio-bin"  # -bin: repackaged vendor binary (Arch convention)
PKG_DESC="WordPress.com Studio, local WordPress development environment (unofficial repackage of Automattic's .deb)"
PKG_URL="https://developer.wordpress.com/studio/"
PKG_LICENSE="GPL-2.0-or-later"
# Arch equivalents of the .deb's Depends.
PKG_DEPENDS=(
  gtk3 libnotify nss xdg-utils at-spi2-core libdrm mesa libxcb
  libcap polkit ca-certificates alsa-lib hicolor-icon-theme
)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*" >&2; }

# Extract the control file from a (possibly truncated) .deb into $2.
read_control() {
  local deb="$1" dir="$2"
  mkdir -p "$dir"
  ( cd "$dir" && ar p "$deb" control.tar.xz 2>/dev/null | tar -xJ 2>/dev/null ) \
    || ( cd "$dir" && ar p "$deb" control.tar.gz 2>/dev/null | tar -xz 2>/dev/null ) \
    || ( cd "$dir" && ar p "$deb" control.tar.zst 2>/dev/null | tar -x --zstd 2>/dev/null ) \
    || die "could not extract control archive from .deb"
  [[ -f "$dir/control" ]] || die "no control file in .deb"
}

control_field() { awk -F': ' -v f="$1" '$1==f{print $2; exit}' "$2"; }

# pacman pkgver = the Debian upstream version (revision after the last '-'
# dropped), restricted to [A-Za-z0-9._]. A changed Debian revision with the
# same upstream version is not lost: the CI compares the full Debian version
# and bumps pkgrel. Epochs are refused (they'd need a pacman epoch and a ':'
# in the file name, which GitHub release assets can't hold) - handle by hand.
to_pkgver() {
  [[ "$1" != *:* ]] || die "Debian version '$1' has an epoch - not supported automatically"
  local up="$1"; [[ "$up" == *-* ]] && up="${up%-*}"
  printf '%s' "$up" | sed -E 's/[^A-Za-z0-9._]/_/g'
}

check_vendor_url() {
  [[ "$1" == "https://$VENDOR_HOST/"* ]] || die "URL is not on https://$VENDOR_HOST/: $1"
}

# pacman installs package contents as root, so the vendor tree is not copied
# blindly: a tampered .deb must not be able to drop files elsewhere on the
# system (/etc/sudoers.d, /usr/bin/...) or ship extra setuid binaries.
#  - only paths Studio legitimately uses are allowed; anything else aborts
#  - only regular files, directories and symlinks
#  - every setuid/setgid bit and world-writable mode is stripped; the one
#    setuid file Studio needs (chrome-sandbox) is re-added in package()
ALLOWED_PATHS='^usr(/bin(/studio)?|/lib(/studio(/.*)?)?|/share(/applications(/studio\.desktop)?|/pixmaps(/studio\.(png|svg))?|/doc(/studio(/.*)?)?)?)?$'
sanitize_tree() {
  local root="$1" bad
  rm -rf "$root/usr/share/lintian"   # Debian-only metadata
  bad=$(cd "$root" && find . -mindepth 1 -printf '%P\n' | grep -Ev "$ALLOWED_PATHS" || true)
  [[ -z "$bad" ]] || die "vendor .deb contains unexpected paths - refusing to package:"$'\n'"$(head -n 20 <<<"$bad")"
  bad=$(find "$root" -mindepth 1 ! -type f ! -type d ! -type l -printf '%P\n')
  [[ -z "$bad" ]] || die "vendor .deb contains special files: $bad"
  [[ -f "$root/usr/lib/studio/studio" ]] || die "vendor .deb has no usr/lib/studio/studio"
  find "$root" ! -type l \( -perm /6000 -o -perm -0002 \) -exec chmod ug-s,o-w {} +
}

cmd_resolve() {
  local work; work=$(mktemp -d); trap 'rm -rf "$work"' RETURN

  # Resolve "latest" to the concrete versioned URL once, so the version we
  # check and the file we later download cannot differ mid-run.
  local url
  url=$("${CURL[@]}" -r 0-524287 -o "$work/head.bin" -w '%{url_effective}' "$LATEST_URL") \
    || die "could not fetch $LATEST_URL"
  check_vendor_url "$url"

  read_control "$work/head.bin" "$work/control"
  local pkg ver
  pkg=$(control_field Package "$work/control/control")
  ver=$(control_field Version "$work/control/control")
  [[ "$pkg" == "$DEB_PKG" ]] || die "unexpected Package '$pkg' in .deb (expected $DEB_PKG)"
  [[ -n "$ver" ]] || die "no Version in .deb control file"

  printf 'url=%s\ndebver=%s\npkgver=%s\n' "$url" "$ver" "$(to_pkgver "$ver")"
}

cmd_build() {
  local url="$1" debver="$2" pkgrel="$3" outdir="$4"
  check_vendor_url "$url"
  [[ "$pkgrel" =~ ^[1-9][0-9]*$ ]] || die "bad pkgrel '$pkgrel'"
  mkdir -p "$outdir"; outdir=$(cd "$outdir" && pwd)

  local work; work=$(mktemp -d); trap 'rm -rf "$work"' RETURN

  log "downloading $url"
  local final
  final=$("${CURL[@]}" -o "$work/pkg.deb" -w '%{url_effective}' "$url") || die "download failed"
  check_vendor_url "$final"
  local sha; sha=$(sha256sum "$work/pkg.deb" | awk '{print $1}')
  log "vendor .deb sha256: $sha"

  read_control "$work/pkg.deb" "$work/control"
  local got; got=$(control_field Version "$work/control/control")
  [[ "$got" == "$debver" ]] || die "downloaded .deb is version $got, expected $debver"

  log "extracting"
  local build="$work/build"
  mkdir -p "$build/pkgroot"
  ( cd "$work" && ar x pkg.deb )
  local data; data=$(cd "$work" && ls data.tar.* 2>/dev/null | head -n1)
  [[ -n "$data" ]] || die "no data archive in .deb"
  case "$data" in
    *.xz)  tar -C "$build/pkgroot" -xJf "$work/$data" ;;
    *.gz)  tar -C "$build/pkgroot" -xzf "$work/$data" ;;
    *.zst) tar -C "$build/pkgroot" -x --zstd -f "$work/$data" ;;
    *)     tar -C "$build/pkgroot" -xf "$work/$data" ;;
  esac
  rm -f "$work/pkg.deb" "$work/$data"   # free disk space before packaging
  sanitize_tree "$build/pkgroot"

  # The .deb's postinst grants the bundled node CAP_NET_BIND_SERVICE so
  # Studio's proxy can bind 80/443 for custom-domain sites.
  cat > "$build/$PKG_NAME.install" <<'EOF'
_apply() {
  setcap 'cap_net_bind_service=+ep' /usr/lib/studio/resources/bin/node 2>/dev/null || \
    echo 'studio: setcap failed for /usr/lib/studio/resources/bin/node - custom domains on ports 80/443 may not work' >&2
}
post_install() { _apply; }
post_upgrade() { _apply; }
EOF

  local deps="" d
  for d in "${PKG_DEPENDS[@]}"; do deps+="'$d' "; done

  cat > "$build/PKGBUILD" <<EOF
# Generated by build.sh from the vendor .deb - do not edit.
# Vendor .deb: $url
# sha256: $sha
pkgname='$PKG_NAME'
pkgver='$(to_pkgver "$debver")'
pkgrel='$pkgrel'
pkgdesc="$PKG_DESC"
arch=('x86_64')
url="$PKG_URL"
license=('$PKG_LICENSE')
depends=($deps)
provides=('wordpress-studio' 'studio')
conflicts=('wordpress-studio' 'wordpress-studio-git' 'studio')
replaces=('studio')
install='$PKG_NAME.install'
options=('!strip' '!debug' '!emptydirs' '!lto')

package() {
  cp -a "\$startdir/pkgroot/." "\$pkgdir/"
  # chrome-sandbox must be setuid root (the .deb ships it that way).
  chmod 4755 "\$pkgdir/usr/lib/studio/chrome-sandbox"
}
EOF
  log "generated PKGBUILD:"; sed 's/^/    /' "$build/PKGBUILD" >&2

  log "building package"
  ( cd "$build" && PKGDEST="$outdir" makepkg --force --nodeps --noconfirm )

  printf '%s  %s\n' "$sha" "$(basename "$url")" > "$outdir/vendor-deb.sha256"
  log "done: $(cd "$outdir" && ls ./*.pkg.tar.zst)"
}

case "${1:-}" in
  resolve) cmd_resolve ;;
  build)   [[ $# -eq 5 ]] || die "usage: build.sh build <url> <debver> <pkgrel> <outdir>"; cmd_build "$2" "$3" "$4" "$5" ;;
  *)       die "usage: build.sh resolve | build <url> <debver> <pkgrel> <outdir>" ;;
esac
