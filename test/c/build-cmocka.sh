#!/bin/sh
# Build the cmocka that `zig build ctest` links against, from the upstream
# release tarball and against this host's glibc.
#
# Why this exists: the packaged cmocka on this host is a Nix build whose glibc
# is newer than the running one (it needs GLIBC_ABI_GNU2_TLS, glibc >= 2.42;
# this host is 2.40), so a suite linked against it cannot even start. The gate
# therefore needs a cmocka compiled here. `test/c/README.md` records the trap;
# this script is the part that makes the fix repeatable rather than a thing
# somebody did by hand once.
#
# Usage:
#   test/c/build-cmocka.sh [<prefix> [<work-dir>]]
#
# The prefix defaults to a **sibling of this repository**, which is the same
# convention `devenv.nix` uses for the read-only reference checkout
# (`devenv.nix:12-17`): a dependency the repository does not vendor lives next
# to the repository, derived from its location rather than written down. So
# there is no `/home/<someone>/...` here to go stale, and the checkout keeps
# working wherever it is cloned. Override it by passing a prefix.
#
# The tarball hash is pinned below and checked on every run. It is the hash
# in the nixpkgs derivation for this version
# (`pkgs/by-name/cm/cmocka/package.nix`, `src.hash = "sha256-OfkvNmvfPxoCr02nW0pcUt9sn35zbH1l3hMoP58O9BY="`,
# which is base64 for 39f92f36...416), so the bytes here are the bytes a
# reproducible build would fetch.
#
# Two things this does NOT do, both deliberate:
#
#   * It applies no patch. nixpkgs carries `uintptr_t.patch` for cmocka, which
#     only adds `#include <stdint.h>` and `#define HAVE_UINTPTR_T 1` to
#     `include/cmocka.h` because the 1.1.x sources are inconsistent about it.
#     cmocka 2.0 includes `<stdint.h>` itself and probes `uintptr_t` in
#     `ConfigureChecks.cmake`, so on this host the patch is a no-op and the
#     bytes built are the tarball's.
#   * It does not run cmocka's own test suite (`-DUNIT_TESTING=ON`, which
#     nixpkgs turns on for `doCheck`). The gate that matters here is `zig build
#     ctest`, and building cmocka's tests buys nothing: they would be compiled
#     by this host's compiler either way, so a failure would have been visible
#     in the suite that uses the library.

set -eu

VERSION=2.0.2
URL="https://cmocka.org/files/2.0/cmocka-${VERSION}.tar.xz"
SHA256=39f92f366bdf3f1a02af4da75b4a5c52df6c9f7e736c7d65de13283f9f0ef416

# `dirname $0` is <repo>/test/c, so two levels up is the build root.
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PREFIX=${1:-$(dirname "$REPO_ROOT")/cmocka-prefix}
WORK=${2:-$(dirname "$REPO_ROOT")/cmocka-build}

TARBALL="$WORK/cmocka-${VERSION}.tar.xz"

echo "cmocka ${VERSION}"
echo "  tarball  ${URL}"
echo "  prefix   ${PREFIX}"
echo "  work     ${WORK}"

mkdir -p "$WORK"

if [ ! -f "$TARBALL" ]; then
    echo "fetching ${URL}"
    curl -fsSL --retry 3 -o "$TARBALL.part" "$URL"
    mv "$TARBALL.part" "$TARBALL"
fi

# `sha256sum -c` is the check, and it is the whole check: a tarball whose hash
# does not match is not built, so a tampered or substituted download cannot
# reach the linker.
echo "${SHA256}  ${TARBALL}" | sha256sum -c -

SRC="$WORK/cmocka-${VERSION}"
rm -rf "$SRC" "$WORK/build-$VERSION"
mkdir -p "$SRC"
tar -xf "$TARBALL" -C "$SRC" --strip-components=1

cmake -S "$SRC" -B "$WORK/build-$VERSION" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=ON \
    -DUNIT_TESTING=OFF \
    -DWITH_EXAMPLES=OFF
cmake --build "$WORK/build-$VERSION" --parallel
cmake --install "$WORK/build-$VERSION"

# Say what to do next, because the point of this script is that the gate works
# afterwards.
echo
echo "installed:"
ls -1 "$PREFIX/lib" "$PREFIX/lib64" 2>/dev/null || true
echo
echo "glibc symbols the installed library needs (must top out below this host's 2.40):"
for lib in "$PREFIX"/lib/libcmocka.so* "$PREFIX"/lib64/libcmocka.so*; do
    [ -f "$lib" ] || continue
    echo "  $lib"
    objdump -T "$lib" 2>/dev/null | sed -n 's/.*GLIBC_\([0-9.]*\).*/    GLIBC_\1/p' | sort -uV | tail -3
done
echo
echo "run the gate with:"
echo "  zig build ctest -Dcmocka-prefix=$PREFIX"
