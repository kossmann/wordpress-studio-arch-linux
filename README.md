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

The [daily workflow](.github/workflows/build.yml) runs in an `archlinux:base-devel` container and uses no third-party Actions:

1. [`build.sh resolve`](build.sh) follows Automattic's "latest" link (`appscdn.wordpress.com`) and reads only the first 512 KB of the `.deb` to get the version.
2. If that version is already published, the run stops.
3. Otherwise it downloads the `.deb` and extracts it. It then builds a pacman package from a PKGBUILD it generates itself. That PKGBUILD only copies the vendor files into place and never runs vendor code during the build. The package reproduces what the `.deb` sets up at install time: the setuid `chrome-sandbox`, and `cap_net_bind_service` on the bundled `node`, so custom domains can use ports 80/443.
4. [`ci.sh`](ci.sh) signs the package and the repo database, then uploads them to the [`repo` release](https://github.com/kossmann/wordpress-studio-arch-linux/releases/tag/repo). The release notes record the vendor URL and the `.deb`'s sha256.

## Trust model

The binary is Automattic's own release. Automattic doesn't sign it, so the only check on what comes from them is HTTPS to their CDN. By using this repo you also trust this GitHub repository, its Actions runs and its signing key. Everything that runs is in this repo, so you can read it all.

Not affiliated with Automattic or WordPress.com.

## Maintainer notes

- **Signing key:** repo secret `GPG_PRIVATE_KEY`. The maintainer keeps an offline backup.
- **Force a rebuild:** Actions → *Build WordPress Studio package* → *Run workflow* → tick **force**.
- **Build locally:** `./build.sh resolve`, then `./build.sh build <url> <debver> ./out`.
