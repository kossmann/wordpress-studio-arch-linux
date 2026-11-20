#!/usr/bin/env bash
# CI entry point. Runs as root inside an archlinux:base-devel container.
# Checks the vendor's latest Studio release and, if it isn't published yet,
# builds it, signs it, and publishes it as a pacman repo on the GitHub
# Release tagged "$TAG".
#
# Env:
#   GITHUB_REPOSITORY  owner/repo (set by Actions)
#   GH_TOKEN           token with contents:write (set by Actions)
#   GPG_PRIVATE_KEY    armored, passphrase-less signing key (repo secret)
#   FORCE=true         rebuild even if this version is already published
#   DRY_RUN=1          build and sign locally, skip everything that talks to GitHub
set -euo pipefail

REPO_DB="wordpress-studio"   # the [section] name in pacman.conf
TAG="repo"
PKG_NAME="wordpress-studio-bin"

here=$(cd "$(dirname "$0")" && pwd)
dry() { [[ "${DRY_RUN:-}" == 1 ]]; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[[ -n "${GPG_PRIVATE_KEY:-}" ]] || { echo "GPG_PRIVATE_KEY is not set" >&2; exit 1; }
dry || : "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}"

# makepkg refuses to run as root.
id builder >/dev/null 2>&1 || useradd -m builder
install -o builder -m 755 "$here/build.sh" /home/builder/build.sh
as_builder() { su builder -s /bin/bash -c "$(printf '%q ' "$@")"; }

# 1. What's the latest vendor release?
url="" debver="" pkgver=""
while IFS='=' read -r k v; do
  case "$k" in url) url=$v ;; debver) debver=$v ;; pkgver) pkgver=$v ;; esac
done < <(as_builder /home/builder/build.sh resolve)
[[ -n "$url" && -n "$pkgver" ]] || { echo "could not resolve vendor release" >&2; exit 1; }
pkgfile="$PKG_NAME-$pkgver-1-x86_64.pkg.tar.zst"
log "vendor release: $debver ($url)"

# 2. Already published?
R=(-R "${GITHUB_REPOSITORY:-}")
assets=""
if ! dry; then
  gh release view "$TAG" "${R[@]}" >/dev/null 2>&1 \
    || gh release create "$TAG" "${R[@]}" --title "pacman repository" --notes "Initialising."
  assets=$(gh release view "$TAG" "${R[@]}" --json assets -q '.assets[].name')
  if grep -qxF "$pkgfile" <<<"$assets" && [[ "${FORCE:-false}" != true ]]; then
    log "$pkgfile is already published - nothing to do"
    exit 0
  fi
fi

# 3. Build.
out=/home/builder/out
rm -rf "$out"
as_builder /home/builder/build.sh build "$url" "$debver" "$out"
[[ -f "$out/$pkgfile" ]] || { echo "expected $out/$pkgfile was not produced" >&2; ls -la "$out" >&2; exit 1; }

# 4. Sign the package and (re)create the repo database with just this package.
export GNUPGHOME; GNUPGHOME=$(mktemp -d)
printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --import
fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/{print $10; exit}')
log "signing with $fpr"
gpg --batch --yes --local-user "$fpr" --detach-sign --no-armor "$out/$pkgfile"
repo-add --sign --key "$fpr" "$out/$REPO_DB.db.tar.gz" "$out/$pkgfile"

# repo-add leaves .db/.files as symlinks; release assets must be real files.
up=$(mktemp -d)
cp "$out/$pkgfile" "$out/$pkgfile.sig" "$up/"
for ext in db files; do
  cp -L "$out/$REPO_DB.$ext.tar.gz"     "$up/$REPO_DB.$ext"
  cp -L "$out/$REPO_DB.$ext.tar.gz.sig" "$up/$REPO_DB.$ext.sig"
done
log "repo contents:"; ls -la "$up"

if dry; then
  log "DRY_RUN: not publishing (files in $up)"
  exit 0
fi

# 5. Publish: package first, then the database that points at it, then drop
#    the old package so clients never see a database referencing a missing file.
gh release upload "$TAG" "${R[@]}" --clobber "$up/$pkgfile" "$up/$pkgfile.sig"
gh release upload "$TAG" "${R[@]}" --clobber \
  "$up/$REPO_DB.db" "$up/$REPO_DB.db.sig" "$up/$REPO_DB.files" "$up/$REPO_DB.files.sig"
while read -r a; do
  # Any package other than the current one (also catches the pre-rename studio-* files).
  [[ "$a" == *.pkg.tar.zst || "$a" == *.pkg.tar.zst.sig ]] || continue
  [[ "$a" != "$pkgfile" && "$a" != "$pkgfile.sig" ]] || continue
  log "removing old asset $a"
  gh release delete-asset "$TAG" "$a" "${R[@]}" --yes
done <<<"$assets"

sha=$(awk '{print $1}' "$out/vendor-deb.sha256")
gh release edit "$TAG" "${R[@]}" --notes "$(cat <<EOF
pacman repository for WordPress.com Studio. See the README for setup.

**Current:** \`$PKG_NAME $pkgver-1\`
**Built from:** $url
**Vendor .deb sha256:** \`$sha\`
**Signed by:** \`$fpr\`
**Built:** $(date -u +%Y-%m-%dT%H:%MZ) by run ${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-?}
EOF
)"
log "published $pkgfile"
