# RNDIS Tether for macOS

Version 0.2.3 provides an on-demand USB backend and address/port forwarding through
Clash Verge / mihomo. The application requires macOS 13 or newer and supports Intel
and Apple silicon.

The USB implementation originates from [stlk0/rndis-tether](https://github.com/stlk0/rndis-tether),
Copyright (c) 2026 stlk0, under the [MIT License](../LICENSE). This independent fork by
[zishuai-hao](https://github.com/zishuai-hao) adds Xiaomi USB matching, optional network
hooks and this GUI. The application includes the upstream license and attribution.

## Setup

1. Unzip the application, move it to Applications, and open it.
2. Enter up to eight domain suffixes, IPv4/IPv6 addresses or CIDR networks, one per
   line. A suffix covers the domain itself and its subdomains. A destination port or
   port range is optional. Configure DNS and IPv6 through Clash Verge's settings.
   Enable IPv6 name resolution there when using IPv6-only domain services.
3. Click **Save and overwrite script**. This writes a standalone RNDIS script directly
   to Clash Verge's `profiles/Script.js`. It replaces the global extension script.
   Then click **Reactivate subscription** in Clash Verge to generate and load the
   updated runtime configuration. Repeat these two clicks after changing targets.
   **Export script** saves a standalone copy in the user directory.
4. Use Clash's **rule mode** and enable its system proxy. Applications must send their
   traffic through Clash to use these rules. System proxy mode provides domain
   forwarding without requiring Clash TUN route management.
5. Click **Start connection** and complete the macOS administrator prompt. On the
   first run with an older GUI installed, this button reads **Migrate and start**.
6. Connect the Android phone and enable USB tethering. For mobile IPv6, enable mobile
   data and turn off the phone's Wi-Fi when its Wi-Fi uplink lacks IPv6.

Examples of accepted targets follow. Omitting the port matches all destination ports.

```text
example.com
example.com:443
192.0.2.10:9876
192.0.2.0/24:8000-8100
2001:db8::/64
[2001:db8::/64]:443
```

IPv6 targets with ports require brackets. Ports range from 1 to 65535. CIDR host bits
are normalized to the network address. Single IPs produce /32 or /128 rules. An
address and port form a logical `AND` condition, so both must match. CIDR rules use
mihomo's ordinary destination-IP matching, including DNS resolution for requests
carrying a hostname. Rule syntax is documented in [mihomo routing rules](https://wiki.metacubex.one/en/config/rules/).
All these conditions apply to traffic that enters Clash. TCP applications can use
the system HTTP proxy, and supported UDP applications can use Clash's SOCKS inbound.

The script adds a direct outbound bound to `feth50` with IPv4/IPv6 dual stack, a selector named
`RNDIS Tether`, and rules pointing the configured destinations at that selector.
These use mihomo's documented [DIRECT outbound fields](https://wiki.metacubex.one/en/config/proxies/direct/).
The selector initially uses `DIRECT`. Once the USB connection is online, the GUI switches it to
`RNDIS Tether USB`. Disconnecting or stopping restores the previous selector choice.
The GUI checks every three seconds and handles Clash profile reloads.

IPv4 forwarding is available on phones without IPv6. IPv6 destinations require a
working phone IPv6 connection. The generated script adds the RNDIS outbound, selector
and routing rules. DNS, fake-IP filters and top-level IPv6 settings are managed by
Clash Verge. Conflicting proxy/group names are rejected. Global Clash mode bypasses
the domain rules. The controller integration currently supports Clash Verge's local
Unix socket, including its per-user service socket.

Clash Verge 2.5.8 restores fields owned by its settings after scripts run. The script
therefore operates on forwarding configuration, with DNS configured through Verge.
See the [versioned enforcement implementation](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.8/src-tauri/src/enhance/mod.rs#L330)
and the [official extension guide](https://www.clashverge.dev/guide/extend.html).

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

- `~/Library/Application Support/RNDIS Tether/settings.json` contains targets.
- `~/Library/Application Support/RNDIS Tether/Clash-USB.js` is the standalone exported script.
- `~/Library/Application Support/RNDIS Tether/previous-Clash-Script.js` is the last
  replaced global script, saved with mode 0600. Identical repeated saves preserve it.
- `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/Script.js`
  is overwritten by **Save and overwrite script**. The generated function adds the
  RNDIS outbound, selector and target rules to the subscription.
- `~/Library/Application Support/RNDIS Tether/clash-session.json` records the previous
  selector choice before changing it and is removed after successful recovery.

Writing the global script completes the file update. Clash Verge's **Reactivate
subscription** action generates and loads its runtime configuration. The GUI reports
these as separate steps. File-write failures are shown separately from saved user settings.

The root backend uses `/var/db/rndis-tether` for locks and interface ownership, plus
status/control sockets under `/var/run` while running. macOS creates the connected
network's ordinary addresses and routes. The GUI's forwarding policy is implemented
inside Clash. Each start requests standard macOS administrator authorization. The
application never receives or saves the administrator password.

First-run migration snapshots the older installation at
`/var/db/rndis-tether/legacy-backup.json`, stops and removes its launch daemon,
installed executables and settings, and removes resolver files carrying the old GUI's
ownership marker. Stopping the old backend removes its owned interfaces and associated
routes. If startup fails, migration attempts to restore the snapshot. The 0.2 GUI uses user-directory preferences. Enter and save the desired domain suffixes in the new GUI.
The backup and root lock directories remain on disk after stopping.

An administrator can restore the migration snapshot using the bundled helper.

```sh
sudo '/Applications/RNDIS Tether.app/Contents/Resources/rndis-tether-gui-helper' \
  restore-legacy '/Applications/RNDIS Tether.app/Contents/Resources'
```

## Diagnostics

**Check connection** reads the phone IPv6 gateway and Clash selector. **Probe public
HTTPS** concurrently probes Cloudflare and Baidu using the phone's scoped DNS and
USB-bound IPv4 connections, plus IPv6 probes when the phone has an IPv6 gateway, retaining TLS verification. Each result is shown
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
# Optional real rule-engine test using an installed mihomo, all traffic on loopback.
python3 tests/gui/RuleIntegration.py build/gui/demand-tests /path/to/mihomo
```

Only macOS system frameworks are required at runtime. The offline GUI integration
tests additionally use Python 3. The local application is ad-hoc signed. Developer ID
signing and notarization are needed for conventional broad distribution.

Offline tests and archive checks cover parsing, controller recovery and packaged
resources. Administrator authorization, phone reconnects, backend cleanup on GUI exit
and real Clash forwarding additionally require installed-app testing with a phone.
