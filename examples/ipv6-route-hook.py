#!/usr/bin/python3
"""Optional network-hook example: IPv6 host routes via the phone current gateway.

Requires Python 3; the rndis-tether daemon itself has no Python dependency.
Reads /etc/rndis-tether-route-domains (hostnames or IPv6 literals, one per line).
Uses system DNS, without installing resolvers or selecting a public DNS provider.
"""
import argparse
import copy
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import socket
import sys
import time

CONFIG = Path("/etc/rndis-tether-route-domains")
STATE = Path("/var/db/rndis-tether/server-routes.json")
DNS_TTL = 300


def routable_v6(value):
    try:
        address = ipaddress.IPv6Address(value)
        return str(address) if not (address.is_unspecified or address.is_loopback or address.is_multicast or address.is_link_local) else None
    except ValueError:
        return None


def parse_gateway(table, interface):
    for line in table.splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[0] != "default" or fields[3] != interface:
            continue
        value = fields[1].split("%", 1)[0]
        try:
            if ipaddress.IPv6Address(value).is_link_local:
                return value + "%" + interface
        except ValueError:
            pass
    return None


def parse_route(text, target):
    fields = {}
    for line in text.splitlines():
        if ":" in line:
            key, value = line.strip().split(":", 1)
            fields[key] = value.strip()
    if "HOST" not in fields.get("flags", "").strip("<>").split(","):
        return None
    if routable_v6(fields.get("destination", "")) != target:
        return None
    interface, gateway = fields.get("interface", ""), fields.get("gateway", "")
    if gateway.startswith("fe80:") and "%" not in gateway:
        gateway += "%" + interface
    return {"interface": interface, "gateway": gateway}



def domains_from(text):
    domains = []
    for line in text.splitlines():
        value = line.split("#", 1)[0].strip().lower()
        if not value:
            continue
        if not routable_v6(value) and not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?", value):
            raise RuntimeError("Invalid route destination: " + value)
        if value not in domains:
            domains.append(value)
    if len(domains) > 8:
        raise RuntimeError("At most 8 route destinations are supported")
    return domains


class System:
    def __init__(self, dry=False):
        self.dry = dry

    @staticmethod
    def command(*args, check=True):
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=4)
        if check and result.returncode:
            raise RuntimeError(" ".join(args) + ": " + result.stdout.strip())
        return result.stdout

    def snapshot(self, interface):
        text = self.command("/sbin/ifconfig", interface, check=False)
        ready = any(routable_v6(value.split("%", 1)[0])
                    for value in re.findall(r"inet6\s+(\S+)", text))
        if not ready:
            return None
        return parse_gateway(self.command("/usr/sbin/netstat", "-rn", "-f", "inet6"), interface)

    def resolve(self, domain):
        literal = routable_v6(domain)
        if literal:
            return [literal]
        try:
            values = socket.getaddrinfo(domain, None, socket.AF_INET6, socket.SOCK_STREAM)
        except socket.gaierror as error:
            raise RuntimeError("System DNS lookup failed: " + str(error)) from error
        return sorted({address for item in values if (address := routable_v6(item[4][0]))})

    def route(self, address):
        return parse_route(self.command("/sbin/route", "-n", "get", "-inet6", address,
                                        check=False), address)

    def set_route(self, address, gateway, current):
        action = "change" if current else "add"
        if self.dry:
            print("Would " + action + " " + address + "/128 via " + gateway)
        else:
            self.command("/sbin/route", "-n", action, "-inet6", "-host", address, gateway)

    def delete_route(self, address, gateway):
        if self.dry:
            print("Would delete owned route " + address + "/128 via " + gateway)
        else:
            self.command("/sbin/route", "-n", "delete", "-inet6", "-host", address, gateway)


def reconcile(state, interface, domains, system, now, force_dns=False):
    """Keep the configured host routes in sync; remove only routes we still own."""
    gateway = system.snapshot(interface)
    owned = state.setdefault("owned", {})
    cache = state.setdefault("cache", {})
    desired = set()
    messages = []
    if gateway:
        for domain in domains:
            entry = cache.get(domain, {"addresses": [], "expires": 0})
            if force_dns or now >= entry["expires"] or gateway != state.get("gateway"):
                try:
                    entry = {"addresses": system.resolve(domain), "expires": now + DNS_TTL}
                except (RuntimeError, subprocess.SubprocessError) as error:
                    entry = dict(entry, expires=now + 60, error=str(error))
                    if entry.get("error") != cache.get(domain, {}).get("error"):
                        messages.append("DNS refresh failed for " + domain + "; retaining the last good addresses")
                cache[domain] = entry
            desired.update(entry["addresses"])

        expected = {"interface": interface, "gateway": gateway}
        for address in sorted(desired):
            current = system.route(address)
            if current != expected:
                system.set_route(address, gateway, current)
                messages.append("route " + address + "/128 -> " + gateway)
            owned[address] = expected.copy()

    for address, previous in list(owned.items()):
        if address in desired:
            continue
        # A route replaced by a VPN/admin belongs to them; never delete it.
        if system.route(address) == previous:
            system.delete_route(address, previous["gateway"])
            messages.append("removed route " + address + "/128")
        del owned[address]
    state["gateway"] = gateway
    state["cache"] = {domain: entry for domain, entry in cache.items() if domain in domains}
    return messages


def write_state(path, state):
    temporary = path.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(state, output, indent=2, sort_keys=True)
        output.write("\n")
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("interface", help="the phone interface supplied by network-hook")
    parser.add_argument("--check", action="store_true", help="show the plan without changing routes or state")
    parser.add_argument("--config", type=Path, default=CONFIG)
    args = parser.parse_args()
    if not re.fullmatch(r"feth[0-9]+", args.interface):
        raise RuntimeError("Invalid phone interface")
    if not args.check and os.geteuid() != 0:
        raise RuntimeError("The installed route hook must run as root")
    domains = domains_from(args.config.read_text(encoding="utf-8"))
    if args.check:
        state = {}
        for message in reconcile(state, args.interface, domains, System(dry=True), time.time()):
            print(message)
        print(json.dumps(state, indent=2))
        return

    settings = args.config.stat()
    if settings.st_uid != 0 or settings.st_mode & 0o022:
        raise RuntimeError("Route destination settings must be root-owned and not group/world-writable")

    # Parent is rndis-tether's existing root-only runtime directory.
    if STATE.parent.stat().st_uid != 0 or STATE.parent.stat().st_mode & 0o077:
        raise RuntimeError("Route state directory is not root-only")
    with open(STATE.with_suffix(".lock"), "a", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        state = json.loads(STATE.read_text()) if STATE.exists() else {}
        original = copy.deepcopy(state)
        try:
            for message in reconcile(state, args.interface, domains, System(), time.time(),
                                     force_dns=os.environ.get("RNDIS_TETHER_EVENT") == "refresh"):
                print("rndis route policy: " + message, file=sys.stderr)
        finally:
            if state != original:
                write_state(STATE, state)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("rndis route policy: " + str(error), file=sys.stderr)
        sys.exit(1)
