#!/usr/bin/env bash
# cross-test profile for zautomerge.
#
# cross-test is ~/.local/bin/cross-test: outside this repository, not vendored,
# not on PATH by default. It is what the house gate's ninth section runs, and
# that section FAILS OUTRIGHT without this file — it refuses a cross-test run
# with "required profile not found" rather than quietly narrowing the matrix —
# so `gate` is only a gate while this file exists and says what it says.
#
# It is discovered at ./cross-test.profile.sh first and ./test/cross-test.profile.sh
# second, and it is SOURCED as trusted bash, not read as data: once in the
# parent and again in every per-target phase worker, which re-sources it on top
# of a snapshot of the parent's own variables. Top-level code here is therefore
# limited to variable and function definitions. No `set -e`, no traps, no `cd`,
# no command output: cross-test runs `set -uo pipefail` and forbids a profile
# from changing shell options, traps, or the working directory.
#
# WHAT THIS FILE DECIDES, AND WHAT IT LEAVES ALONE
# The matrix it names, the concurrency, and the deadlines. Everything about
# WHERE the run happens stays with the caller, and that is deliberate: a
# committed path like /home/tmp2/<user>/cross-out works on exactly one machine,
# and the oracle of that path outlives the checkout it was written for. So this
# file sets no ZIG (the caller's compiler wins, and cross-test probes it
# afterwards anyway), no CROSS_PREFIX (zig-gate passes --output), and no cache or
# TMPDIR (cross-test keeps its own fresh cache under ZIG_GLOBAL_CACHE_DIR when
# the host policy exported one, else under TMPDIR, and refuses an output prefix
# that resolves to /tmp, /var/tmp or /dev/shm on the buildhost hosts). Every one
# of those comes from the shared host policy the gate already sources, so no
# scratch, cache or artifact lands on a small system volume. Command-line flags
# still win over this file: `--timeout 60` really does override the budget
# below, which is the one trap worth naming here.

# The step, not a narrower one. `zig build test` (build.zig:95) is the whole
# per-target subject: the library suite, the fixture corpus read from
# test/fixtures, and every consumer root that imports `zautomerge` by name —
# src/hexane/hexane_test.zig, the eleven `test/*.zig` roots, and the C ABI's own
# Zig sections. Naming `test` rather than leaning on the tool's default is the
# point: a profile that quietly selected a narrower step would turn a
# portability matrix into a compile check. It needs neither cargo nor the
# upstream checkout (build.zig:629-632), which is what makes it runnable for a
# target rather than host-specific.
CROSS_BUILD_STEP=test

# TARGETS - four of cross-test's own 53-platform Zig 0.16.0 tier table. The
# table is inherited, not replaced: CROSS_MATRIX is left untouched, so
# `cross-test --targets '<any platform in the table>'` still reaches every
# other row, and `cross-test --no-profile --list` prints them all with the
# runner this host has for each. These four are the rows this host can actually
# say something about, measured with `cross-test --list` on this checkout:
#
#   x86_64-linux     native (`native`). The host itself, no emulator in the
#                    loop, and the only row whose wall clock means what it
#                    looks like. Every foreign row is this same suite with a
#                    different codegen and ABI underneath it, so it is the row
#                    that says a foreign failure is the port's and not qemu's.
#   aarch64-linux    little-endian 64-bit foreign under qemu_user
#                    (`/bin/qemu-aarch64`). A different ABI for the f64 and
#                    pointer-sized values the column codecs move by hand.
#   powerpc64-linux  BIG-ENDIAN (`/bin/qemu-ppc64`), and the only byte-order
#                    evidence this project has: the host, aarch64-linux and
#                    x86_64-windows are all little-endian. The compatibility
#                    contract in AGENTS.md is encoded bytes — LEB128, the
#                    column order, the change hashes — and a value that reaches
#                    the wire through the host's own byte order is invisible on
#                    every little-endian row. It hid exactly once, and **the
#                    round-trip test could not have found it**:
#                    `ValueDecoder.next`'s float arm and `appendPayload`'s
#                    float arm in src/columnar/encoding.zig wrote and read
#                    `@bitCast` of the payload's eight bytes, so each agreed
#                    with the other on every host and `1.5` went out as
#                    `{0x3f, 0xf8, …}` — `{0, …, 0xf8, 0x3f}` in the
#                    reference. Both arms now spell
#                    `std.mem.readInt`/`writeInt(…, .little)`, as the two
#                    op-column writers already did
#                    (src/columnar/columns.zig:526, src/opset/types.zig:371),
#                    and `a float value column's payload is the reference's
#                    eight little-endian bytes` pins the bytes and feeds the
#                    reader a literal array it did not write. **This row is
#                    what runs that test where it means something**; a green
#                    powerpc64 row is the evidence that the wire bytes do not
#                    depend on the host.
#   x86_64-windows   compile coverage of the Windows ABI and std paths — non-ELF
#                    object output, .exe naming, the win32 side of std — and
#                    nothing else. See CROSS_REQUIRE_RUNNERS below.
TARGETS=(
    x86_64-linux
    aarch64-linux
    powerpc64-linux
    x86_64-windows
)

# Serial by policy, not by luck. One target in flight and one compiler job
# inside it: the gate is run pinned to one core at nice 19, and a matrix that
# opened four targets or N build jobs would buy nothing but four times the
# memory pressure and no wall-clock saving on a machine that is deliberately
# shared. CROSS_BUILD_JOBS is set rather than left to cross-test's ZIG_JOBS
# fallback, because the serial contract is this project's and a caller's
# ZIG_JOBS should not quietly become four.
CROSS_JOBS=1
CROSS_BUILD_JOBS=1

# Deadlines. CROSS_TIMEOUT is the per-runtime budget: on 0.16.0 cross-test
# passes it to the build as `--test-timeout 900s`, so it is the number a
# "timed out after 8m58s" in a per-target log is measured against, and it is
# also the wall clock of the run phase in an artifact profile. 900 rather than
# the tool's 300: the library suite takes minutes on this host before any
# emulation is involved, and qemu_user is slower again, so 300 is a budget
# that measures the harness rather than the port.
#
# CROSS_BUILD_TIMEOUT is the separate, larger deadline around one whole
# target phase — in the standard build mode that phase IS `zig build test
# -Dtarget=…`, so it covers compiling every test root AND running every one of
# them, serially. It therefore has to sit well above CROSS_TIMEOUT rather than
# equal to it: 3600 leaves an hour for a cold compile plus a full suite under
# emulation, and a deadline that fires there is a budget finding to read in the
# logs, never a way to turn a slow run green.
CROSS_TIMEOUT=900
CROSS_BUILD_TIMEOUT=3600

# A target with no runner is compile coverage, not a pass, and not a failure
# either. x86_64-windows has no wine64 on this host, so cross-test records it
# build_only/runtime_unavailable and says so in its summary; CROSS_REQUIRE_RUNNERS
# is what would turn that truthful partial into an error, and the house gate
# does not pass --require-runners. Stating 0 here keeps the policy in the
# project rather than in an unwritten default, so the row cannot be promoted to
# a pass by accident and cannot fail the gate by accident either.
#
# Expected when all runnable rows pass: `status=partial pass=1 fail=0
# build_only=1 partial=2 summary=<path>`. Windows is compile-only, not a pass.
# A timeout can indicate a regression or an insufficient deadline; inspect
# the per-target log rather than classifying it as success.
#
# The two foreign rows are `partial` for a second, host-specific reason worth
# naming so it is not read as a failure. Two of the roots under `test` link libc
# dynamically (test/example_test.zig's root at build.zig:131 and
# src/c_abi_test.zig at build.zig:221), and a dynamically-linked foreign binary
# needs a target-side loader. cross-test supplies one only when
# CROSS_LIBC_RUNTIMES names a directory of them, and the Zig 0.16.0 lib
# directory on this host ships no `libc/runtimes` to name. Its run policy then
# skips exactly those run steps on the qemu_user rows: the binaries are still
# compiled and linked for those targets, only not executed, and cross-test
# records the row `partial` rather than `pass`. CROSS_LIBC_RUNTIMES is
# deliberately left unset here so a host that does have loaders can supply them
# from the environment; nothing in this file can supply them.
CROSS_REQUIRE_RUNNERS=0