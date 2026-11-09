# RNDIS Tether for macOS

Version 0.2.0 provides an on-demand USB backend and domain-based forwarding through
Clash Verge / mihomo. The application requires macOS 13 or newer and supports Intel
and Apple silicon.

The USB implementation originates from [stlk0/rndis-tether](https://github.com/stlk0/rndis-tether),
Copyright (c) 2026 stlk0, under the [MIT License](../LICENSE). This independent fork by
[zishuai-hao](https://github.com/zishuai-hao) adds Xiaomi USB matching, optional network
hooks and this GUI. The application includes the upstream license and attribution.

## Setup

1. Unzip the application, move it to Applications, and open it.
2. Enter up to eight domain suffixes or IPv6 literals, one per line. A suffix covers
   the domain itself and its subdomains. The optional DNS field sets a Clash DNS
   policy for these domains. Leaving it empty uses Clash's existing DNS servers.
3. Save and export **Clash-USB.js**. It includes the current Clash Verge global script
   and appends a marked RNDIS block. Enable this combined script once in Clash Verge's
   global extension script editor. Export again and update Clash after changing targets.
4. Use Clash's **rule mode** and enable its system proxy. Applications must send their
   traffic through Clash to use these rules. System proxy mode provides domain
   forwarding without requiring Clash TUN route management.
5. Click **Start connection** and complete the macOS administrator prompt. On the
   first run with an older GUI installed, this button reads **Migrate and start**.
6. Connect the Android phone and enable USB tethering. For mobile IPv6, enable mobile
   data and turn off the phone's Wi-Fi when its Wi-Fi uplink lacks IPv6.

The script adds a direct outbound bound to `feth50` with IPv6, a selector named
`RNDIS Tether`, and rules pointing the configured destinations at that selector.
These use mihomo's documented [DIRECT outbound fields](https://wiki.metacubex.one/en/config/proxies/direct/).
The selector initially uses `DIRECT`. Once the phone has IPv6, the GUI switches it to
`RNDIS Tether USB`. Disconnecting or stopping restores the previous selector choice.
The GUI checks every three seconds and handles Clash profile reloads.

The generated DNS configuration adds domain fake-IP exclusions and optional
nameserver policies. Fake-IP blacklist mode and redir-host are supported. Conflicting
proxy/group names and fake-IP whitelist mode are rejected. Global Clash mode bypasses
the domain rules. The controller integration currently supports Clash Verge's local
Unix socket, including its per-user service socket.

## Connection lifetime

Opening the GUI restores user settings. Clicking **Start connection** launches the
bundled privileged USB process for this GUI session. While started, it automatically
detects phone connections and retries after USB reconnects.

Closing the window keeps the menu-bar item and connection active, and hides the Dock
icon. Reopening the control panel restores the Dock icon. **Stop connection** stops
USB networking. **Quit and stop connection** also quits the GUI.

The backend watches its owning GUI process through a kernel process-exit event. GUI
exit, including an unexpected termination, shuts down USB networking and removes its
interfaces and sockets. A separate user process restores the Clash selector after GUI
exit, retrying for up to one minute if Clash is unavailable. An unfinished recovery
journal is retried when the GUI next opens. The backend itself can require cleanup
on the next start if it is forcibly killed.

## Files and privileges

Preferences are stored in the logged-in user's directory with mode 0600.

- `~/Library/Application Support/RNDIS Tether/settings.json` contains targets and DNS.
- `~/Library/Application Support/RNDIS Tether/Clash-USB.js` is the exported combined script.
- `~/Library/Application Support/RNDIS Tether/clash-session.json` records the previous
  selector choice before changing it and is removed after successful recovery.

The root backend uses `/var/db/rndis-tether` for locks and interface ownership, plus
status/control sockets under `/var/run` while running. macOS creates the connected
network's ordinary addresses and routes. The GUI's forwarding policy is implemented
inside Clash. Each start requests standard macOS administrator authorization. The
application never receives or saves the administrator password.

First-run migration snapshots the older installation at
`/var/db/rndis-tether/legacy-backup.json`, stops and removes its launch daemon,
installed executables and settings, and removes resolver files carrying the old GUI's
ownership marker. Stopping the old backend removes its owned interfaces and associated
routes. If startup fails, migration attempts to restore the snapshot. User settings
start fresh in 0.2.0. Enter and save the desired domain suffixes in the new GUI.
The backup and root lock directories remain on disk after stopping.

An administrator can restore the migration snapshot using the bundled helper.

```sh
sudo '/Applications/RNDIS Tether.app/Contents/Resources/rndis-tether-gui-helper' \
  restore-legacy '/Applications/RNDIS Tether.app/Contents/Resources'
```

## Diagnostics

**Check connection** reads the phone IPv6 gateway and Clash selector. **Probe public
HTTPS** concurrently probes Cloudflare and Baidu using the phone's scoped DNS and
USB-bound IPv6 connections, retaining TLS verification. Each result is shown
separately. At least one successful HTTPS response confirms the public USB exit.
These probes test the phone exit. To test domain forwarding, access a configured
destination through Clash. Diagnostic operations are read-only and send no login
credentials.

## Build and verify

```sh
make check             # C tests with UBSan and Guard Malloc
make analyze           # C static analysis
make check-gui         # preferences, real JS execution, Unix controller, probes and resources
make gui               # universal application and ZIP in build/gui/
```

Only macOS system frameworks are required at runtime. The offline GUI integration
tests additionally use Python 3. The local application is ad-hoc signed. Developer ID
signing and notarization are needed for conventional broad distribution.

Offline tests and archive checks cover parsing, controller recovery and packaged
resources. Administrator authorization, phone reconnects, backend cleanup on GUI exit
and real Clash forwarding additionally require installed-app testing with a phone.
