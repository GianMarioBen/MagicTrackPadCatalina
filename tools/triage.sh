#!/bin/bash
# Diagnostica: come vede questo Mac la Magic Trackpad USB-C.
# Eseguilo due volte: senza cavo (Bluetooth) e con il cavo collegato.

VID=0x004C
PID=0x0324

echo "=== macOS ==="
sw_vers
echo

echo "=== Il device e' presente in IOKit? ==="
ioreg -w0 -l -r -c IOHIDDevice 2>/dev/null | awk '
  /\+-o / { name=$0; buf="" }
  { buf = buf "\n" $0 }
  /"ProductID" = 804/ { print name; print buf; buf="" }
' | grep -Ei 'IOHIDDevice|Product|VendorID|ProductID|Transport|MaxInputReportSize|MaxFeatureReportSize|ReportInterval|LocationID' \
  | sed 's/^[[:space:]]*/  /'
echo

echo "=== MaxInputReportSize (il numero che conta) ==="
echo "  8   -> descriptor di compatibilita' mouse: i report 0x31 vengono scartati"
echo "  >32 -> descriptor reale: i report multitouch arrivano in user space"
ioreg -w0 -l -r -c IOHIDDevice 2>/dev/null \
  | grep -B40 '"ProductID" = 804' \
  | grep 'MaxInputReportSize' | sed 's/^[[:space:]]*/  /'
echo

echo "=== A quale driver e' attaccato? ==="
for k in AppleMultitouchDevice AppleHSBluetoothDevice IOBluetoothHIDDriver \
         AppleUserHIDEventService IOHIDEventDriver AppleUSBMultitouchDevice; do
  n=$(ioreg -w0 -r -c "$k" 2>/dev/null | grep -c '+-o')
  printf '  %-28s %s\n' "$k" "${n:-0} istanze"
done
echo

echo "=== Transport ==="
system_profiler SPBluetoothDataType 2>/dev/null \
  | grep -A12 -i 'trackpad' | sed 's/^/  /'
echo "  --- USB ---"
system_profiler SPUSBDataType 2>/dev/null \
  | grep -A8 -i 'trackpad' | sed 's/^/  /'
echo

echo "=== Cache SDP Bluetooth (dove vive il report descriptor) ==="
if [ -f /Library/Preferences/com.apple.Bluetooth.plist ]; then
  if sudo -n true 2>/dev/null || [ "$EUID" -eq 0 ]; then
    sudo plutil -p /Library/Preferences/com.apple.Bluetooth.plist 2>/dev/null \
      | grep -ci 'SDPServiceRecords' | sed 's/^/  record SDP in cache: /'
  else
    echo "  (serve sudo per leggerla: sudo $0)"
  fi
else
  echo "  non trovata"
fi
echo

echo "=== SIP ==="
csrutil status | sed 's/^/  /'
