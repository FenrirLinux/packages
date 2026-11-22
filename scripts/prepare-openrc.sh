#!/usr/bin/env bash
# ==============================================================================
# Fetch Artix's current openrc packaging and turn it into Fenrir's build:
# the same package, compiled with branding "Fenrir Linux" so the boot screen
# says "OpenRC ... is starting up Fenrir Linux" instead of Artix Linux.
#
#   ./scripts/prepare-openrc.sh <output-dir>
#
# pkgrel gets a ".1" suffix (e.g. 0.63-1 -> 0.63-1.1) so ours is newer than
# the Artix build it came from. When Artix releases a new version, CI
# notices the new version and rebuilds.
# ==============================================================================

set -euo pipefail

OUT=${1:?usage: prepare-openrc.sh <output-dir>}
BRANDING='Fenrir Linux'
ARTIX_GIT=${ARTIX_GIT:-https://gitea.artixlinux.org/packages/openrc.git}

[[ ! -e $OUT ]] || { echo "$OUT already exists; pass a new directory" >&2; exit 1; }
git clone --quiet --depth 1 "$ARTIX_GIT" "$OUT"
cd "$OUT"
[[ -f PKGBUILD ]] || { echo "no PKGBUILD in $ARTIX_GIT" >&2; exit 1; }

# 1. Branding. Artix may already pass -Dbranding=...; replace it, otherwise
#    add it to the meson call.
if grep -q -- '-Dbranding=' PKGBUILD; then
    # Value may be "double quoted" (with \" escapes), 'single quoted' or bare.
    BRANDING="$BRANDING" perl -pi -e \
        's/-Dbranding=("(?:\\.|[^"\\])*"|\x27[^\x27]*\x27|[^\s)]+)/-Dbranding=\x27"$ENV{BRANDING}"\x27/' PKGBUILD
elif grep -qE '^[[:space:]]*(local[[:space:]]+)?_?meson_?opt(ion)?s=\(' PKGBUILD; then
    sed -i -E "0,/^([[:space:]]*(local[[:space:]]+)?_?meson_?opt(ion)?s=\()/s||\1\n    -Dbranding='\"${BRANDING}\"'|" PKGBUILD
elif grep -qE '(artix-meson|arch-meson|meson setup)' PKGBUILD; then
    sed -i -E "0,/(artix-meson|arch-meson|meson setup)/s|(artix-meson\|arch-meson\|meson setup)|\1 -Dbranding='\"${BRANDING}\"'|" PKGBUILD
else
    echo "Don't know where to add -Dbranding in Artix's openrc PKGBUILD:" >&2
    grep -n 'meson' PKGBUILD >&2 || true
    exit 1
fi
grep -q -- "-Dbranding='\"${BRANDING}\"'" PKGBUILD || { echo "branding patch failed" >&2; exit 1; }

# 2. Version: one step newer than the Artix build.
sed -i -E 's/^pkgrel=([0-9]+)$/pkgrel=\1.1/' PKGBUILD
grep -qE '^pkgrel=[0-9]+\.1$' PKGBUILD || { echo "pkgrel patch failed" >&2; exit 1; }

# Keep the maintainer line honest.
sed -i "1i # Fenrir Linux: Artix's openrc package, rebuilt with branding \"${BRANDING}\"." PKGBUILD

echo "==> Patched openrc PKGBUILD:"
grep -nE 'pkgver=|pkgrel=|-Dbranding' PKGBUILD
