# RNDIS Tether for macOS

An optional native SwiftUI control panel and menu-bar item for this fork. The
existing C daemon remains independent of the GUI. macOS 13 or newer, Intel and
Apple silicon. The packaged app does not require Python, Homebrew, or Xcode.

## Author and upstream project

The original [rndis-tether](https://github.com/stlk0/rndis-tether) USB tethering
daemon is by [stlk0](https://github.com/stlk0), Copyright (c) 2026 stlk0, under
the [MIT License](../LICENSE). This independent fork by
[zishuai-hao](https://github.com/zishuai-hao) adds Xiaomi USB matching, IPv6 routing
hooks and this native GUI. These additions are not an official upstream release.
The app bundles the original license as `Contents/Resources/LICENSE.txt` and
shows upstream attribution in its window and macOS About panel.

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
**Probe public HTTPS** additionally probes `https://www.cloudflare.com/` and
`https://www.baidu.com/` concurrently. Each result is shown separately; at least
one successful TLS-verified HTTPS response confirms the phone's IPv6 HTTPS exit.
These probes use the phone interface's scoped DNS to obtain public AAAA records,
pin the selected address and bind curl to the USB interface. Hostname SNI and TLS
certificate verification remain enabled; Wi-Fi or a proxy cannot provide a false
positive. Probes never change routes/DNS and only run on request, without credentials.
VPN benchmark/fake-IP answers are rejected. Missing phone DNS is reported explicitly.
The configured targets are checked separately for DNS and /128 routes; their HTTPS
services are not tested by the public probes. DNS changes are effective after saving.
Diagnostics fail if target routing fails or both public probes fail.

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

Version 0.1.2 fixes DNS bootstrap on Macs whose primary network is IPv4. Darwin
implicitly treats zero `getaddrinfo` flags as `AI_DEFAULT` / `AI_ADDRCONFIG` and
can filter IPv6 answers before phone host routes are ready. The native lookup now
uses `AI_UNUSABLE` to obtain AAAA records independently of current reachability,
as documented in [Apple's getaddrinfo manual](https://github.com/apple-oss-distributions/Libinfo/blob/main/lookup.subproj/getaddrinfo.3).
Saved settings and unapplied drafts are identified separately in diagnostics.
The installer explicitly reconciles routes after restarting the daemon, because
startup hooks can run while its installation lock is still held.

For opt-in real-system validation, run `make check-gui-dns`. Set `GUI_DNS_TARGET`
and `GUI_DNS_SERVER` to compare the real helper's lookup against a control DNS
query; the chosen scoped DNS must already be applied to macOS. Set
`GUI_REQUIRE_SAVED=yes` to verify the persisted configuration and
`GUI_REQUIRE_HTTPS=yes` to require a working route and a public USB HTTPS probe too.
A DNS-only pass never implies successful route/HTTPS acceptance. These are
development tests; the application itself does not require Python.

Version 0.1.3 additionally writes `flags a aaaa` to each GUI-owned domain resolver.
Without explicit flags, macOS can inherit A-only query policy from an IPv4 primary
network even when a phone-specific IPv6 host route exists. Enabling AAAA on only
these domain resolvers lets ordinary clients resolve the configured destinations
without making the phone the default IPv6 network. The syntax is implemented by
[Apple's resolver-file parser](https://github.com/apple-oss-distributions/configd/blob/main/dnsinfo/dnsinfo_flatfile.c).
Reapply settings after updating to migrate existing GUI-owned files. A diagnostic
failure is shown separately from successful configuration persistence.

Version 0.1.5 replaces per-target HTTPS requests with the two public probes above.
Target-server availability and phone Internet availability are reported separately.
This diagnostics update does not change persisted settings or routing policy.

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

No telemetry, updater, public DNS default, private server address, or credentials
are bundled. The two documented public HTTPS probe destinations are built in.
