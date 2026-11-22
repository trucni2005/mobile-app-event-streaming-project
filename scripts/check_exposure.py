#!/usr/bin/env python3
"""Fail nếu service nào publish port ra ngoài loopback / IP được phép.

Docker publish port bằng iptables riêng, bỏ qua ufw, nên port bind 0.0.0.0 là lộ
ra mọi interface của host. Policy: chỉ bind 127.0.0.1, hoặc IP interface VPN
(BIND_ADDR) cho UI có đăng nhập.

    docker compose config --format json | scripts/check_exposure.py [--allow IP ...]
"""
import argparse
import json
import sys

LOOPBACK = {"127.0.0.1", "::1"}


def find_violations(config, allowed):
    violations = []
    for name, service in sorted(config.get("services", {}).items()):
        for port in service.get("ports") or []:
            # Không ghi host_ip nghĩa là Docker bind mọi interface.
            host_ip = port.get("host_ip") or "0.0.0.0"
            if host_ip not in allowed:
                published = port.get("published") or "<random>"
                violations.append(f"{name}: {host_ip}:{published} -> {port.get('target')}")
    return violations


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--allow",
        action="append",
        default=[],
        help="IP được phép bind ngoài loopback (vd: IP interface VPN). Lặp lại được.",
    )
    args = parser.parse_args()

    allowed = LOOPBACK | {ip for ip in args.allow if ip}
    if allowed & {"0.0.0.0", "::"}:
        parser.error("không được allow 0.0.0.0 / ::")

    violations = find_violations(json.load(sys.stdin), allowed)
    if violations:
        print("Port publish ngoài địa chỉ cho phép " + ", ".join(sorted(allowed)) + ":", file=sys.stderr)
        for line in violations:
            print(f"  - {line}", file=sys.stderr)
        sys.exit(1)
    print("OK: mọi port chỉ bind " + ", ".join(sorted(allowed)))


if __name__ == "__main__":
    main()
