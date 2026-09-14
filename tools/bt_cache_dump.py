#!/usr/bin/env python3
"""
bt_cache_dump — trova dove macOS tiene i dati dei dispositivi Bluetooth.

sdp_patch cerca il report descriptor HID in
/Library/Preferences/com.apple.Bluetooth.plist, sotto l'attributo SDP 0x0206.
Se li' non c'e', prima di cambiare strada conviene guardare davvero cosa c'e'
e dove, invece di tirare a indovinare.

Questo strumento:

  - elenca tutti i plist Bluetooth di sistema e utente;
  - ne stampa lo scheletro (chiavi, tipi, dimensioni) senza riversare i dati;
  - cerca ovunque l'indirizzo del dispositivo;
  - cerca ovunque blob binari che abbiano la forma di un report descriptor HID.

    sudo ./bt_cache_dump.py
    sudo ./bt_cache_dump.py --addr 04:B5:B2:7A:B9:8F
    sudo ./bt_cache_dump.py --depth 6
"""

import argparse
import glob
import os
import plistlib
import re
import sys

SEARCH_GLOBS = [
    "/Library/Preferences/com.apple.Bluetooth*.plist",
    "/Library/Preferences/ByHost/com.apple.Bluetooth*.plist",
    os.path.expanduser("~/Library/Preferences/com.apple.Bluetooth*.plist"),
    os.path.expanduser("~/Library/Preferences/ByHost/com.apple.Bluetooth*.plist"),
    "/Library/Preferences/com.apple.MobileBluetooth*.plist",
]

# Un report descriptor HID inizia con un item Usage Page.
DESC_PREFIXES = (b"\x05\x01", b"\x05\x0d", b"\x05\x0D", b"\x06\x00\xff",
                 b"\x06\x00\xFF")

# Sequenze con cui inizia, quasi sempre, il descriptor di un dispositivo di
# puntamento. Servono a ritrovarlo dentro un blob binario piu' grande.
DESC_SIGNATURES = (
    b"\x05\x01\x09\x02\xA1\x01",   # Generic Desktop / Mouse / Collection
    b"\x05\x01\x09\x01\xA1\x01",   # Generic Desktop / Pointer
    b"\x05\x0D\x09\x05\xA1\x01",   # Digitizer / Touch Pad
    b"\x05\x01\x09\x06\xA1\x01",   # Generic Desktop / Keyboard
)


def norm_addr(a):
    return re.sub(r"[^0-9a-f]", "", a.lower())


def typename(v):
    if isinstance(v, dict):  return "dict(%d)" % len(v)
    if isinstance(v, list):  return "list(%d)" % len(v)
    if isinstance(v, (bytes, bytearray)): return "data(%d byte)" % len(v)
    if isinstance(v, bool):  return "bool=%s" % v
    if isinstance(v, int):   return "int=%d" % v
    if isinstance(v, str):
        return "str=%r" % (v if len(v) <= 40 else v[:40] + "...")
    return type(v).__name__


def skeleton(node, depth, maxdepth, indent=4):
    if depth > maxdepth:
        return
    pad = " " * indent
    if isinstance(node, dict):
        for k in sorted(node, key=str):
            v = node[k]
            print("%s%s : %s" % (pad, k, typename(v)))
            if isinstance(v, (dict, list)):
                skeleton(v, depth + 1, maxdepth, indent + 2)
    elif isinstance(node, list):
        for i, v in enumerate(node[:8]):
            print("%s[%d] : %s" % (pad, i, typename(v)))
            if isinstance(v, (dict, list)):
                skeleton(v, depth + 1, maxdepth, indent + 2)
        if len(node) > 8:
            print("%s... altri %d" % (pad, len(node) - 8))


def walk(node, path=()):
    """Attraversa il plist scendendo anche dentro i blob annidati.

    macOS serializza i record SDP di un dispositivo in un unico blob binario
    (DeviceCache/<indirizzo>/Services). Se quel blob e' a sua volta un plist
    binario lo si apre e lo si attraversa: e' li' dentro che finisce il report
    descriptor HID.
    """
    if isinstance(node, dict):
        for k, v in node.items():
            yield path + (str(k),), v
            yield from walk(v, path + (str(k),))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield path + ("[%d]" % i,), v
            yield from walk(v, path + ("[%d]" % i,))
    elif isinstance(node, (bytes, bytearray)) and node[:8] == b"bplist00":
        try:
            inner = plistlib.loads(bytes(node))
        except Exception:
            return
        yield path + ("<bplist>",), inner
        yield from walk(inner, path + ("<bplist>",))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--addr", help="indirizzo Bluetooth da cercare")
    ap.add_argument("--depth", type=int, default=4,
                    help="profondita' dello scheletro (default 4)")
    args = ap.parse_args()

    want = norm_addr(args.addr) if args.addr else None

    files = []
    for g in SEARCH_GLOBS:
        files.extend(sorted(glob.glob(g)))
    if not files:
        print("Nessun plist Bluetooth trovato.")
        return 1

    all_descs = []
    all_addr_hits = []

    for path in files:
        print("=" * 72)
        print(path)
        try:
            with open(path, "rb") as f:
                data = plistlib.load(f)
        except PermissionError:
            print("  (serve sudo)")
            continue
        except Exception as e:
            print("  illeggibile: %s" % e)
            continue

        print("  --- struttura ---")
        skeleton(data, 0, args.depth)

        for p, v in walk(data):
            joined = "/".join(p)

            if want and any(norm_addr(seg) == want for seg in p):
                all_addr_hits.append((path, joined, typename(v)))

            if isinstance(v, (bytes, bytearray)) and len(v) >= 8:
                b = bytes(v)
                if b[:3] in DESC_PREFIXES or b[:2] in DESC_PREFIXES:
                    all_descs.append((path, joined, b, 0))
                    continue
                # descriptor annidato dentro un blob piu' grande
                for sig in DESC_SIGNATURES:
                    off = b.find(sig)
                    if off >= 0:
                        all_descs.append((path, joined + " @offset %d" % off,
                                          b[off:], off))
                        break
        print()

    print("=" * 72)
    if want:
        print("Nodi che contengono l'indirizzo %s: %d" % (args.addr,
                                                          len(all_addr_hits)))
        for f, p, t in all_addr_hits[:40]:
            print("  %s\n    %s : %s" % (os.path.basename(f), p, t))
        print()

    print("Blob che hanno la forma di un report descriptor HID: %d"
          % len(all_descs))
    for f, p, b, off in all_descs:
        print("  %s\n    %s  (%d byte dal punto trovato)"
              % (os.path.basename(f), p, len(b)))
        for i in range(0, min(len(b), 96), 16):
            print("    %s" % " ".join("%02X" % x for x in b[i:i + 16]))
        if len(b) > 96:
            print("    ...")
        print()
    if not all_descs:
        print("  nessuno.")
        print()
        print("  Se il trackpad e' connesso via Bluetooth e qui non c'e' nulla,")
        print("  significa che su questa versione di macOS il descriptor non")
        print("  viene messo in cache su disco: bluetoothd rifa' la query SDP")
        print("  a ogni connessione e lo tiene solo in memoria.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
