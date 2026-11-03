#!/usr/bin/env python3
"""Opt-in, read-only tests against a development Mac's actual DNS configuration.

GUI_DNS_TARGET is deliberately supplied by the operator, never bundled.
DNS-only success is not routing/public-HTTPS acceptance. Set GUI_REQUIRE_HTTPS=yes for both.
Public probes test the phone's exit; they do not test the configured target's HTTPS service.
"""
import base64
import ipaddress
import json
import os
from pathlib import Path
import subprocess


def run(*args, timeout=35):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def main():
    helper = os.environ.get("GUI_HELPER", "build/gui/RNDIS Tether.app/Contents/Resources/rndis-tether-gui-helper")
    # An absent interface must produce a failing diagnostic, even with a literal
    # that needs no DNS. This prevents a successful exit from hiding failed checks.
    invalid_network = dict(enabled=False, preferPhone=False, targets=["2001:db8::10"], dnsServer="")
    payload = base64.b64encode(json.dumps(invalid_network).encode()).decode()
    absent = run(helper, "diagnose", payload, "feth2147483647")
    assert absent.returncode == 2 and "尚未通过" in absent.stdout, absent.stdout + absent.stderr
    assert "当前为未应用的草稿" in absent.stdout, absent.stdout
    print("PASS: a missing interface is a failed diagnostic, not successful acceptance")

    target = os.environ.get("GUI_DNS_TARGET")
    if not target:
        print("SKIP live DNS: set GUI_DNS_TARGET (the app runtime has no Python dependency)")
        return
    response = run(helper, "resolve", target)
    assert response.returncode == 0, response.stdout + response.stderr
    addresses = {str(ipaddress.IPv6Address(value)) for value in response.stdout.splitlines()}
    assert addresses, "No IPv6 results from the real helper resolver"
    print("PASS: real Darwin IPv6 lookup via the helper:", ", ".join(sorted(addresses)))

    server = os.environ.get("GUI_DNS_SERVER", "")
    if server:
        ipaddress.ip_address(server)
        control = run("/usr/bin/dig", "@" + server, target, "AAAA", "+short", "+time=2", "+tries=1")
        assert control.returncode == 0, control.stdout + control.stderr
        expected = {str(ipaddress.IPv6Address(value)) for value in control.stdout.splitlines() if ":" in value}
        assert expected and expected == addresses, (expected, addresses)
        print("PASS: helper AAAA results match the selected DNS server")

    config = dict(enabled=True, preferPhone=False, targets=[target], dnsServer=server)
    payload = base64.b64encode(json.dumps(config).encode()).decode()
    interface = os.environ.get("GUI_DNS_INTERFACE", "feth50")
    require_https = os.environ.get("GUI_REQUIRE_HTTPS") == "yes"
    args = [helper, "diagnose", payload, interface] + (["--https"] if require_https else [])
    diagnostic = run(*args, timeout=95)
    print(diagnostic.stdout)
    assert all(address in diagnostic.stdout for address in addresses), diagnostic.stdout + diagnostic.stderr
    if os.environ.get("GUI_REQUIRE_SAVED") == "yes":
        saved = json.loads(Path("/etc/rndis-tether-gui.json").read_text())
        assert saved == config and "已保存到磁盘" in diagnostic.stdout, diagnostic.stdout
        print("PASS: settings exist on disk and the diagnostic recognizes the applied configuration")
    if require_https or os.environ.get("GUI_REQUIRE_ROUTES") == "yes":
        assert diagnostic.returncode == 0, "Routing/HTTPS acceptance has NOT passed"
        if require_https:
            assert "https://www.cloudflare.com/" in diagnostic.stdout and "https://www.baidu.com/" in diagnostic.stdout
            assert "本次未探测目标服务器的 HTTPS 服务" in diagnostic.stdout
        print("PASS: route" + (" and public USB HTTPS" if require_https else "") + " acceptance")
    else:
        print("PASS DNS only; route/HTTPS acceptance was not requested and is not implied")


if __name__ == "__main__":
    main()
