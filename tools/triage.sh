#!/bin/bash
# Diagnostica: come vede questo Mac la Magic Trackpad USB-C.
# Eseguilo due volte: senza cavo (Bluetooth) e con il cavo collegato.
#
#   ./tools/triage.sh

PID_DEC=804     # 0x0324

echo "=== macOS ==="
sw_vers | sed 's/^/  /'
echo

echo "=== Istanze IOHIDDevice con ProductID 804 (0x0324) ==="
# ioreg -a produce XML: lo attraversiamo con python invece di fare a pezzi
# del testo con grep, che sui nodi annidati sbaglia facilmente.
/usr/bin/python3 - "$PID_DEC" <<'PY'
import plistlib, subprocess, sys

pid_wanted = int(sys.argv[1])
xml = subprocess.run(["ioreg", "-a", "-l", "-r", "-c", "IOHIDDevice"],
                     capture_output=True).stdout
if not xml.strip():
    print("  nessun IOHIDDevice trovato")
    raise SystemExit

try:
    tree = plistlib.loads(xml)
except Exception as e:
    print("  impossibile leggere ioreg: %s" % e)
    raise SystemExit

found = []

def walk(node):
    if isinstance(node, dict):
        if node.get("ProductID") == pid_wanted:
            found.append(node)
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

walk(tree)

if not found:
    print("  NESSUNA. Il trackpad non e' visto come IOHIDDevice su questo")
    print("  transport. Se hai appena collegato il cavo: e' un cavo dati?")
    raise SystemExit

KEYS = ["Product", "Transport", "VendorID", "ProductID", "VersionNumber",
        "MaxInputReportSize", "MaxOutputReportSize", "MaxFeatureReportSize",
        "PrimaryUsagePage", "PrimaryUsage", "LocationID", "SerialNumber"]

for i, d in enumerate(found):
    print("  [%d]" % i)
    for k in KEYS:
        if k in d:
            print("      %-22s %s" % (k, d[k]))
    print()

sizes = [d.get("MaxInputReportSize") for d in found
         if d.get("MaxInputReportSize") is not None]
print("  --- verdetto ---")
for d in found:
    t = d.get("Transport", "?")
    s = d.get("MaxInputReportSize")
    if s is None:
        print("      %-12s MaxInputReportSize assente" % t)
    elif s < 13:
        print("      %-12s MaxInputReportSize = %d  ->  i report multitouch"
              " vengono scartati dal kernel" % (t, s))
    else:
        print("      %-12s MaxInputReportSize = %d  ->  OK, i report possono"
              " arrivare in user space" % (t, s))
PY
echo

echo "=== A quale driver e' attaccato? ==="
for k in AppleMultitouchDevice AppleHSBluetoothDevice IOBluetoothHIDDriver \
         AppleUserHIDEventService IOHIDEventDriver AppleUSBMultitouchDevice \
         IOUSBHostHIDDevice; do
  n=$(ioreg -w0 -r -c "$k" 2>/dev/null | grep -c '+-o')
  printf '  %-28s %s istanze\n' "$k" "${n:-0}"
done
echo

echo "=== USB ==="
system_profiler SPUSBDataType 2>/dev/null \
  | grep -B2 -A9 -i 'trackpad' | sed 's/^/  /' \
  || echo "  nessun trackpad su USB"
echo

echo "=== Bluetooth ==="
system_profiler SPBluetoothDataType 2>/dev/null \
  | grep -A10 -i 'trackpad' | sed 's/^/  /' \
  || echo "  nessun trackpad su Bluetooth"
echo

echo "=== SIP ==="
csrutil status 2>/dev/null | sed 's/^/  /'
