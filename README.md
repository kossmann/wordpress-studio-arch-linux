# WordPress Studio for Arch Linux

An **unofficial** signed pacman repository for [WordPress.com Studio](https://developer.wordpress.com/studio/),
rebuilt daily from Automattic's official `.deb`. The package is `wordpress-studio-bin`. Once you add it, Studio updates
come with a normal `sudo pacman -Syu`.

## Install

**1. Trust the signing key.** Check that the fingerprint matches before you add it:

```bash
curl -fsSL https://raw.githubusercontent.com/kossmann/wordpress-studio-arch-linux/main/signing-key.asc -o /tmp/wordpress-studio.asc
gpg --show-keys /tmp/wordpress-studio.asc
# fingerprint must be: AE1E8ABA5EEC90606E0E86B4F9C60FBF37447EA3
sudo pacman-key --add /tmp/wordpress-studio.asc
sudo pacman-key --lsign-key AE1E8ABA5EEC90606E0E86B4F9C60FBF37447EA3
```

**2. Add the repo** to the end of `/etc/pacman.conf`:

```ini
[wordpress-studio]
SigLevel = Required DatabaseRequired
Server = https://github.com/kossmann/wordpress-studio-arch-linux/releases/download/repo
```

**3. Install:**

```bash
sudo pacman -Syu wordpress-studio-bin
```

(Always use `-Syu` here. A bare `-Sy <pkg>` is a partial upgrade, which Arch doesn't support.)

If you already have a package called `studio` installed (for example one you built yourself from the `.deb`), the next `-Syu` will offer to replace it with `wordpress-studio-bin`.

After that, updates come in with `sudo pacman -Syu`.

### Uninstall

```bash
sudo pacman -Rns wordpress-studio-bin
```

Then remove the `[wordpress-studio]` section from `/etc/pacman.conf`. To remove the key as well, run
`sudo pacman-key --delete AE1E8ABA5EEC90606E0E86B4F9C60FBF37447EA3`.

## How it works

The [daily workflow](.github/workflows/build.yml) has two jobs. Each runs on its own fresh VM and gets only the permissions it needs:

1. **`build`** runs in an `archlinux:base-devel` container with **no secrets** and a read-only token. This is the only job that handles Automattic's `.deb`.
   - [`build.sh resolve`](build.sh) follows the vendor's "latest" link over HTTPS only (redirects included) and checks that it ends up on `appscdn.wordpress.com`. It reads only the first 512 KB of the `.deb` to get the version.
   - [`ci-build.sh`](ci-build.sh) compares the full vendor version with the one already published. If only the Debian revision changed, or a rebuild was forced, it bumps `pkgrel` so pacman treats it as an upgrade.
   - Before packaging, the vendor file tree is checked against an allowlist: `usr/bin/studio`, `usr/lib/studio/…`, the `.desktop` file, the icon and docs. Anything else, or any special file, aborts the build, so a tampered `.deb` can't install files elsewhere on your system. All setuid/setgid and world-writable bits are stripped. The only one put back is on `chrome-sandbox`.
   - It then builds the package from a PKGBUILD it generates itself. That PKGBUILD only copies the vendor files into place and never runs vendor code. It also builds an **unsigned** repo database.
2. **`publish`** holds the signing key and a write token. [`ci-publish.sh`](ci-publish.sh) never parses the package: it checks file names, confirms the database references the package's sha256, signs the files with gpg and uploads them to the [`repo` release](https://github.com/kossmann/wordpress-studio-arch-linux/releases/tag/repo).

The workflow uses no third-party Actions. GitHub's own artifact actions, pinned to commit SHAs, pass the build from one job to the other. The repository settings enforce this: only GitHub-owned actions are allowed, and they must be pinned to a SHA.

### Privileges the package grants

These copy what Automattic's own `.deb` sets up when it installs:

- `/usr/lib/studio/chrome-sandbox` is **setuid root**. Electron needs this for its sandbox on systems without unprivileged user namespaces.
- `/usr/lib/studio/resources/bin/node` gets **`cap_net_bind_service`**, so Studio's proxy can serve custom domains on ports 80/443. Note that this applies to *any* script run with that `node` binary, which means any local user can bind ports below 1024 through it. If you don't use custom domains, you can remove it with `sudo setcap -r /usr/lib/studio/resources/bin/node`. Each upgrade puts it back.

## Trust model

The binary is Automattic's own release. Automattic doesn't sign it or publish checksums, so the only check on what comes from them is HTTPS to their CDN. By using this repo you also trust this GitHub repository, its Actions runs (including the `archlinux:base-devel` image and Arch's packages used to build) and its signing key. Everything that runs is in this repo, so you can read it all.

Limits worth knowing:
- The publish job signs whatever the build job produced. Isolation keeps the signing key away from vendor content, but it can't detect a build that was tampered with. Only the allowlist above limits what a tampered build could do.
- pacman database signatures don't expire. Someone who could replace this repo's release files could serve an *older* signed database, but they couldn't forge a new one.

Not affiliated with Automattic or WordPress.com.

## Maintainer notes

- **Signing key:** repo secret `GPG_PRIVATE_KEY`. The maintainer keeps an offline backup.
- **Force a rebuild:** Actions → *Build WordPress Studio package* → *Run workflow* → tick **force**.
- **Build locally:** `./build.sh resolve`, then `./build.sh build <url> <debver> 1 ./out`.
