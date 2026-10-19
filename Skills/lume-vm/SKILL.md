---
name: lume-vm
description: "Run Ducko UI work inside a disposable Lume macOS VM instead of on the host desktop: start and stop the VM, run commands in its logged-in GUI session (Accessibility, screencapture, posted CGEvents, open), switch Light/Dark, and copy builds in and captures out. Use when a UI run would otherwise move the real pointer, bring windows to the front, flip the host's appearance, or capture whatever is on the host screen: demo-screenshots reference captures, smoke tests, ducko-ui end-to-end runs, or when the user asks to \"use the VM\", \"run it in the VM\", \"start the Lume VM\", or \"rebuild the VM\"."
---

# Lume UI-Test VM

A disposable macOS VM for UI automation that must not touch the host desktop. Everything goes through `scripts/vm.sh` on the host. Run it with `zsh`, since Bash cannot set the executable bit under `Skills/`. Run it outside the Bash sandbox too, because `lume` and its SSH connection need that.

```sh
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }
vm start
vm gui 'screencapture -x /tmp/s.png'
vm stop
```

Define `vm` in every Bash call that uses it, since shell functions do not carry over between calls.

## The VM

| | |
|---|---|
| Name, storage | `ducko` in lume's `home` storage (`~/.lume`) |
| System | macOS 27.0.1 (26A434); 6 CPUs, 12 GB; user `lume`, password `lume`, auto-login |
| Display | 2880×1800 pixels, 1440×900 points, backing scale 2.0 |
| Tools | Xcode at `/Applications/Xcode.app`, copied from the host and selected with `xcode-select`, and the Command Line Tools (Swift 6.4, Python 3.9.6). The Peekaboo CLI and Peekaboo.app, copied from the host's installs. The CLI gives the same results whether or not the app runs |
| Desktop | Light appearance, solid `Stone` wallpaper, no hot corners, no desktop widgets, click-wallpaper-to-show-desktop off, host time zone, no screen saver or sleep, update checks and Spotlight indexing off |
| Security | SIP off, so `provision` can write TCC grants; passwordless `sudo`. The published `lume` login and the whole-checkout share are accepted for this local VM |

Python in the VM is 3.9: keep scripts meant to run there free of `match` and of `X | None` annotations evaluated at runtime.

## Commands

| Command | Does |
|---|---|
| `start` | Boot headless and wait for the GUI session. Shares the repo **read-only** and `.build/vm-exchange` read-write |
| `stop` | Shut the guest down, then end the VM process |
| `status`, `view` | Show the lume state; open a viewer window to watch (the user can run it with `!`) |
| `sh '<cmd>'` | Run in an SSH shell, in a Background session |
| `gui '<cmd>'` | Run in the GUI session as `lume`, in a login `zsh` started in the home folder |
| `sync` | Copy the working tree into `/Users/lume/work/ducko`, the VM's build folder, keeping its `.build` folders. Refuses when the VM was started from another checkout |
| `ui <script> [args]` | `sync`, then run a `Skills/ducko-ui/scripts` script from the build folder in the GUI session, passing `DUCKO_PROFILE` through |
| `itest [swift test args]` | `sync`, package the debug app, then run `swift test --package-path IntegrationTests` in the build folder; `--filter UILayer` unless the arguments name a filter |
| `push <host> <guest>`, `pull <guest> <host>` | Copy a file or bundle in or out through the exchange folder |
| `screenshot <host png>` | Capture the whole VM screen |
| `appearance light\|dark` | Switch the system appearance |
| `allow` | Press Allow on pending consent alerts |
| `ax list`, `ax press <process> <title>` | List or press buttons and menu items in any app's windows |
| `provision` | Reapply the setup; safe to re-run |

`sh` and `gui` pass the remote exit status through. Remote stderr arrives on stdout. Commands run without a timeout; set `DUCKO_VM_TIMEOUT=<seconds>` to bound one. A call cut by that timeout leaves its remote command running, so check with `pgrep -f` on part of the command that it has finished before running it again.

Inside the VM, the shares are at:

- `/Volumes/My Shared Files/<checkout folder name>/`: the repo, read-only, so scripts run straight from it.
- `/Volumes/My Shared Files/vm-exchange/`: the host's `.build/vm-exchange/`.

Shares are fixed when the VM boots, so start it from the checkout whose files you need. Only one session can use the VM at a time. `start` records the checkout it booted from, and `sync` refuses to copy from any other. That refusal most likely means the VM serves another session, so wait for it or ask the user. Restart it from this checkout (`vm stop && vm start`) only once the user confirms it is free.

## Running work in the GUI session

- **Permissions.** TCC charges every `sh` and `gui` command to the sshd binaries, which hold Screen Recording, Accessibility and event posting. A freshly rebuilt tool needs no new grant.
- **`gui` versus `sh`.** On this build, capture, AX reads, posted events and `open` work from both. A process executed directly from `sh`, though, lives in the Background session, so launch apps and anything they spawn through `gui`.
- **Swift tools.** Compile on the host into `.build/vm-exchange/bin/` under a new name whenever the source changes, then run it from `/Volumes/My Shared Files/vm-exchange/bin/` through `gui`. A rebuild under the same name can be read stale through the share (see Pitfalls), so `vm.sh` names its own helpers `<tool>-<first 12 hex digits of the source's SHA-256>`. The VM's `swiftc` works too.
- **ducko-ui scripts.** `vm ui ducko-launch.sh` builds and launches the `DuckoUITest` copy inside the VM, and every other script then runs as `vm ui <script> [args]` (see the `/ducko-ui` skill). The scripts run only in the VM, or on the host with `DUCKO_UI_HOST=1`, which is only for when the user asks for a run on their Mac. `ui` sets `DUCKO_UI_OUTPUT_DIR` to the exchange folder's `ducko-ui/`, so `ducko-screenshot.sh <name>.png` lands in the host's `.build/vm-exchange/ducko-ui/`.
- **Integration tests.** The `UILayer` suites that `vm itest` runs by default skip on the host without `DUCKO_UI_HOST=1`. `sync` copies `IntegrationTests/.env.test` into the build folder with the rest of the tree. In a linked worktree that file is a symlink into the main checkout, which the VM cannot resolve, so `sync` pushes the file it points to instead. A VM run and a host run of the integration suites must not overlap, since both use the same live accounts.
- **The app.** Copy a host build onto the VM's disk, for example `vm push "$WORK/DuckoDemo.app" /Users/lume/work/DuckoDemo.app`, and keep work folders on the VM's disk rather than on a share. Launch it through `gui` with the usual environment, such as `DUCKO_PROFILE=… /Users/lume/work/DuckoDemo.app/Contents/MacOS/DuckoApp`.
- **Sparkle's prompt.** From its second launch under a bundle ID whose defaults hold no answer, a packaged Ducko opens with Sparkle's "Check for updates automatically?" prompt, which holds back the Welcome window. `provision` answers it for `im.ducko`, the integration suites' bundle. Answer it for another bundle ID with `vm sh 'defaults write <bundle id> SUEnableAutomaticChecks -bool false'`, or set `SUEnableAutomaticChecks` to false in the copy's `Info.plist`, as the demo and `DuckoUITest` copies do.
- **Where a script runs.** `sysctl -n kern.hv_vmm_present` prints `1` in the VM and `0` on the host.
- **Long-running processes.** A background job such as the stub server or the app keeps the SSH call open as long as it holds the call's output. Detach it with `nohup <cmd> >/path/log 2>&1 &`, or launch apps with `open`.
- **Automation consent.** The first Apple Event to each target app raises an Allow alert, which stalls `osascript` until answered. Run `vm allow` from a second shell while the call waits, and the call goes on. A call bounded by `DUCKO_VM_TIMEOUT` that timed out is still waiting in the VM, so `vm allow` lets it finish; don't repeat it. The answer persists, and System Events and Finder are already allowed. The user TCC database stays unreadable even with SIP off, so these grants cannot be written in advance.

## Updating Xcode

`provision` copies Xcode in only when the VM has none, since any Xcode that builds Ducko will do. To move the VM to the host's newer Xcode, run `vm sh 'sudo rm -rf /Applications/Xcode.app'`, then `vm provision`.

## Creating the VM from scratch

The VM has no baseline copy, so starting fresh means rebuilding it. That is needed when the VM is gone, when its state has drifted past what `provision` repairs, or when a new macOS build is wanted. Delete the old VM first with `lume delete ducko --storage home --force`.

1. Get the IPSW URL with `lume ipsw`, then download it with `curl -fL -C -`. The 27.0.1 image is 26.6 GB. `lume create` installs into a temporary folder in its default storage, `~/.lume`, and the finished VM takes about 30 GB, so check free space where the image goes and in `~/.lume`.
2. `lume create ducko --storage home --ipsw <file> --unattended tahoe --cpu 6 --memory 12 --disk-size 80 --display 2880x1800`
3. Turn off SIP. This needs the user: `lume sip off` cannot read a German Recovery. Have them run `lume run ducko --storage home --recovery-mode true`, choose Options, then Utilities › Terminal (Dienstprogramme › Terminal), run `csrutil disable` with `lume`/`lume`, and shut down.
4. `vm start`, then `vm provision`.
5. Walk Setup Assistant, which reopens at every login until finished. Quitting it logs the session out instead. Read the buttons with `vm ax list`, check each page with `vm screenshot`, and press `vm ax press "Setup Assistant" "<title>"` through: Not Now (Accessibility), Other Sign-In Options, Sign in Later in Settings, Skip, Adult, 18 or older, Continue (analytics left unchecked), Not Now and Continue (FileVault), Only Download Automatically, Continue (Liquid Glass), Get Started.

## Pitfalls

- `lume run --shared-dir path:ro` mangles the path (`…/ducko:ro` becomes `…/duckoo`). `vm.sh` passes `path/:ro`.
- The guest cannot resolve relative symlinks read straight off a share (`Too many levels of symbolic links` on a framework's `Versions/Current`). Copy bundles with `push`, which sends folders as one `ditto` archive, rather than running them from the share.
- After the host replaces a file, as editors do on save, the share can answer the next lookup of it with the old file. That lookup refreshes it, so the one after sees the new file. `sync` walks the tree once with a dry run before copying. Read a just-edited file twice when reading it off the share some other way.
- `lume stop` ends the VM process without a guest shutdown. `vm.sh stop` shuts the guest down first.
- `lume ssh` defaults to a 60 s timeout. `vm.sh` turns it off.
- The Command Line Tools cannot build Ducko: SwiftData's `@Model` fails with "plugin for module 'SwiftDataMacros' not found", which is why `provision` copies Xcode in (3.9 GB, about a minute). Build in the writable copy `sync` keeps, never on the read-only share. Without `.git` there, `package_app.sh` versions the build 0.0.0 build 1, so Sparkle offers the latest release.
- Quitting Setup Assistant, or anything else that ends the login session, leaves the VM at the login window until it reboots: `vm sh 'sudo shutdown -r now'`, then `vm start`.
