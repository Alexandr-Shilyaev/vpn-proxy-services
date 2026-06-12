#!/usr/bin/env python3
"""Считает AllowedIPs для split-tunnel: весь интернет МИНУС исключаемые сети.

Исключения берутся из трёх источников (любая комбинация):
  --countries ru,by   страны -> все их подсети из RIPEstat (country-resource-list);
  --asns AS47541,...  автономные системы -> их анонсируемые префиксы (announced-prefixes);
  --cidrs 1.2.3.0/24  произвольные подсети.

Вывод в stdout (для парсинга из bash):
  V4=<csv cidr>          всегда
  V6=<csv cidr>          только при --ipv6 1

Без исключений печатает V4=0.0.0.0/0 (и V6=::/0 при --ipv6 1).
Нужен только стандартный Python 3 (urllib + ipaddress), без сторонних пакетов.

Про размер списка: по умолчанию выдаётся МИНИМАЛЬНЫЙ ТОЧНЫЙ набор CIDR. «Весь интернет
минус RU» всё равно крупный, т.к. RU-блоки разбросаны. Чтобы получить МАЛО диапазонов,
есть --aggregate N: RU-сети огрубляются до /N (v4) и сливаются. Это уменьшает список в разы,
но с допуском — соседние НЕ-российские адреса в тех же /N тоже пойдут мимо VPN (для задачи
«рунет напрямую» это безвредно).
"""
import argparse
import ipaddress
import json
import sys
import urllib.request

RIPE = "https://stat.ripe.net/data"


def _fetch(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def country_prefixes(cc):
    d = _fetch(f"{RIPE}/country-resource-list/data.json?resource={cc}")
    res = d["data"]["resources"]
    return list(res.get("ipv4", [])) + list(res.get("ipv6", []))


def asn_prefixes(asn):
    num = asn.upper().replace("AS", "").strip()
    d = _fetch(f"{RIPE}/announced-prefixes/data.json?resource=AS{num}")
    return [p["prefix"] for p in d["data"]["prefixes"]]


def collect(countries, asns, cidrs):
    nets = []
    for cc in countries:
        nets += country_prefixes(cc)
    for a in asns:
        nets += asn_prefixes(a)
    nets += cidrs
    return nets


def _parse(nets, version, aggregate):
    """Парсит сети нужной версии; при aggregate>0 огрубляет v4 до /aggregate."""
    out = []
    for n in nets:
        try:
            net = ipaddress.ip_network(n, strict=False)
        except ValueError:
            continue
        if net.version != version:
            continue
        if version == 4 and aggregate and net.prefixlen > aggregate:
            net = net.supernet(new_prefix=aggregate)
        out.append(net)
    return out


def complement(version, nets, aggregate=0):
    """Возвращает список CIDR = всё адресное пространство версии МИНУС nets."""
    lo, hi = (0, 2 ** 32 - 1) if version == 4 else (0, 2 ** 128 - 1)
    # ВАЖНО: ip_address(0) вернёт IPv4 — для v6 нужен явный класс адреса.
    addr = ipaddress.IPv4Address if version == 4 else ipaddress.IPv6Address

    ranges = []
    for net in _parse(nets, version, aggregate):
        ranges.append((int(net.network_address), int(net.broadcast_address)))

    ranges.sort()
    merged = []
    for a, b in ranges:
        if merged and a <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))

    gaps = []
    cur = lo
    for a, b in merged:
        if a > cur:
            gaps.append((cur, a - 1))
        cur = max(cur, b + 1)
    if cur <= hi:
        gaps.append((cur, hi))

    out = []
    for a, b in gaps:
        for net in ipaddress.summarize_address_range(addr(a), addr(b)):
            out.append(str(net))
    return out


def _split(s):
    return [x.strip() for x in s.replace(",", " ").split() if x.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--countries", default="")
    ap.add_argument("--asns", default="")
    ap.add_argument("--cidrs", default="")
    ap.add_argument("--ipv6", type=int, default=0)
    ap.add_argument("--aggregate", type=int, default=0,
                    help="огрублять v4-исключения до /N (0 = точно, без огрубления)")
    a = ap.parse_args()

    countries, asns, cidrs = _split(a.countries), _split(a.asns), _split(a.cidrs)

    if not (countries or asns or cidrs):
        print("V4=0.0.0.0/0")
        if a.ipv6:
            print("V6=::/0")
        return

    try:
        nets = collect(countries, asns, cidrs)
    except Exception as e:  # сеть/RIPEstat недоступны
        sys.stderr.write(f"allowedips: не удалось получить списки: {e}\n")
        sys.exit(2)

    print("V4=" + ",".join(complement(4, nets, a.aggregate)))
    if a.ipv6:
        print("V6=" + ",".join(complement(6, nets)))


if __name__ == "__main__":
    main()
