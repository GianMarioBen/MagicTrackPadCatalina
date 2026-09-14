#!/usr/bin/env python3
"""
sdp_patch — dichiara a macOS il report multitouch 0x31 della Magic Trackpad.

Il problema
-----------
Per un dispositivo Bluetooth HID, il report descriptor che IOBluetoothHIDDriver
pubblica non viene letto dal dispositivo: viene preso dai record SDP messi in
cache in /Library/Preferences/com.apple.Bluetooth.plist, sotto

    DeviceCache/<indirizzo>/Services

che non e' un valore leggibile: e' un plist binario serializzato
(NSKeyedArchiver) dentro un blob. Il report descriptor e' uno degli oggetti
del suo array $objects.

Per la Magic Trackpad quel descriptor dichiara il report 0x02 da 8 byte, cioe'
il mouse di compatibilita', e il canale vendor. Il report multitouch 0x31 non
e' dichiarato affatto: e' per questo che IOHIDFamily lo scarta nel kernel
prima che raggiunga lo user space, anche quando il dispositivo lo trasmette.

La soluzione non richiede il descriptor originale di Apple. Basta aggiungere
in coda una collection che dichiari il report 0x31 lungo abbastanza.

Uso
---
    sudo ./sdp_patch.py --show
    sudo ./sdp_patch.py --show --addr 04:B5:B2:7A:B9:8F
    sudo ./sdp_patch.py --add-multitouch --addr 04:B5:B2:7A:B9:8F
    sudo ./sdp_patch.py --restore

Dopo --add-multitouch:
    sudo killall -9 cfprefsd bluetoothd
    (spegni e riaccendi il trackpad)
    ./tools/triage.sh        -> MaxInputReportSize deve valere 94, non 8
"""

import argparse
import os
import plistlib
import re
import shutil
import sys

PLIST = "/Library/Preferences/com.apple.Bluetooth.plist"
BACKUP_SUFFIX = ".mammetta-backup"

# Numero massimo di contatti che vogliamo poter ricevere.
MAX_CONTACTS = 10

# Il conteggio e' scelto perche' la lunghezza TOTALE del report (report ID
# compreso) valga 4 + 9*MAX_CONTACTS, cioe' la forma esatta del formato
# multitouch. Cosi' sia che macOS consegni la lunghezza realmente ricevuta,
# sia che riempia fino alla dimensione dichiarata, il decoder trova un numero
# intero di contatti, e quelli di riempimento hanno i bit di stato a zero e
# vengono scartati come dito sollevato.
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

# Sequenze con cui inizia il descriptor di un dispositivo di puntamento.
DESC_SIGNATURES = (
    b"\x05\x01\x09\x02\xA1\x01",   # Generic Desktop / Mouse
    b"\x05\x01\x09\x01\xA1\x01",   # Generic Desktop / Pointer
    b"\x05\x0D\x09\x05\xA1\x01",   # Digitizer / Touch Pad
)


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


class Descriptor:
    """Un report descriptor trovato in cache, con il modo per riscriverlo.

    Il descriptor puo' stare direttamente come valore, oppure — ed e' il caso
    reale — dentro l'archivio binario annidato del blob Services. Nel secondo
    caso riscriverlo significa modificare l'oggetto dentro l'archivio e
    riserializzare l'intero archivio nel blob.
    """

    def __init__(self, path, container, key, data,
                 archive=None, obj_index=None):
        self.path = path
        self.container = container
        self.key = key
        self.data = data
        self.archive = archive
        self.obj_index = obj_index

    @property
    def nested(self):
        return self.archive is not None

    def write(self, new_data):
        if self.nested:
            self.archive["$objects"][self.obj_index] = new_data
            self.container[self.key] = plistlib.dumps(self.archive,
                                                      fmt=plistlib.FMT_BINARY)
        else:
            self.container[self.key] = new_data
        self.data = new_data


def _looks_like_descriptor(b):
    return any(b.startswith(sig) for sig in DESC_SIGNATURES)


def find_descriptors(data, addr=None):
    """Cerca i report descriptor, anche dentro gli archivi annidati."""
    want = norm_addr(addr) if addr else None
    found = []

    def device_matches(node, path):
        if not want:
            return True
        # l'indirizzo puo' essere un segmento del percorso (DeviceCache)
        if any(norm_addr(seg) == want for seg in path):
            return True
        # oppure un campo del dizionario del dispositivo (CoreBluetoothCache)
        if isinstance(node, dict):
            da = node.get("DeviceAddress")
            if isinstance(da, str) and norm_addr(da) == want:
                return True
        return False

    def visit(node, path, device_ok):
        if isinstance(node, dict):
            ok = device_ok or device_matches(node, path)
            for k, v in node.items():
                if isinstance(v, (bytes, bytearray)):
                    inspect_blob(bytes(v), path + (str(k),), node, k, ok)
                else:
                    visit(v, path + (str(k),), ok)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                if not isinstance(v, (bytes, bytearray)):
                    visit(v, path + ("[%d]" % i,), device_ok)

    def inspect_blob(b, path, container, key, device_ok):
        if not device_ok:
            return
        if _looks_like_descriptor(b):
            found.append(Descriptor("/".join(path), container, key, b))
            return
        if b[:8] != b"bplist00":
            return
        try:
            archive = plistlib.loads(b)
        except Exception:
            return
        objs = archive.get("$objects") if isinstance(archive, dict) else None
        if not isinstance(objs, list):
            return
        for i, o in enumerate(objs):
            if isinstance(o, (bytes, bytearray)) and _looks_like_descriptor(bytes(o)):
                found.append(Descriptor(
                    "/".join(path) + "/<archivio>/$objects/[%d]" % i,
                    container, key, bytes(o), archive, i))

    visit(data, (), False)
    return found


def hexdump(b, limit=None):
    out = []
    end = len(b) if limit is None else min(len(b), limit)
    for i in range(0, end, 16):
        out.append("    " + " ".join("%02X" % x for x in b[i:i + 16]))
    if limit is not None and len(b) > limit:
        out.append("    ...")
    return "\n".join(out)


def report_ids(b):
    """Estrae i report ID dichiarati, per dire subito cosa c'e' e cosa manca."""
    ids, i = [], 0
    while i < len(b):
        pfx = b[i]
        size = {0: 1, 1: 2, 2: 3, 3: 5}[pfx & 3]
        if (pfx & 0xFC) == 0x84 and size == 2:      # Report ID
            ids.append(b[i + 1])
        i += size
    return ids


def cmd_show(args):
    data = load_plist()
    descs = find_descriptors(data, args.addr)
    if not descs:
        print("Nessun report descriptor in cache"
              + (" per %s" % args.addr if args.addr else "") + ".")
        return
    for i, d in enumerate(descs):
        print("[%d] %s" % (i, d.path))
        print("    %d byte, %s" % (len(d.data),
              "dentro un archivio annidato" if d.nested else "valore diretto"))
        ids = report_ids(d.data)
        print("    report dichiarati: %s"
              % (", ".join("0x%02X" % x for x in ids) or "nessuno"))
        print("    multitouch 0x31  : %s"
              % ("presente" if 0x31 in ids else "ASSENTE"))
        print(hexdump(d.data, 96))
        print()


def cmd_add_multitouch(args, quiet=False):
    data = load_plist()
    descs = find_descriptors(data, args.addr)
    if not descs:
        die("nessun descriptor in cache. Il trackpad e' connesso? "
            "Prova prima --show senza --addr.")

    if args.index is not None:
        descs = [descs[args.index]]

    changed = []
    for d in descs:
        if MULTITOUCH_COLLECTION in d.data:
            if not quiet:
                print("gia' a posto : %s" % d.path)
            continue
        if not quiet:
            print("da modificare: %s" % d.path)
            print("    %d -> %d byte" % (len(d.data),
                                         len(d.data) + len(MULTITOUCH_COLLECTION)))
        changed.append(d)

    if not changed:
        if not quiet:
            print("\nNiente da fare: la collection multitouch e' gia' presente.")
        return False

    backup = PLIST + BACKUP_SUFFIX
    if not os.path.exists(backup):
        shutil.copy2(PLIST, backup)
        if not quiet:
            print("\nBackup: %s" % backup)

    for d in changed:
        d.write(d.data + MULTITOUCH_COLLECTION)

    save_plist(data)

    if not quiet:
        print("\nAggiunta a %d descriptor la dichiarazione del report 0x31,"
              % len(changed))
        print("%d byte di dati, cioe' fino a %d contatti:" % (_COUNT, MAX_CONTACTS))
        print(hexdump(MULTITOUCH_COLLECTION))
        print("\nOra:")
        print("  sudo killall -9 cfprefsd bluetoothd")
        print("  spegni e riaccendi il trackpad e aspetta che si riconnetta")
        print("  ./tools/triage.sh        -> MaxInputReportSize deve valere %d"
              % (_COUNT + 1))
        print("  ./build/mammetta_bridge -v")
    return True


def cmd_restore(args):
    backup = PLIST + BACKUP_SUFFIX
    if not os.path.exists(backup):
        die("nessun backup in %s" % backup)
    shutil.copy2(backup, PLIST)
    print("Ripristinato da %s" % backup)
    print("Ora:  sudo killall -9 cfprefsd bluetoothd")


def cmd_watch(args):
    import subprocess
    import time
    print("Sorveglianza di %s — Ctrl-C per uscire.\n" % PLIST)
    last = 0
    while True:
        try:
            mtime = os.path.getmtime(PLIST)
            if mtime != last:
                last = mtime
                if cmd_add_multitouch(args, quiet=True):
                    print(">>> cache riscritta da bluetoothd, patch riapplicata "
                          "(%s)" % time.strftime("%H:%M:%S"))
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
        description="Dichiara a macOS il report multitouch 0x31.")
    p.add_argument("--show", action="store_true",
                   help="mostra i descriptor in cache e cosa dichiarano")
    p.add_argument("--add-multitouch", action="store_true",
                   help="aggiunge la dichiarazione del report 0x31")
    p.add_argument("--restore", action="store_true", help="ripristina il backup")
    p.add_argument("--watch", action="store_true",
                   help="riapplica la patch se viene sovrascritta")
    p.add_argument("--addr", metavar="BD_ADDR",
                   help="limita al dispositivo con questo indirizzo")
    p.add_argument("--index", type=int, help="agisci su un solo candidato")
    args = p.parse_args()

    if (args.add_multitouch or args.restore) and os.geteuid() != 0:
        die("serve sudo per scrivere %s" % PLIST)

    if args.restore:
        cmd_restore(args)
    elif args.watch:
        if not args.add_multitouch:
            die("--watch richiede --add-multitouch")
        cmd_watch(args)
    elif args.add_multitouch:
        cmd_add_multitouch(args)
    elif args.show:
        cmd_show(args)
    else:
        p.print_help()


if __name__ == "__main__":
    main()
