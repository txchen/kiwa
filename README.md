# Kiwa

Kiwa is a lightweight terminal multiplexer with a persistent sidebar. It is
written in Zig 0.16 and uses Ghostty's `ghostty-vt` module as the terminal
engine for each pane. See `GLOSSARY.md` for vocabulary and `docs/adr/` for
the main decisions.

## Build

Zig is pinned in `mise.toml`. Run every command through mise:

```sh
mise exec -- zig build                          # Debug build, zig-out/bin/kiwa
mise exec -- zig build -Doptimize=ReleaseSmall  # static, stripped release binary
```

The default target is static `x86_64-linux-musl`. A cold build takes about
3 minutes per optimize mode because ghostty-vt compiles with Kiwa. Do not use
`--watch` or `-fincremental`; Zig 0.16 incremental compilation crashes on
this project.

## Test

```sh
mise exec -- zig build test   # unit tests for the pure modules
mise exec -- zig build e2e    # end-to-end tests against the built kiwa binary
```

The end-to-end harness runs each client under a PTY it owns and models the
outer terminal with ghostty-vt. Every test sets a private `KIWA_SOCKET` and
`KIWA_STATE_DIR` under a temporary directory, so it never touches a running
Kiwa session.

## Benchmark

```sh
mise exec -- zig build bench -Doptimize=ReleaseFast
```

`tools/bench.py` compares Kiwa with tmux. Each runs attached in its own PTY
at 100x40 with `/bin/sh`, for an idle pane, a 60 Hz one-cell spinner, and
30 lines/s of output. It reports server plus client CPU and the bytes that
reach the outer terminal. tmux runs only as `tmux -L kiwa-bench-<pid>-<n>
-f /dev/null`, and Kiwa uses a private `KIWA_SOCKET` and `KIWA_STATE_DIR`,
so the benchmark never touches a running session. Pass options after `--`,
for example `-- --runs 5`.

## Run

```sh
kiwa              # attach, starting the server if needed
kiwa kill-server  # stop the server and its panes
kiwa --version    # version and pinned Ghostty commit
```

`ctrl+b q` detaches. `ctrl+b ctrl+b` sends `ctrl+b` to the pane.

`KIWA_SOCKET` overrides the socket path (default
`$XDG_RUNTIME_DIR/kiwa/default.sock`, or `/tmp/kiwa-<uid>/default.sock`).
`KIWA_STATE_DIR` overrides the state directory (default
`$XDG_STATE_HOME/kiwa/default`, or `~/.local/state/kiwa/default`), which
holds `server.log`.
