# Magic Trackpad USB-C su macOS Catalina

Far funzionare una **Apple Magic Trackpad USB-C** (VID `0x004C`, PID `0x0324`)
come vero trackpad su **macOS Catalina 10.15.8 (19H2036)**, che oggi la vede
solo come mouse generico.

Stato del lavoro pregresso: [`docs/01-handoff.md`](docs/01-handoff.md)
Analisi e strategia attuale: [`docs/02-analisi.md`](docs/02-analisi.md)
Formato dei report multitouch: [`docs/03-report-0x31.md`](docs/03-report-0x31.md)

## In due righe

Il trackpad, dopo il feature report `F1 02 01`, trasmette veri report
multitouch HID (`0x31` su Bluetooth, `0x02` su USB). Il problema **non** è il
dispositivo: è che Catalina ha pubblicato un `IOHIDDevice` con il *report
descriptor di compatibilità mouse* (`MaxInputReportSize = 8`), quindi il
kernel butta via i report da 14/23/32 byte prima che arrivino allo user space.

La soluzione non è sniffare l'HCI. È **dare a Catalina il report descriptor
giusto**, e poi leggere i report con una normalissima `IOHIDManager` e
tradurli in `CGEvent`.

## Layout

```
tools/triage.sh          diagnostica: come vede il trackpad questo Mac
tools/mt_desc_dump.c     dump del report descriptor reale (da un Mac moderno)
tools/mt_enable.c        invia il comando di abilitazione multitouch
tools/sdp_patch.py       sostituisce il descriptor nella cache SDP Bluetooth
tools/mt_decode.py       decoder offline dei .pklg / dump esadecimali
src/mammetta_bridge.m    daemon: legge i report 0x31 e genera CGEvent
Makefile                 build di tutto
```

## Build

```bash
make            # compila tutto in ./build
make bridge     # solo il daemon
```

Richiede Xcode Command Line Tools. Testato per il target 10.15.
