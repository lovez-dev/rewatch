# rewatch

Watch files and restart a command when they change. Native notifications with polling fallback, debounce, ignore patterns, optional browser live reload, and process tree cleanup on Windows, Linux, and macOS.

## Installation

Download the archive for your OS and architecture from [GitHub Releases](https://github.com/lovez-dev/rewatch/releases) and add the executable to `PATH`. Windows uses `.zip`; Linux and macOS use `.tar.gz`, with `SHA256SUMS` provided.

To build from source, use the toolchain pinned in `.zigversion`:

```sh
zig build -Doptimize=ReleaseSafe
```

The executable is installed in `zig-out/bin`.

## Usage

Run a command and restart it whenever a watched file changes:

```sh
rewatch -- zig build run
rewatch --watch src --watch build.zig --debounce 200ms -- zig build test
```

Commands run immediately, inherit terminal streams, and wait for a change after exiting; a restart stops the previous process tree first. The `--` separator is required for a CLI command and arguments are passed without shell expansion. Use an explicit shell for shell expressions (`sh -c` or `cmd.exe /c`).

You can also create a `rewatch.toml` in the working directory and run `rewatch`:

```toml
pre-command = [["zig", "fmt", "--check", "src"]]
command = ["zig", "build", "run"]
watch = ["src", "build.zig"]
ignore = ["*.tmp"]
debounce = "150ms"
```

Optional `pre-command` steps run in order before every launch and must all succeed. CLI values override the configuration file; use `--config` for a different file or `--no-config` to disable discovery.

For browser live reload, point the proxy at your application and open its listen address; HTML responses receive a reload script that refreshes after a restart:

```toml
proxy-target = "http://127.0.0.1:8080"
proxy-listen = "127.0.0.1:3000"
```

Try the bundled example with `zig build run -- --watch examples -- zig run examples/heartbeat.zig`, then edit `examples/heartbeat.zig` to trigger a restart.

## Options

Durations are unsigned milliseconds (`150`, `150ms`) or seconds (`2s`); zero is allowed for debounce and stop timeout. Boolean flags accept `=true` or `=false`. Run `rewatch --help` for the built-in reference.

| Option | Default | Meaning |
| --- | --- | --- |
| `--config <path>` | `./rewatch.toml` | Read a TOML configuration file |
| `--no-config` | | Disable automatic discovery |
| `--no-pre-command` | | Skip all configured pre-commands |
| `--proxy-target <origin>` | Disabled | HTTP application origin to forward to |
| `--proxy-listen <IP:port>` | `127.0.0.1:3000` | Browser-facing proxy address |
| `--watch <path>` | `.` | Watch a file or directory; repeatable |
| `--ignore <pattern>` | None | Add an ignore rule; repeatable |
| `--watcher <auto\|poll>` | `auto` | Native notifications with polling fallback, or polling only |
| `--debounce <duration>` | `150ms` | Quiet period after the last change |
| `--poll-interval <duration>` | `300ms` | Delay between polling scans; at least `10ms` |
| `--stop-timeout <duration>` | `2s` | Graceful shutdown deadline before force |
| `--cwd <path>` | Current directory | Base directory for watch paths and the command |
| `-h`, `--help` | | Print usage |
| `--version` | | Print version |

## License

[MIT](LICENSE)
