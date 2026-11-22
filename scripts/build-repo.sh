#!/usr/bin/env bash
# ==============================================================================
# Build the Fenrir Linux pacman repository. Runs in an Artix container (CI).
#
#   FENRIR_GPG_PRIVATE_KEY=... ./scripts/build-repo.sh <out-dir>
#
# - downloads the current repo database from the GitHub release
# - builds every package whose version isn't in the database yet
#   (openrc is re-derived from Artix's latest packaging on every run)
# - signs packages and the database with the Fenrir key
# - writes new packages, the database and keep.txt (every file the repo
#   needs) to <out-dir>, for the publish step to upload
# ==============================================================================

set -euo pipefail

OUT=${1:?usage: build-repo.sh <out-dir>}
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_NAME=fenrir
REPO_URL=${REPO_URL:-https://github.com/FenrirLinux/packages/releases/download/repo}
BUILD_USER=builder
WORK=/tmp/fenrir-build

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root inside the build container"
SIGN=1
if [[ -z ${FENRIR_GPG_PRIVATE_KEY:-} ]]; then
    # Pull requests (especially from forks) don't get secrets: test-build
    # without signing. Unsigned output is never published.
    [[ ${ALLOW_UNSIGNED:-} == 1 ]] || die "FENRIR_GPG_PRIVATE_KEY is not set"
    SIGN=0
    echo "WARNING: no signing key; building UNSIGNED packages (test build only)" >&2
fi
[[ ! -e $WORK ]] || die "$WORK already exists"

# ------------------------------------------------------------------------------
# Build user with the signing key
# ------------------------------------------------------------------------------
msg "Setting up the build user"
pacman -Syu --noconfirm --needed base-devel git perl >/dev/null
id "$BUILD_USER" >/dev/null 2>&1 || useradd -m "$BUILD_USER"
echo "$BUILD_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder
mkdir -p "$WORK/db" "$WORK/src" "$OUT"
chown -R "$BUILD_USER:" "$WORK" "$OUT"

as_builder() { sudo -u "$BUILD_USER" -H "$@"; }

KEY=""
if ((SIGN)); then
    printf '%s\n' "$FENRIR_GPG_PRIVATE_KEY" | as_builder gpg --batch --quiet --import
    KEY=$(as_builder gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
    [[ -n $KEY ]] || die "could not import the signing key"
    msg "Signing with key $KEY"
fi
as_builder tee "/home/$BUILD_USER/.makepkg.conf" >/dev/null <<EOF
${KEY:+GPGKEY=$KEY}
PKGDEST=$WORK/pkgs
PKGEXT=.pkg.tar.zst
EOF
mkdir -p "$WORK/pkgs"; chown "$BUILD_USER:" "$WORK/pkgs"

# ------------------------------------------------------------------------------
# Current database
# ------------------------------------------------------------------------------
msg "Downloading the current repository database"
for f in "$REPO_NAME.db.tar.gz" "$REPO_NAME.files.tar.gz"; do
    if curl -fsSL -o "$WORK/db/$f" "$REPO_URL/$f"; then
        echo "    $f"
    else
        rm -f "$WORK/db/$f"
        echo "    $f: none yet (new repository)"
    fi
done
chown -R "$BUILD_USER:" "$WORK/db"

in_db() {
    # in_db name-version: is this exact package version in the database?
    [[ -f $WORK/db/$REPO_NAME.db.tar.gz ]] || return 1
    bsdtar -tf "$WORK/db/$REPO_NAME.db.tar.gz" | grep -qx "$1/"
}

# ------------------------------------------------------------------------------
# Sources: our packages plus Artix's openrc with Fenrir branding
# ------------------------------------------------------------------------------
for d in "$REPO_DIR"/fenrir-*/; do
    cp -a "$d" "$WORK/src/"
done
"$REPO_DIR/scripts/prepare-openrc.sh" "$WORK/src/openrc"
chown -R "$BUILD_USER:" "$WORK/src"

# ------------------------------------------------------------------------------
# Build what changed
# ------------------------------------------------------------------------------
built=0
# Keyring first: other packages depend on it.
for dir in "$WORK/src/fenrir-keyring" "$WORK/src"/*/; do
    dir=${dir%/}
    [[ -f $dir/.built ]] && continue
    touch "$dir/.built"
    cd "$dir"
    srcinfo=$(as_builder makepkg --printsrcinfo)
    name=$(awk '$1 == "pkgname" {print $3; exit}' <<< "$srcinfo")
    ver=$(awk '$1 == "pkgver" {print $3; exit}' <<< "$srcinfo")
    rel=$(awk '$1 == "pkgrel" {print $3; exit}' <<< "$srcinfo")
    epoch=$(awk '$1 == "epoch" {print $3; exit}' <<< "$srcinfo")
    full="$name-${epoch:+$epoch:}$ver-$rel"

    if in_db "$full"; then
        msg "$full is up to date"
        continue
    fi
    msg "Building $full"
    # Sources signed upstream (e.g. openrc release tags) need their keys.
    while read -r key; do
        as_builder gpg --batch --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key" \
            || as_builder gpg --batch --quiet --keyserver hkps://keys.openpgp.org --recv-keys "$key" \
            || echo "    warning: could not fetch source key $key"
    done < <(awk '$1 == "validpgpkeys" {print $3}' <<< "$srcinfo")
    sign_opt=(--nosign)
    ((SIGN)) && sign_opt=(--sign)
    # Fenrir's own packages only copy files: their runtime dependencies
    # (CachyOS keyring, fenrir-keyring, ...) aren't needed, or even
    # available, in the build container. Real builds (openrc) get theirs.
    deps_opt=(--syncdeps)
    [[ $name == fenrir-* ]] && deps_opt=(--nodeps)
    as_builder makepkg "${deps_opt[@]}" --noconfirm --clean --cleanbuild --force "${sign_opt[@]}"
    built=$((built + 1))
done

# ------------------------------------------------------------------------------
# Database
# ------------------------------------------------------------------------------
shopt -s nullglob
new_pkgs=("$WORK"/pkgs/*.pkg.tar.zst)
if ((${#new_pkgs[@]})); then
    msg "Adding ${#new_pkgs[@]} package(s) to the database"
    repo_sign=()
    ((SIGN)) && repo_sign=(--sign --key "$KEY")
    as_builder repo-add "${repo_sign[@]}" --remove \
        "$WORK/db/$REPO_NAME.db.tar.gz" "${new_pkgs[@]}"
    cp "${new_pkgs[@]}" "$OUT/"
    if ((SIGN)); then
        for p in "${new_pkgs[@]}"; do cp "$p.sig" "$OUT/"; done
    fi
else
    msg "Nothing to build"
fi

# pacman fetches <repo>.db and <repo>.files; release assets can't be
# symlinks, so ship real copies under both names.
for kind in db files; do
    src=$WORK/db/$REPO_NAME.$kind.tar.gz
    [[ -f $src ]] || continue
    cp "$src" "$OUT/$REPO_NAME.$kind.tar.gz"
    cp "$src" "$OUT/$REPO_NAME.$kind"
    if [[ -f $src.sig ]]; then
        cp "$src.sig" "$OUT/$REPO_NAME.$kind.tar.gz.sig"
        cp "$src.sig" "$OUT/$REPO_NAME.$kind.sig"
    fi
done

# Every file the repository needs; the publish step deletes the rest.
{
    for kind in db files; do
        printf '%s\n' "$REPO_NAME.$kind" "$REPO_NAME.$kind.sig" \
            "$REPO_NAME.$kind.tar.gz" "$REPO_NAME.$kind.tar.gz.sig"
    done
    if [[ -f $WORK/db/$REPO_NAME.db.tar.gz ]]; then
        bsdtar -xOf "$WORK/db/$REPO_NAME.db.tar.gz" --include '*/desc' \
            | awk '/^%FILENAME%$/ {getline; print; print $0 ".sig"}'
    fi
} | sort -u > "$OUT/keep.txt"

echo "$built" > "$OUT/built-count"
msg "Done: $built package(s) built"
ls -l "$OUT"
