# La Magic Trackpad USB-C su USB

Analisi dei report descriptor letti dal dispositivo con `mt_enable --desc`
su macOS Catalina 10.15.8.

## Identita'

| | valore |
|---|---|
| VendorID USB | `0x05AC` (1452) — **non** `0x004C`, che e' il company id Bluetooth |
| ProductID | `0x0324` (804), uguale su entrambi i transport |
| Versione | `5.10` |

## Le tre interfacce

### [0] UsagePage `0x01` Usage `0x02` — mouse

```
05 01 09 02 A1 01 ...   Generic Desktop / Mouse / Collection(Application)
  85 02                 Report ID 0x02: 3 bit pulsanti + 5 padding
  09 30 09 31 ...       X e Y relativi, 8 bit con segno
  95 04 75 08 81 01     4 byte costanti
05 0D 09 05 A1 01       Digitizer / Touch Pad / Collection(Application)
  85 3F 95 10 81 22     Report ID 0x3F: 16 byte, dati vendor
06 00 FF 09 0C A1 01    Vendor 0xFF00
  85 44 96 6B 05 81 00  Report ID 0x44: 1387 byte
```

| Report | Tipo | Byte | Cos'e' |
|---|---|---|---|
| `0x02` | Input | 7 | mouse di compatibilita' |
| `0x3F` | Input | 17 | **multitouch** — sta in una collection `Digitizer / Touch Pad` |
| `0x44` | Input | 1388 | canale diagnostico / firmware |

Il `MaxInputReportSize = 1388` che si vede in `ioreg` viene da `0x44`, non
dal multitouch.

### [1] UsagePage `0xFF00` Usage `0x0D` — canale vendor

```
06 00 FF 09 0D A1 01
  85 3F 96 0F 00 81 02   Report ID 0x3F: 15 byte  Input
  85 53 96 3F 00 91 02   Report ID 0x53: 63 byte  Output
C0
```

| Report | Tipo | Byte | Cos'e' |
|---|---|---|---|
| `0x3F` | Input | 16 | canale dati |
| `0x53` | Output | 64 | **canale comandi** |

Questa e' l'unica interfaccia con un endpoint di output, e `0x53` e' **l'unico
output report dichiarato dall'intero dispositivo**.

15 byte di dati corrispondono a `6 + 9 x 1`, cioe' header piu' un contatto nel
layout del Magic Trackpad 2. Puo' essere una coincidenza, oppure questo modello
manda un report per dito invece di uno per fotogramma.

### [2] UsagePage `0xFF00` Usage `0x0B` — batteria

Contiene tre collection `06 00 FF 09 14` con dentro `05 84` = **Usage Page
Power Device**, usage `0x61` (Voltage), `0x44`/`0x46` (Charging/Discharging),
`0x65` (AbsoluteStateOfCharge), piu' i report `0x90`, `0x9B`, `0x9C`.

E' la telemetria della batteria. Non ha niente a che vedere col multitouch: il
`MaxInputReportSize = 14` veniva dal report `0x9B`.

## Perche' i primi tentativi non potevano funzionare

1. **Feature report.** Nessuna interfaccia dichiara feature report
   (`MaxFeatureReportSize = 1`). Il `F1 02 01` che funziona su Bluetooth non
   ha proprio un canale su cui passare, e infatti `IOHIDDeviceSetReport`
   restituisce `0xE0005000`.

2. **Output report con l'ID sbagliato.** Il comando di abilitazione del Magic
   Trackpad 2 USB usa il report ID `0x02`. Qui l'unico output dichiarato e'
   `0x53`: mandare `0x02` fa restituire `kIOReturnSuccess` a macOS, che
   spedisce comunque i byte, ma il dispositivo scarta un report ID che non
   conosce.

Quindi il canale giusto e': **output report `0x53` sull'interfaccia
`0xFF00 / 0x0D`**, e la risposta attesa e' l'input report `0x3F`.

Il contenuto del comando, pero', non e' documentato. `mt_sweep` prova una
matrice di candidati.

## Esito: il comando e' quello classico, mandato bene

Lo sweep dei candidati non ha prodotto nulla, ma la risposta era nel driver
Linux `hid-magicmouse.c`, che questo modello lo gestisce esplicitamente:

```c
const u8 feature_mt_trackpad2_usb[] = { 0x02, 0x01 };
```

Due byte, non nove, e **come feature report** — nonostante
`MaxFeatureReportSize` valga 1 su tutte le interfacce, la richiesta passa
sull'interfaccia mouse.

E i dati tornano indietro con **report ID `0x02`, lo stesso del mouse di
compatibilita'**, distinguibili solo dalla lunghezza (`12 + 9n` contro 7).

Questo spiega perche' i tentativi precedenti sembravano fallire pur essendo
andati a buon fine: sia `mt_enable` sia `mt_sweep` classificavano i report per
ID, e scartavano `0x02` come "gia' noto". Il comando aveva funzionato e la
risposta veniva buttata via.

Morale: il canale vendor `0x53` / `0x3F` identificato dal descriptor esiste,
ma non e' quello del multitouch. Serve ad altro.

## Se serve catturare il traffico vero

A quel punto conviene **catturare la sequenza vera invece di indovinarla**.
Il modo piu' rapido e' una macchina Linux, anche un Raspberry Pi:

```bash
sudo modprobe usbmon
# collega il trackpad, individua il bus con lsusb
lsusb | grep 05ac:0324
# cattura (bus 1 nell'esempio)
sudo cat /sys/kernel/debug/usb/usbmon/1u > cattura.txt
```

Poi si cerca nel file il traffico verso l'endpoint di output: il driver
`hid-magicmouse` invia la sua sequenza di inizializzazione all'attach, e li'
dentro c'e' il comando esatto per questo modello, insieme al formato reale dei
report `0x3F` che seguono.

Alternativa senza Linux: Wireshark con USBPcap su Windows, oppure — visto che
il dispositivo funziona nativamente su macOS moderno — un secondo Mac su cui
leggere il traffico con `IOUSBHostFamily` in debug.

## Nota sul Bluetooth

Su Bluetooth questo stesso dispositivo **parla il protocollo classico**: dopo
`F1 02 01` emette report `0x31` nel formato del Magic Trackpad 2, come provato
dalle catture PacketLogger (vedi `docs/01-handoff.md`). Su USB usa invece
questo transport vendor piu' recente.

E' un'asimmetria utile da ricordare: se la strada USB si impantana, quella
Bluetooth ha un protocollo gia' noto e gia' decodificato — le manca solo il
report descriptor giusto nella cache SDP (`docs/02-analisi.md`, traccia B).
