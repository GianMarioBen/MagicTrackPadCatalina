#!/usr/bin/env python3
"""
sdp_patch — sostituisce il report descriptor HID nella cache SDP Bluetooth.

Il problema che risolve
-----------------------
Per un dispositivo Bluetooth HID, il report descriptor che IOBluetoothHIDDriver
pubblica non viene letto dal dispositivo: viene preso dall'attributo SDP 0x0206
(HIDDescriptorList) messo in cache al pairing dentro

    /Library/Preferences/com.apple.Bluetooth.plist

Su Catalina la Magic Trackpad USB-C finisce in cache con il descriptor di
compatibilita' mouse (MaxInputReportSize = 8), quindi il kernel scarta i report
multitouch 0x31 prima che arrivino in user space. Sostituendo quel blob con il
descriptor vero, i report arrivano per via ordinaria.

Uso
---
    sudo ./sdp_patch.py --show                      # cosa c'e' ora in cache
    sudo ./sdp_patch.py --show --addr 04:B5:B2:7A:B9:8F
    sudo ./sdp_patch.py --apply desc.txt --addr 04:B5:B2:7A:B9:8F
    sudo ./sdp_patch.py --restore                   # torna al backup
    sudo ./sdp_patch.py --watch  --apply desc.txt --addr 04:B5:B2:7A:B9:8F

`desc.txt` e' l'output di `mt_desc_dump --hex` preso dal Mac moderno
(esadecimale, spazi e a capo ignorati).

Dopo --apply:
    sudo killall -9 bluetoothd
    (riconnetti il trackpad)
    tools/triage.sh        -> MaxInputReportSize deve essere salito

--watch riapplica la patch se bluetoothd rifa' la query SDP e la sovrascrive.
"""

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time

PLIST = "/Library/Preferences/com.apple.Bluetooth.plist"
BACKUP_SUFFIX = ".mammetta-backup"

# 0x0206 = HIDDescriptorList. Nel plist le chiavi degli attributi SDP sono
# stringhe decimali.
HID_DESCRIPTOR_ATTR = "518"

# Un report descriptor HID plausibile comincia quasi sempre con
# Usage Page (Generic Desktop) = 05 01, oppure Usage Page (Digitizer) = 05 0D.
DESC_PREFIXES = (b"\x05\x01", b"\x05\x0d", b"\x05\x0D")

# Numero massimo di contatti che vogliamo poter ricevere.
MAX_CONTACTS = 10

# Collection vendor che dichiara il report multitouch 0x31.
#
# Il conteggio e' scelto perche' la lunghezza TOTALE del report (report ID
# compreso) valga 4 + 9*MAX_CONTACTS, cioe' la forma esatta del formato
# multitouch. Cosi' sia che macOS consegni la lunghezza realmente ricevuta,
# sia che riempia fino alla dimensione dichiarata, il decoder trova un
# numero intero di contatti: gli eventuali contatti di riempimento hanno i
# bit di stato a zero e vengono scartati come "dito sollevato".
_COUNT = 9 * MAX_CONTACTS + 3

MULTITOUCH_COLLECTION = bytes([
    0x06, 0x00, 0xFF,        # Usage Page (Vendor Defined 0xFF00)
    0x09, 0x31,              # Usage (0x31)
    0xA1, 0x01,              # Collection (Application)
    0x85, 0x31,              #   Report ID (0x31)
    0x09, 0x31,              #   Usage (0x31)
    0x15, 0x00,              #   Logical Minimum (0)
    0x26, 0xFF, 0x00,        #   Logical Maximum (255)
    0x75, 0x08,              #   Report Size (8 bit)
    0x95, _COUNT,            #   Report Count
    0x81, 0x02,              #   Input (Data, Var, Abs)
    0xC0,                    # End Collection
])


def die(msg, code=1):
    print("errore: " + msg, file=sys.stderr)
    sys.exit(code)


def norm_addr(a):
    return re.sub(r"[^0-9a-f]", "", a.lower())


def load_plist(path=PLIST):
    if not os.path.exists(path):
        die("%s non trovato" % path)
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except PermissionError:
        die("serve sudo per leggere %s" % path)
    except Exception as e:
        die("plist illeggibile: %s" % e)


def save_plist(data, path=PLIST):
    tmp = path + ".mammetta-tmp"
    with open(tmp, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def read_hex_file(path):
    with open(path, "r") as f:
        text = f.read()
    # tiene solo le coppie esadecimali, ignora commenti e intestazioni
    text = re.sub(r"(?m)^\s*[A-Za-z].*$", "", text)
    hexes = re.findall(r"\b[0-9A-Fa-f]{2}\b", text)
    if not hexes:
        die("nessun byte esadecimale in %s" % path)
    return bytes(int(h, 16) for h in hexes)


def walk(node, path=()):
    """Genera (percorso, contenitore, chiave, valore) per ogni nodo."""
    if isinstance(node, dict):
        for k, v in list(node.items()):
            yield path + (str(k),), node, k, v
            yield from walk(v, path + (str(k),))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield path + ("[%d]" % i,), node, i, v
            yield from walk(v, path + ("[%d]" % i,))


def find_candidates(data, addr=None):
    """Trova i blob che sembrano report descriptor HID.

    Cerca sia sotto la chiave 518 (0x0206) sia, come rete di sicurezza,
    qualsiasi data che inizi come un descriptor: nelle varie versioni di
    macOS l'annidamento del record SDP cambia.
    """
    want = norm_addr(addr) if addr else None
    out = []

    for path, container, key, value in walk(data):
        if not isinstance(value, (bytes, bytearray)):
            continue
        if len(value) < 8:
            continue

        joined = "/".join(path)
        under_attr = ("/%s/" % HID_DESCRIPTOR_ATTR) in ("/" + joined + "/")
        looks_like = bytes(value[:2]) in DESC_PREFIXES

        if not (under_attr or looks_like):
            continue

        if want:
            # l'indirizzo compare come segmento del percorso, in una delle
            # tante formattazioni possibili
            if not any(norm_addr(seg) == want for seg in path):
                continue

        out.append({
            "path": joined,
            "container": container,
            "key": key,
            "data": bytes(value),
            "under_attr": under_attr,
        })
    return out


def hexdump(b, limit=64):
    shown = b[:limit]
    s = " ".join("%02X" % x for x in shown)
    if len(b) > limit:
        s += " ... (%d byte totali)" % len(b)
    return s


def cmd_show(args):
    data = load_plist()
    cands = find_candidates(data, args.addr)
    if not cands:
        print("Nessun report descriptor trovato in cache"
              + (" per %s" % args.addr if args.addr else "") + ".")
        print("Il trackpad e' accoppiato? Prova senza --addr per vedere tutto.")
        return
    for i, c in enumerate(cands):
        print("[%d] %s" % (i, c["path"]))
        print("    attributo 0x0206: %s" % ("si" if c["under_attr"] else "no (euristica)"))
        print("    lunghezza       : %d byte" % len(c["data"]))
        print("    %s" % hexdump(c["data"]))
        print()


def cmd_add_multitouch(args):
    """Aggiunge in coda al descriptor esistente la collection del report 0x31.

    Non sostituisce nulla di quello che c'e' gia': il mouse di compatibilita'
    resta dichiarato com'era, e si aggiunge soltanto la dichiarazione del
    report multitouch, che il descriptor originale non contiene. E' per
    questo che IOHIDFamily scarta i report 0x31 prima che arrivino in user
    space.
    """
    data = load_plist()
    cands = find_candidates(data, args.addr)
    if not cands:
        die("nessun descriptor in cache. Il trackpad e' accoppiato? "
            "Prova prima --show.")

    targets = [c for c in cands if c["under_attr"]] or cands
    if len(targets) > 1 and args.index is None:
        print("Piu' candidati: scegli con --index N (vedi --show).")
        for i, c in enumerate(targets):
            print("  [%d] %s (%d byte)" % (i, c["path"], len(c["data"])))
        sys.exit(2)

    t = targets[args.index or 0]
    old = t["data"]

    if MULTITOUCH_COLLECTION in old:
        print("La collection multitouch e' gia' presente: niente da fare.")
        return False

    new = old + MULTITOUCH_COLLECTION

    print("Descriptor in %s" % t["path"])
    print("  prima : %d byte" % len(old))
    print("  dopo  : %d byte (+%d)" % (len(new), len(MULTITOUCH_COLLECTION)))
    print("  aggiunta: report 0x31, %d byte di dati, cioe' fino a %d contatti"
          % (_COUNT, MAX_CONTACTS))
    print("  %s" % " ".join("%02X" % b for b in MULTITOUCH_COLLECTION))

    backup = PLIST + BACKUP_SUFFIX
    if not os.path.exists(backup):
        shutil.copy2(PLIST, backup)
        print("\nBackup: %s" % backup)

    t["container"][t["key"]] = new
    save_plist(data)
    print("\nScritto.")
    print("\nOra:")
    print("  sudo killall -9 cfprefsd bluetoothd")
    print("  (spegni e riaccendi il trackpad per farlo riconnettere)")
    print("  ./tools/triage.sh      -> MaxInputReportSize deve valere %d"
          % (_COUNT + 1))
    print("  ./build/mammetta_bridge -v")
    return True


def cmd_apply(args):
    new_desc = read_hex_file(args.apply)
    print("Nuovo descriptor: %d byte" % len(new_desc))
    print("  %s" % hexdump(new_desc, 32))

    if bytes(new_desc[:2]) not in DESC_PREFIXES and not args.force:
        die("non sembra un report descriptor (non inizia con 05 01 / 05 0D). "
            "Usa --force se sei sicuro.")

    data = load_plist()
    cands = find_candidates(data, args.addr)
    if not cands:
        die("nessun blob da sostituire. Lancia prima --show.")

    # preferisce quelli effettivamente sotto l'attributo 0x0206
    targets = [c for c in cands if c["under_attr"]] or cands
    if len(targets) > 1 and args.index is None:
        print("\nPiu' candidati: scegli con --index N (vedi --show).")
        for i, c in enumerate(targets):
            print("  [%d] %s (%d byte)" % (i, c["path"], len(c["data"])))
        sys.exit(2)

    t = targets[args.index or 0]

    backup = PLIST + BACKUP_SUFFIX
    if not os.path.exists(backup):
        shutil.copy2(PLIST, backup)
        print("\nBackup: %s" % backup)
    else:
        print("\nBackup gia' presente: %s" % backup)

    if t["data"] == new_desc:
        print("Gia' applicato, niente da fare.")
        return False

    print("Sostituisco %s (%d -> %d byte)"
          % (t["path"], len(t["data"]), len(new_desc)))
    t["container"][t["key"]] = new_desc
    save_plist(data)
    print("Scritto.")
    print("\nOra:  sudo killall -9 cfprefsd bluetoothd")
    print("      (riconnetti il trackpad, poi tools/triage.sh)")
    return True


def cmd_restore(args):
    backup = PLIST + BACKUP_SUFFIX
    if not os.path.exists(backup):
        die("nessun backup in %s" % backup)
    shutil.copy2(backup, PLIST)
    print("Ripristinato da %s" % backup)
    print("Ora:  sudo killall -9 cfprefsd bluetoothd")


def cmd_watch(args):
    """Riapplica la patch se bluetoothd la sovrascrive."""
    print("Sorveglianza di %s — Ctrl-C per uscire.\n" % PLIST)
    last_mtime = 0
    while True:
        try:
            mtime = os.path.getmtime(PLIST)
            if mtime != last_mtime:
                last_mtime = mtime
                changed = (cmd_add_multitouch(args) if args.add_multitouch
                           else cmd_apply(args))
                if changed:
                    print(">>> cache riscritta da bluetoothd, patch riapplicata "
                          "(%s)\n" % time.strftime("%H:%M:%S"))
                    subprocess.run(["killall", "-9", "cfprefsd"],
                                   stderr=subprocess.DEVNULL)
            time.sleep(2)
        except KeyboardInterrupt:
            print("\nUscita.")
            return
        except SystemExit:
            raise
        except Exception as e:
            print("watch: %s" % e, file=sys.stderr)
            time.sleep(5)


def main():
    p = argparse.ArgumentParser(
        description="Patch del report descriptor HID nella cache SDP Bluetooth.")
    p.add_argument("--show", action="store_true",
                   help="mostra i descriptor in cache")
    p.add_argument("--apply", metavar="FILE",
                   help="sostituisce il descriptor con quello esadecimale in FILE")
    p.add_argument("--add-multitouch", action="store_true",
                   help="aggiunge al descriptor la dichiarazione del report 0x31")
    p.add_argument("--restore", action="store_true",
                   help="ripristina il backup")
    p.add_argument("--watch", action="store_true",
                   help="riapplica la patch se viene sovrascritta")
    p.add_argument("--addr", metavar="BD_ADDR",
                   help="limita al dispositivo con questo indirizzo Bluetooth")
    p.add_argument("--index", type=int,
                   help="quale candidato sostituire, se ce n'e' piu' di uno")
    p.add_argument("--force", action="store_true",
                   help="accetta un descriptor dall'aspetto insolito")
    args = p.parse_args()

    if (args.apply or args.restore or args.add_multitouch) and os.geteuid() != 0:
        die("serve sudo per scrivere %s" % PLIST)

    if args.restore:
        cmd_restore(args)
    elif args.add_multitouch:
        cmd_add_multitouch(args)
    elif args.watch:
        if not (args.apply or args.add_multitouch):
            die("--watch richiede --apply FILE oppure --add-multitouch")
        cmd_watch(args)
    elif args.apply:
        cmd_apply(args)
    elif args.show:
        cmd_show(args)
    else:
        p.print_help()


if __name__ == "__main__":
    main()
