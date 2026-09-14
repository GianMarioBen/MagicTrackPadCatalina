#!/usr/bin/env python3
"""
mt_decode — decodifica i report multitouch della Magic Trackpad USB-C.

Funziona su tre sorgenti:

    ./mt_decode.py --pklg cattura.pklg        # cerca A1 31 nel file
    ./mt_decode.py --hex  "A1 31 00 00 ..."   # un singolo report
    ./mt_decode.py --stdin                    # legge righe esadecimali

Il layout (vedi docs/03-report-0x31.md):

    Bluetooth : report 0x31, header 4 byte, 9 byte per contatto
    USB       : report 0x02, header 6 byte, 9 byte per contatto
"""

import argparse
import re
import sys

BT_REPORT_ID = 0x31
BT_HEADER = 4
USB_REPORT_ID = 0x02
USB_HEADER = 12
CONTACT_SIZE = 9

X_MIN, X_MAX = -3678, 3934
Y_MIN, Y_MAX = -2478, 2587


def sign_extend(value, bits):
    mask = 1 << (bits - 1)
    return (value & (mask - 1)) - (value & mask)


def decode_contact(t):
    """Decodifica i 9 byte di un contatto."""
    x = sign_extend((t[1] << 8 | t[0]) >> 0 & 0x1FFF, 13)
    y = sign_extend(((t[3] << 16 | t[2] << 8 | t[1]) >> 5) & 0x1FFF, 13)
    return {
        "x": x,
        "y": -y,
        "touch_major": t[4],
        "touch_minor": t[5],
        "size": t[6],
        "pressure": t[7],
        # lo stato sta nei due bit alti di t[3]: 0x80 = dito appoggiato
        "state": t[3] & 0xC0,
        "down": (t[3] & 0xC0) == 0x80,
        "id": t[8] & 0x0F,
        "orientation": (t[8] >> 5) - 4,
    }


def decode_report(data):
    """data include il report ID in posizione 0. Restituisce None se non valido."""
    if not data:
        return None
    if data[0] == BT_REPORT_ID:
        header = BT_HEADER
    elif data[0] == USB_REPORT_ID:
        header = USB_HEADER
    else:
        return None

    body = len(data) - header
    if body < 0 or body % CONTACT_SIZE:
        return None

    n = body // CONTACT_SIZE
    contacts = [decode_contact(data[header + i * CONTACT_SIZE:
                                    header + (i + 1) * CONTACT_SIZE])
                for i in range(n)]
    return {
        "report_id": data[0],
        "button": bool(data[1] & 1),
        "contacts": contacts,
    }


def print_report(rep, prefix=""):
    active = [c for c in rep["contacts"] if c["down"]]
    print("%sreport 0x%02X  button=%s  contatti=%d  attivi=%d"
          % (prefix, rep["report_id"], "SI" if rep["button"] else "no",
             len(rep["contacts"]), len(active)))
    for c in rep["contacts"]:
        flag = "" if c["down"] else "  (sollevato)"
        print("    id=%-2d  x=%-6d y=%-6d  size=%-4d major=%-4d minor=%-4d%s"
              % (c["id"], c["x"], c["y"], c["size"],
                 c["touch_major"], c["touch_minor"], flag))


def parse_hex(text):
    return bytes(int(h, 16) for h in re.findall(r"\b[0-9A-Fa-f]{2}\b", text))


def strip_a1(data):
    """Toglie l'header di transazione HID-over-L2CAP se presente."""
    if len(data) >= 2 and data[0] == 0xA1:
        return data[1:]
    return data


def scan_pklg(path):
    """Cerca le sequenze A1 31 nel file e decodifica quello che segue.

    Non interpreta il framing del .pklg: cerca direttamente la firma, il che
    lo rende robusto sulle catture GUI come su quelle CLI.
    """
    with open(path, "rb") as f:
        blob = f.read()

    found = 0
    i = 0
    while True:
        i = blob.find(b"\xA1\x31", i)
        if i < 0:
            break
        # prova tutte le lunghezze valide, dalla piu' lunga alla piu' corta
        for n in (5, 4, 3, 2, 1):
            length = 1 + BT_HEADER + n * CONTACT_SIZE   # A1 + report
            chunk = blob[i:i + length]
            if len(chunk) < length:
                continue
            rep = decode_report(strip_a1(chunk))
            if not rep:
                continue
            active = [c for c in rep["contacts"] if c["down"]]
            # scarta i falsi positivi: contatti fuori range
            if any(not (X_MIN - 200 <= c["x"] <= X_MAX + 200 and
                        Y_MIN - 200 <= c["y"] <= Y_MAX + 200)
                   for c in active):
                continue
            found += 1
            print_report(rep, "@0x%06X  " % i)
            break
        i += 2

    print("\nReport multitouch decodificati: %d" % found)
    if found == 0:
        print("Nessuno. Se la cattura viene dalla CLI di packetlogger i payload "
              "di 1 e 2 dita sono stati rimossi dallo scrubbing (vedi "
              "docs/02-analisi.md §2).")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--pklg", metavar="FILE", help="cattura PacketLogger")
    g.add_argument("--hex", metavar="BYTES", help="un report in esadecimale")
    g.add_argument("--stdin", action="store_true",
                   help="una riga esadecimale per report")
    args = p.parse_args()

    if args.pklg:
        scan_pklg(args.pklg)
    elif args.hex:
        rep = decode_report(strip_a1(parse_hex(args.hex)))
        if rep:
            print_report(rep)
        else:
            print("Non e' un report multitouch valido.")
    else:
        for line in sys.stdin:
            data = strip_a1(parse_hex(line))
            rep = decode_report(data)
            if rep:
                print_report(rep)


if __name__ == "__main__":
    main()
