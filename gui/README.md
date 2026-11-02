# RNDIS Tether for macOS

An optional native SwiftUI control panel and menu-bar item for this fork. The
existing C daemon remains independent of the GUI. macOS 13 or newer, Intel and
Apple silicon. The packaged app does not require Python, Homebrew, or Xcode.

## Using the application

1. Unzip the archive and move **RNDIS Tether.app** to Applications, then open it.
2. Add up to eight destination hostnames or IPv6 literals, one per line. Leave
   **Prefer phone** off to preserve the normal Wi-Fi preference.
3. If necessary, enter a domain-specific DNS server IP. Empty means system DNS;
   only the configured domains receive resolver files. Existing resolver files
   created by another tool are never overwritten.
4. Click **Install and apply** / **Save and apply** and authorize with macOS.
   This replaces an existing rndis-tether service with the bundled version, enables
   IPv6, and configures the GUI's native route hook. Other daemon settings remain.
5. Enable USB tethering on the Android phone. For mobile IPv6, keep mobile data
   enabled and turn the phone's Wi-Fi off if its Wi-Fi uplink does not provide IPv6.

The status panel refreshes every three seconds. **Check routes** is read-only:
it shows the phone's current IPv6 gateway, DNS results and explicit host routes.
It does not test HTTPS, authentication or firewall rules. DNS changes are effective
after saving; the system resolver and its caches determine lookup results.

The background service starts with the Mac and continues when the GUI quits. The
GUI does not need to launch at login for routing to work. Pause is temporary and
is reset by a service restart. Disabling automatic routes and saving removes routes
owned by the GUI; an alternative network can then be selected by macOS.

**Uninstall service** removes the rndis-tether daemon, its configuration and GUI-
owned routes/resolvers. It does not remove the application or hooks/resolvers
installed by other tools. A small root-only lock directory may remain.

## Build and verify

On a development Mac with Xcode Command Line Tools:

```sh
make check-gui  # Swift route-policy/validation tests, no root or phone
make gui        # universal .app and zip in build/gui/
```

Only system frameworks are linked. There are no network package downloads. The
Swift helper replaces the optional Python routing example for the GUI; the daemon
and the Python example remain unchanged.

The local build is ad-hoc signed, without Developer ID or Apple notarization.
For broad distribution, sign all executables and the app with your Developer ID
and notarize the resulting archive. Do not disable Gatekeeper globally. Local
compilation and a resource smoke test do not verify the administrator prompt or
real USB reconnects: those require running the installed app and authorizing it.

Version 0.1.1 fixes system-directory validation for the standard macOS `/var` and
`/etc` symlinks. The helper uses POSIX `realpath` and checks every canonical parent;
Foundation file URLs can return display aliases even after symlink resolution.
`make check-gui` also runs read-only regressions against these actual system paths,
while verifying that writable temporary directories and regular files are rejected.
The packaged helper's `check-system-paths` command runs the same installation
directory checks without root or filesystem changes, and packaging runs it too.

## Privilege boundary

The UI runs as the logged-in user. Status, diagnostics and pause/resume use the
existing CLI; pause/resume require membership in the local administrators group.
Install, save and uninstall invoke the bundled helper through macOS's standard
administrator prompt. No password is read, stored or sent by the app.

The helper revalidates JSON input, accepts only fixed operations and writes to
fixed system locations. Shell and AppleScript quoting are separate; arbitrary
commands are not accepted as configuration. The installed helper is root-owned
and cannot be replaced through writable parent directories. Settings are staged
in the destination directory and atomically renamed. Installation keeps snapshots
of affected files and restores them if the bundled CLI cannot start the service.

Routes remain in the Mac kernel. Network events and the daemon's periodic refresh
invoke the hook; it maintains /128 routes using the current phone gateway, caches
last successful AAAA answers, and checks ownership before stale-route deletion.
DNS requests run in short-lived children with a per-target deadline. Ownership is
checkpointed after each route mutation so a later timeout can be retried safely.
The hook serializes with installation using a root-only lock. Transient DNS failure
preserves previous answers. A matching route belonging to another tool is not
adopted merely because it already points to the phone.

Additional files:

- `/Library/PrivilegedHelperTools/rndis-tether-gui-helper`: native route/install helper.
- `/etc/rndis-tether-gui.json`: GUI settings (root-owned, readable, no passwords).
- `/var/db/rndis-tether-gui/`: root-only ownership state and lock.
- `/etc/resolver/<configured-domain>`: only when explicitly opting into scoped DNS.

No telemetry, updater, public DNS default, server address, or credentials are bundled.
