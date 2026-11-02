# Optional network policies

`network-hook` runs an administrator-installed executable after network changes.
It can restore routes when a phone reconnects with a different IPv6 gateway, without
an additional daemon. The default is `none`; the normal USB bridge and installation
do not need Python or a hook.

## Hook contract

- Configure an absolute executable path with `sudo rndis-tether config network-hook PATH`.
  This setting takes effect after the service restarts, like `ipv6`.
- The canonical executable and all its parent directories must be root-owned and
  must not be writable by group or others. The check is repeated before every run.
- The hook receives the host interface as its only argument, for example `feth50`.
  It runs as root, without a shell, with closed inherited USB/BPF/socket descriptors,
  null stdin/stdout, and the daemon's stderr. Its environment contains only `PATH`,
  `LC_ALL=C`, and `RNDIS_TETHER_EVENT` (`network-change` or `refresh`).
- IPv4/IPv6 service and IPv6 interface notifications trigger reconciliation, including
  address/router arrival and loss. Bursts are debounced for 300 ms. At most one hook
  runs at a time; events received while it runs schedule one following reconciliation.
- A five-minute `refresh` invocation lets a policy refresh DNS even when the network
  stays unchanged. A hook should inspect current state and be idempotent. An absent
  interface is an ordinary disconnected state, not an error.
- The hook must finish within 30 seconds and must not daemonize. Timeout or shutdown
  kills its process group and reaps the child. Child completion is checked by a timer
  only while a hook is running; no blocking wait or second thread handles policy work.
- Hooks are not packet proxies. They may configure kernel routes while the existing
  USB bridge continues to handle its normal I/O.

Disable a hook with `sudo rndis-tether config network-hook none`.

## IPv6 split-routing example

[`ipv6-route-hook.py`](ipv6-route-hook.py) is an optional Python 3 example. It keeps
the ordinary preferred connection (usually Wi-Fi), and installs `/128` routes for
selected hostnames or IPv6 literals through the phone's currently advertised router.
The destination file contains one hostname or literal per line, up to eight entries.

After building and installing this branch, install the example:

```sh
sudo install -o root -g wheel -m 755 examples/ipv6-route-hook.py \
  /Library/PrivilegedHelperTools/rndis-tether-ipv6-route-hook
printf '%s\n' server.example.com 2001:db8::10 | \
  sudo tee /etc/rndis-tether-route-domains >/dev/null
sudo chmod 644 /etc/rndis-tether-route-domains
rndis-tether config prefer-phone no
sudo rndis-tether config ipv6 yes
sudo rndis-tether config network-hook \
  /Library/PrivilegedHelperTools/rndis-tether-ipv6-route-hook
```

Replace the documentation destinations with your own. This example's shebang uses
`/usr/bin/python3`; check that a working Python 3 is present before enabling it.
Command Line Tools provide one on the development Macs used here.

The example uses **system DNS** and does not install resolvers, edit `/etc/hosts`, or
choose a public DNS provider. If the preferred network's DNS does not return AAAA
records, configure suitable DNS separately, or use a literal IPv6 address.

The phone must provide IPv6 to tethered clients. If it shares a Wi-Fi uplink without
IPv6, try disabling Wi-Fi on the phone and using mobile data. A link-local address
alone is insufficient. Routing rules cannot create IPv6 connectivity that the phone
does not provide.

The example tracks its owned routes in the service's root-only runtime directory.
On disconnection, or when DNS addresses change, it removes an old route only if the
current next-hop and interface still match its ownership record. A transient DNS
failure retains the last good addresses. A valid address removal takes effect after
a successful lookup; the system resolver's DNS cache still follows DNS TTLs.

Inspect the current plan without root or changes:

```sh
python3 examples/ipv6-route-hook.py feth50 --check
```

After disabling the hook, its optional executable and destination file may be removed.
The normal service uninstall deliberately does not remove administrator-owned hooks.
The example is not a VPN kill switch: when the phone disconnects, it removes its host
routes, so another available route may be selected by macOS.

Run the example's offline reconnect/DNS/route-ownership tests with `make check-examples`.
