# Fenrir Linux packages

The `[fenrir]` pacman repository: the packages that make an Artix system
Fenrir Linux. Built and signed by GitHub Actions and published as the
[`repo` release](https://github.com/FenrirLinux/packages/releases/tag/repo).

| Package | What it does |
|---------|--------------|
| `fenrir-keyring` | Key the repository is signed with |
| `fenrir-base` | Fenrir os-release branding (kept across updates by a pacman hook), adds the Fenrir, Artix lib32, Arch and CachyOS repos to `pacman.conf`, OpenRC service for scx schedulers, gaming sysctl defaults, `fenrir-nvidia-setup` |
| `fenrir-desktop` | PipeWire startup for desktop sessions, Driver Manager, Kernel Switcher, Fenrir Browser (Firefox) defaults |
| `openrc` | Artix's OpenRC, rebuilt so the boot screen says **Fenrir Linux** |

## Using the repository

The Fenrir ISO and `fenrir-install` set everything up. On an existing Artix
system, or by hand:

```bash
# Trust the Fenrir key
curl -LO https://github.com/FenrirLinux/packages/releases/download/repo/fenrir.gpg  # or take it from this repo
sudo pacman-key --add fenrir-keyring/fenrir.gpg
sudo pacman-key --lsign-key 598E705FC472CEE4EEF809E3D05B82361E7C6C0E

# Add the repo ABOVE [system] in /etc/pacman.conf, so Fenrir's openrc wins:
#   [fenrir]
#   Server = https://github.com/FenrirLinux/packages/releases/download/repo

sudo pacman -Syu fenrir-keyring fenrir-base
```

After that, `fenrir-base` keeps `pacman.conf` set up on every update.

Key fingerprint: `598E 705F C472 CEE4 EEF8  09E3 D05B 8236 1E7C 6C0E`

## How builds work

`.github/workflows/build.yml` runs in an Artix container on every push to
`main`, daily, and on demand:

1. downloads the current database from the release
2. builds each package whose version isn't published yet; for `openrc` it
   fetches Artix's latest packaging and patches in `-Dbranding="Fenrir Linux"`
   (`scripts/prepare-openrc.sh`), with pkgrel `N.1` so it's newer than
   Artix's `N`
3. signs packages and database with the key in the `FENRIR_GPG_PRIVATE_KEY`
   secret
4. uploads to the `repo` release and deletes superseded files

To release a change to one of the `fenrir-*` packages, edit it and **bump
`pkgver` or `pkgrel`** in its PKGBUILD; unchanged versions are skipped.
Pull requests build but don't publish.

Because `[fenrir]` comes first in `pacman.conf`, pacman takes `openrc` from
Fenrir even after Artix releases a newer one, until the daily build catches
up (within a day).
