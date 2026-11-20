#!/usr/bin/env bash
# CI publish stage. Runs on a plain ubuntu runner in a job that holds the
# signing key and a contents:write token. It deliberately never parses the
# package or vendor content: it checks file names and hashes, signs bytes
# with gpg, and uploads.
#
# Env (from the workflow):
#   GITHUB_REPOSITORY, GH_TOKEN, GPG_PRIVATE_KEY
#   PKGFILE   package file name from the build job (validated below)
#   SRC_URL   vendor URL the build used (for release notes only)
#   OUT       directory holding the downloaded build artifact
set -euo pipefail

REPO_DB="wordpress-studio"
PKG_NAME="wordpress-studio-bin"
TAG="repo"
R=(-R "${GITHUB_REPOSITORY:?}")
: "${GH_TOKEN:?}" "${GPG_PRIVATE_KEY:?}" "${PKGFILE:?}" "${OUT:?}"
log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1. Validate the artifact: exact names, regular files, nothing extra.
[[ "$PKGFILE" =~ ^${PKG_NAME}-[A-Za-z0-9._]+-[1-9][0-9]*-x86_64\.pkg\.tar\.zst$ ]] \
  || die "unexpected package file name: $PKGFILE"
expected=("$PKGFILE" "$REPO_DB.db" "$REPO_DB.files" vendor-debver vendor-deb.sha256)
got=$(cd "$OUT" && find . -mindepth 1 -printf '%P\n' | sort)
want=$(printf '%s\n' "${expected[@]}" | sort)
[[ "$got" == "$want" ]] || die "artifact contents differ from expected:"$'\n'"$got"
for f in "${expected[@]}"; do
  [[ -f "$OUT/$f" && ! -L "$OUT/$f" ]] || die "$f is not a regular file"
done
grep -qxE '[A-Za-z0-9.:~+_-]{1,64}' "$OUT/vendor-debver" || die "bad vendor-debver"
grep -qxE '[0-9a-f]{64}  studio-x64-v[A-Za-z0-9._~+-]+\.deb' "$OUT/vendor-deb.sha256" || die "bad vendor-deb.sha256"

# The database must reference exactly this package's bytes.
pkgsha=$(sha256sum "$OUT/$PKGFILE" | awk '{print $1}')
dbtar=$(mktemp)
gzip -dc "$OUT/$REPO_DB.db" > "$dbtar"   # to a file: grep -q in a pipe can SIGPIPE gzip under pipefail
grep -a -qxF "$pkgsha" "$dbtar" || die "database does not contain the package's sha256"   # -a: tar headers hold NULs
rm -f "$dbtar"

# 2. Sign.
export GNUPGHOME; GNUPGHOME=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME"' EXIT
printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --import
unset GPG_PRIVATE_KEY
fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/{print $10; exit}')
log "signing with $fpr"
for f in "$PKGFILE" "$REPO_DB.db" "$REPO_DB.files"; do
  gpg --batch --yes --local-user "$fpr" --detach-sign --no-armor "$OUT/$f"
done

# 3. Publish: package first, then the database pointing at it, then the
#    vendor-version marker, then remove superseded packages.
gh release view "$TAG" "${R[@]}" >/dev/null 2>&1 \
  || gh release create "$TAG" "${R[@]}" --title "pacman repository" --notes "Initialising."
assets=$(gh release view "$TAG" "${R[@]}" --json assets -q '.assets[].name')

gh release upload "$TAG" "${R[@]}" --clobber "$OUT/$PKGFILE" "$OUT/$PKGFILE.sig"
gh release upload "$TAG" "${R[@]}" --clobber \
  "$OUT/$REPO_DB.db" "$OUT/$REPO_DB.db.sig" "$OUT/$REPO_DB.files" "$OUT/$REPO_DB.files.sig"
gh release upload "$TAG" "${R[@]}" --clobber "$OUT/vendor-debver"
while read -r a; do
  [[ "$a" == *.pkg.tar.zst || "$a" == *.pkg.tar.zst.sig ]] || continue
  [[ "$a" != "$PKGFILE" && "$a" != "$PKGFILE.sig" ]] || continue
  log "removing old asset $a"
  gh release delete-asset "$TAG" "$a" "${R[@]}" --yes
done <<<"$assets"

read -r debsha debname < "$OUT/vendor-deb.sha256"
gh release edit "$TAG" "${R[@]}" --notes "$(cat <<EOF
Unofficial pacman repository for WordPress.com Studio. See the README for setup.

**Current:** \`${PKGFILE%-x86_64.pkg.tar.zst}\`
**Vendor version:** \`$(cat "$OUT/vendor-debver")\`
**Built from:** ${SRC_URL:-$debname}
**Vendor .deb sha256:** \`$debsha\`
**Package sha256:** \`$pkgsha\`
**Signed by:** \`$fpr\`
**Built:** $(date -u +%Y-%m-%dT%H:%MZ) by run ${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-?}
EOF
)"
log "published $PKGFILE"
