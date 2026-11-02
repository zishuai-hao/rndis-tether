"""Exercise the actual reconnect/DNS/ownership policy without changing host routes."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("policy", Path(__file__).resolve().parents[1] / "examples/ipv6-route-hook.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
ADDRESS = "2001:db8::10"
ADDRESS2 = "2001:db8::20"
DOMAIN = "server.example.com"


class Network:
    def __init__(self):
        self.gateway = None
        self.addresses = [ADDRESS]
        self.routes = {}
        self.operations = []
        self.lookups = 0
        self.dns_error = False

    def snapshot(self, interface):
        return self.gateway

    def resolve(self, domain):
        self.lookups += 1
        if self.dns_error:
            raise RuntimeError("DNS timeout")
        return self.addresses.copy()

    def route(self, address):
        return self.routes.get(address)

    def set_route(self, address, gateway, current):
        self.operations.append(("set", address, gateway))
        self.routes[address] = {"gateway": gateway, "interface": "feth50"}

    def delete_route(self, address, gateway):
        self.operations.append(("delete", address, gateway))
        del self.routes[address]


class PolicyTests(unittest.TestCase):
    def test_connect_disconnect_and_changed_gateway(self):
        network, state = Network(), {}
        policy.reconcile(state, "feth50", [DOMAIN], network, 0)
        self.assertEqual(network.operations, [])
        self.assertEqual(network.lookups, 0)
        network.gateway = "fe80::1%feth50"
        policy.reconcile(state, "feth50", [DOMAIN], network, 1)
        self.assertEqual(network.routes[ADDRESS]["gateway"], network.gateway)
        policy.reconcile(state, "feth50", [DOMAIN], network, 2)
        self.assertEqual(len(network.operations), 1)  # Duplicate notifications are harmless.
        self.assertEqual(network.lookups, 1)
        network.gateway = None
        policy.reconcile(state, "feth50", [DOMAIN], network, 3)
        self.assertEqual(network.routes, {})
        network.gateway = "fe80::2%feth50"
        policy.reconcile(state, "feth50", [DOMAIN], network, 4)
        self.assertEqual(network.routes[ADDRESS]["gateway"], network.gateway)
        self.assertEqual(network.lookups, 2)

    def test_gateway_changes_while_connected(self):
        network, state = Network(), {}
        network.gateway = "fe80::1%feth50"
        policy.reconcile(state, "feth50", [DOMAIN], network, 1)
        network.gateway = "fe80::2%feth50"
        policy.reconcile(state, "feth50", [DOMAIN], network, 2)
        self.assertEqual(network.routes[ADDRESS]["gateway"], "fe80::2%feth50")
        self.assertEqual(len(network.operations), 2)

    def test_dns_changes_replace_stale_host_route(self):
        network, state = Network(), {}
        network.gateway = "fe80::1%feth50"
        policy.reconcile(state, "feth50", [DOMAIN], network, 0)
        network.addresses = [ADDRESS2]
        policy.reconcile(state, "feth50", [DOMAIN], network, 301)
        self.assertNotIn(ADDRESS, network.routes)
        self.assertIn(ADDRESS2, network.routes)

    def test_transient_dns_failure_keeps_last_good_route(self):
        network, state = Network(), {}
        network.gateway = "fe80::1%feth50"
        policy.reconcile(state, "feth50", [DOMAIN], network, 0)
        network.dns_error = True
        messages = policy.reconcile(state, "feth50", [DOMAIN], network, 301)
        self.assertIn(ADDRESS, network.routes)
        self.assertEqual(len(messages), 1)
        self.assertEqual(policy.reconcile(state, "feth50", [DOMAIN], network, 362), [])

    def test_refresh_event_checks_dns_before_local_cache_expiry(self):
        network, state = Network(), {}
        network.gateway = "fe80::1%feth50"
        policy.reconcile(state, "feth50", [DOMAIN], network, 0)
        network.addresses = [ADDRESS2]
        policy.reconcile(state, "feth50", [DOMAIN], network, 1, force_dns=True)
        self.assertNotIn(ADDRESS, network.routes)
        self.assertIn(ADDRESS2, network.routes)

    def test_disconnect_does_not_delete_a_route_replaced_by_vpn(self):
        network, state = Network(), {}
        network.gateway = "fe80::1%feth50"
        policy.reconcile(state, "feth50", [DOMAIN], network, 0)
        replacement = {"gateway": "fe80::3%utun5", "interface": "utun5"}
        network.routes[ADDRESS] = replacement
        network.gateway = None
        policy.reconcile(state, "feth50", [DOMAIN], network, 1)
        self.assertEqual(network.routes[ADDRESS], replacement)
        self.assertEqual(state["owned"], {})

    def test_disappeared_interface_and_route_are_already_clean(self):
        network, state = Network(), {}
        network.gateway = "fe80::1%feth50"
        policy.reconcile(state, "feth50", [DOMAIN], network, 0)
        network.gateway = None
        network.routes = {}
        policy.reconcile(state, "feth50", [DOMAIN], network, 1)
        self.assertEqual(len(network.operations), 1)
        self.assertEqual(state["owned"], {})

    def test_parsers_reject_default_route_as_owned_host(self):
        self.assertIsNone(policy.parse_route("destination: default\nflags: <UP,GATEWAY>\ninterface: feth50", ADDRESS))
        text = "destination: " + ADDRESS + "\ngateway: fe80::1\ninterface: feth50\nflags: <UP,GATEWAY,HOST,DONE,STATIC>\n"
        self.assertEqual(policy.parse_route(text, ADDRESS), {"gateway": "fe80::1%feth50", "interface": "feth50"})
        self.assertEqual(policy.parse_gateway("default fe80::2%feth50 UGcIg feth50\n", "feth50"), "fe80::2%feth50")

    def test_literal_destinations_and_domain_validation(self):
        self.assertEqual(policy.domains_from("server.example.com\n2001:db8::10\n"), ["server.example.com", "2001:db8::10"])
        self.assertIsNone(policy.routable_v6("fe80::1"))
        self.assertIsNone(policy.routable_v6("::1"))
        with self.assertRaises(RuntimeError):
            policy.domains_from("--output=/tmp/test")


if __name__ == "__main__":
    unittest.main(verbosity=2)
