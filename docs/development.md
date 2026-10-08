# Developing Kiwa

[Back to the README](../README.md) · [Benchmark results and methodology](benchmarks.md)

## Build


Zig is pinned in `mise.toml`. Run every command through mise:

```sh
mise exec -- zig build                          # Debug build, zig-out/bin/kiwa
mise exec -- zig build -Doptimize=ReleaseFast   # optimized, stripped release binary
```

The default target is static `x86_64-linux-musl`. A cold build takes about
3 minutes per optimize mode because ghostty-vt compiles with Kiwa. Do not use
`--watch` or `-fincremental`; Zig 0.16 incremental compilation crashes on
this project.

## CI and binary releases

GitHub Actions runs unit tests and PTY end-to-end tests in ReleaseFast on
native Linux x86_64, Linux ARM64, and `macos-15` ARM64 runners, and in Debug
on Linux x86_64 and macOS. Debug keeps runtime safety checks, which do not
depend on the CPU, so one Linux architecture runs it. The Linux Debug job
also checks formatting and the OS layer. Each successful ReleaseFast job
uploads a downloadable archive, so the tested binary is the one a release
ships. Zig is installed from `mise.toml`; Ghostty remains pinned by
`build.zig.zon`.

To publish a release:

1. Set `.version` in `build.zig.zon` (for example, `0.1.0`), commit the
   change and workflows, and push them to `master`.
2. Tag that commit with the matching version and push the tag over HTTPS:

   ```sh
   gh auth setup-git
   git push https://github.com/txchen/kiwa.git master
   git tag -a v0.1.0 -m "Release v0.1.0"
   git push https://github.com/txchen/kiwa.git v0.1.0
   ```

3. The Release workflow rejects a tag that differs from the package
   version. If CI already passed on the tagged commit and its archives
   have not expired, it publishes those archives. Otherwise it runs all CI
   checks first. Either way it publishes a GitHub Release containing
   `kiwa-x86_64-linux-musl.tar.gz`, `kiwa-aarch64-linux-musl.tar.gz`,
   `kiwa-aarch64-macos.tar.gz`, `install.sh`, and `SHA256SUMS`. Tags
   containing a hyphen are marked as prereleases. Publishing requires every
   CI job to pass. Push the version commit to `master` and wait for CI
   before tagging, so the release takes about a minute.

Download the archive for your architecture and `SHA256SUMS` from the same
release. Verify it with `sha256sum --ignore-missing -c SHA256SUMS`, then
extract the archive and install `kiwa` on your PATH. Linux binaries link
musl statically and do not depend on the target machine's glibc version.

Reproduce the release builds locally:

```sh
mise exec -- zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline -Doptimize=ReleaseFast
mise exec -- zig build -Dtarget=aarch64-linux-musl -Dcpu=baseline -Doptimize=ReleaseFast
```

[ReleaseFast](https://ziglang.org/documentation/0.16.0/#ReleaseFast) optimizes
both Kiwa and Ghostty for speed and disables runtime safety checks. Debug CI retains those checks. ReleaseSmall optimizes for
size instead and is not used for published binaries. Release CPU targets
are explicitly `baseline`, avoiding accidental dependence on the CI
runner's CPU instructions. A local build for one known machine can use
`-Dcpu=native`; do not distribute that binary as a generic architecture
release. No compiler mode guarantees the fastest result on every CPU.
Measure changes with `bench-check` on consistent, dedicated hardware
before tagging; shared GitHub runners are too noisy for reliable CPU
performance gates. The benchmark is Linux-only and requires Python 3 and
tmux; its first run also downloads Zellij and Herdr.

### macOS

Kiwa builds for Apple silicon Macs running macOS 13.0 or later. Intel Macs
are not supported. Build and test on a Mac with:

```sh
brew install htop fzf   # the end-to-end tests also need git, Python 3, less, and Vim
mise exec -- zig build test e2e -Dtarget=aarch64-macos.13.0
```

The binary links the system libraries, so it is not a static executable.
Releases publish it as `kiwa-aarch64-macos.tar.gz`. It carries the ad-hoc
signature Zig's linker adds and is not notarized. `install.sh` downloads it
with curl, which sets no quarantine flag, so Gatekeeper does not block it. An
archive downloaded with a browser needs `xattr -d com.apple.quarantine kiwa`.

OS-specific code lives in `src/os/linux.zig` and `src/os/darwin.zig`, and
the test harness's in `tests/os/` (ADR 0005). On Linux,
`zig build check -Dtarget=aarch64-macos.13.0` compiles the macOS binary,
unit tests, and end-to-end tests without running them. A clean compile
means the macOS calls exist in libSystem. It does not show that they
behave, because Zig compiles `std.os.linux` calls for macOS too.
`tools/check-os-layer.sh` fails when Zig code outside the per-OS files
names Linux syscalls or a macOS-only API.

CI runs the unit tests and the functional end-to-end tests natively on
`macos-15` runners, in Debug and ReleaseFast as two parallel jobs. A pass there does not show
that macOS 13 or 14 works, and `zig build e2e-perf` has not run on a Mac.

## Test

```sh
mise exec -- zig build test       # unit tests for the pure modules
mise exec -- zig build e2e        # functional end-to-end tests against the built kiwa binary
mise exec -- zig build e2e-perf   # end-to-end tests that measure cost; run on demand
```

`e2e-perf` holds the cases that measure wakes, context switches, or outer
bytes, or that load the machine on purpose, such as the stalled-client
overflow. Their results depend on the machine, so CI does not run them.
Run them before a change that could affect the event loop or the renderer.
Both steps take a name filter, as in `zig build e2e -- vim`.

Functional cases run in parallel, one per CPU by default, because each has
its own socket, state, and directories. Set `KIWA_E2E_JOBS=1` to run them
one at a time. Perf cases always run one at a time.

The randomized unit tests run a tenth of their cases by default, so a local
`zig build test` stays fast. CI runs all of them with `-Dfuzz=100`; pass the
same flag locally after changing the frame diff or the renderer.

The end-to-end tests require git, Python 3, less, Vim, htop, fzf, and ncurses
utilities/terminfo (CI installs these explicitly).

The end-to-end harness runs each client under a PTY it owns and models the
outer terminal with ghostty-vt. Every test sets a private `KIWA_SOCKET` and
`KIWA_STATE_DIR` under a temporary directory, so it never touches a running
Kiwa session. The e2e step also builds `kiwa-skewed`, whose protocol
version is one higher, to test a client and a server of different versions.
`kiwa __stats` prints the server's debug counters, such as
`renders` and `name_checks`, for tests and benchmarks.
