#!/usr/bin/env bash
# CI build stage. Runs as root in an archlinux:base-devel container, in a job
# that has NO secrets and only a read-only token. It parses the untrusted
# vendor .deb, builds the package and an UNSIGNED repo database, and stages
# them in $GITHUB_WORKSPACE/out for the separate publish job to sign.
#
# Env: FORCE=true  rebuild (with pkgrel+1) even if this vendor version is published
set -euo pipefail

REPO_DB="wordpress-studio"
PKG_NAME="wordpress-studio-bin"
BASE="https://github.com/${GITHUB_REPOSITORY:?}/releases/download/repo"
CURL=(curl -fsSL --proto '=https' --proto-redir '=https' --max-redirs 5)

here=$(cd "$(dirname "$0")" && pwd)
log() { printf '==> %s\n' "$*"; }
out_kv() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

# makepkg refuses to run as root. Use a clean environment for the build user
# (env -i) - belt and braces, since this job is given no secrets anyway.
id builder >/dev/null 2>&1 || useradd -m builder
install -o builder -m 755 "$here/build.sh" /home/builder/build.sh
as_builder() { su builder -s /bin/bash -c "env -i HOME=/home/builder PATH=/usr/bin:/bin LANG=C.UTF-8 $(printf '%q ' "$@")"; }

# 1. Latest vendor release.
url="" debver="" pkgver=""
while IFS='=' read -r k v; do
  case "$k" in url) url=$v ;; debver) debver=$v ;; pkgver) pkgver=$v ;; esac
done < <(as_builder /home/builder/build.sh resolve)
[[ -n "$url" && -n "$debver" && -n "$pkgver" ]] || { echo "could not resolve vendor release" >&2; exit 1; }
log "vendor release: $debver ($url)"

# 2. What's published now? (our own repo, public, over HTTPS)
work=$(mktemp -d)
pub_ver="" pub_debver=""
if "${CURL[@]}" -o "$work/db" "$BASE/$REPO_DB.db" 2>/dev/null; then
  pub_ver=$(tar -xzOf "$work/db" --wildcards "$PKG_NAME-*/desc" 2>/dev/null \
            | awk '/^%VERSION%$/{getline; print; exit}') || true
fi
pub_debver=$("${CURL[@]}" "$BASE/vendor-debver" 2>/dev/null | head -n1) || true
log "published: ${pub_ver:-nothing} (vendor ${pub_debver:-unknown})"

# 3. Decide pkgrel. Same upstream version -> rebuild only if the full Debian
#    version changed (e.g. a new Debian revision) or FORCE, with pkgrel+1, so
#    pacman sees it as an upgrade.
pkgrel=1
if [[ -n "$pub_ver" && "${pub_ver%-*}" == "$pkgver" ]]; then
  same_vendor=false
  [[ "$pub_debver" == "$debver" || -z "$pub_debver" ]] && same_vendor=true
  if $same_vendor && [[ "${FORCE:-false}" != true ]]; then
    log "already published - nothing to do"
    out_kv publish false
    exit 0
  fi
  pkgrel=$(( ${pub_ver##*-} + 1 ))
fi
pkgfile="$PKG_NAME-$pkgver-$pkgrel-x86_64.pkg.tar.zst"
log "building $pkgfile"

# 4. Build, then an unsigned database (signing happens in the publish job).
bout=/home/builder/out
rm -rf "$bout"
as_builder /home/builder/build.sh build "$url" "$debver" "$pkgrel" "$bout"
[[ -f "$bout/$pkgfile" ]] || { echo "expected $bout/$pkgfile was not produced" >&2; ls -la "$bout" >&2; exit 1; }
repo-add "$bout/$REPO_DB.db.tar.gz" "$bout/$pkgfile"

# 5. Stage exactly the files the publish job expects, as regular files.
out="${GITHUB_WORKSPACE:-$PWD}/out"
rm -rf "$out"; mkdir -p "$out"
cp "$bout/$pkgfile" "$out/"
cp -L "$bout/$REPO_DB.db.tar.gz"    "$out/$REPO_DB.db"
cp -L "$bout/$REPO_DB.files.tar.gz" "$out/$REPO_DB.files"
cp "$bout/vendor-deb.sha256" "$out/"
printf '%s\n' "$debver" > "$out/vendor-debver"
ls -la "$out"

out_kv publish true
out_kv pkgfile "$pkgfile"
out_kv url "$url"
