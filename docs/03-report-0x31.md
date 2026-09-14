# Formato dei report multitouch

Riferimento incrociato: driver Linux `hid-magicmouse.c` + le catture PacketLogger
decodificate su Catalina.

## Identificazione del dispositivo

Il vendor ID **cambia col transport**, ed e' un errore facile da fare:

| Transport | VendorID | ProductID |
|---|---|---|
| USB       | `0x05AC` (1452) — vendor USB di Apple | `0x0324` (804) |
| Bluetooth | `0x004C` (76) — company identifier Bluetooth | `0x0324` (804) |

Il ProductID e' lo stesso. Quindi il matching IOKit va fatto **sul solo
ProductID**, verificando il vendor dopo: un dizionario di matching con
VendorID 0x004C non trova nulla su USB.

Su USB il dispositivo espone inoltre **piu' interfacce** con lo stesso
VID/PID:

| UsagePage | Usage | cos'e' |
|---|---|---|
| `0x01` | `0x02` | mouse di compatibilita' |
| `0xFF00` | `0x0B` | vendor Apple |
| `0xFF00` | `0x0D` | vendor Apple, con endpoint di output da 64 byte |

Agganciarsi alla prima che capita significa quasi sempre prendere quella
sbagliata.

## Abilitazione

| Transport | Report ID | Payload feature |
|---|---|---|
| Bluetooth | `0xF1` | `F1 02 01` |
| USB       | `0x02` | `02 01` — **due byte soli** |

Il primo byte del payload e' il report ID. Su USB il comando e' quindi lungo
in tutto due byte: mandarne nove lo fa accettare da macOS ma non produce
effetto.

Va inviato come **feature report**. Dopo l'invio il dispositivo esce dalla
modalità mouse di compatibilità: il puntatore smette di muoversi (è la
conferma che il comando ha preso) e comincia a emettere report multitouch.

Il comando **va rinviato a ogni riconnessione**: dopo sleep, spegnimento del
trackpad o riconnessione Bluetooth il dispositivo torna in modalità mouse.

## Struttura del report

| Transport | Report ID | Header | Per contatto |
|---|---|---|---|
| Bluetooth | `0x31` | 4 byte | 9 byte |
| USB       | `0x02` | **12 byte** | 9 byte |

Attenzione al report ID su USB: **e' `0x02`, lo stesso del mouse di
compatibilita'**. I due si distinguono solo dalla lunghezza — 7 byte il mouse,
`12 + 9n` il multitouch. Filtrare per report ID significa buttare via proprio
i dati che si cercano.

Lunghezze USB: 21 byte = 1 dito, 30 = 2 dita, 39 = 3 dita, 48 = 4 dita.

Quindi su Bluetooth la lunghezza è sempre `4 + 9 × n_dita` (contando il byte
di report ID), che è esattamente la relazione osservata nelle catture:

```
1 dito  → 13 byte di report  (14 sul canale, con A1)
2 dita  → 22                 (23)
3 dita  → 31                 (32)
```

Il byte `A1` che si vede in PacketLogger è l'header di transazione HID-over-L2CAP
(`DATA | Input`), non fa parte del report.

Stato del pulsante: `data[1] & 1` (con `data[0]` = report ID).

## Blocco da 9 byte per contatto

Con `t[0..8]` i nove byte del contatto:

```
x           = (t[1] << 27 | t[0] << 19) >> 19        // 13 bit con segno
y           = -((t[3] << 30 | t[2] << 22 | t[1] << 14) >> 19)
touch_major = t[4]
touch_minor = t[5]
size        = t[6]
pressure    = t[7]
state       = t[3] & 0xC0     // 0x80 = dito appoggiato
id          = t[8] & 0x0F     // tracking id, stabile per tutta la gesture
orientation = (t[8] >> 5) - 4
```

Lo stato del contatto sta nei **due bit alti di `t[3]`**, non in `t[7]`: `t[3]`
porta sia i due bit piu' alti di y sia i due bit di stato, e `t[7]` e' la
pressione. Il Magic Trackpad di prima generazione usava invece `t[8]`, ed e' un
errore facile da ereditare leggendo il codice sbagliato.

Gli shift servono a fare l'estensione del segno: si porta il bit alto in cima
a un intero a 32 bit e si fa uno shift aritmetico a destra.

## Range delle coordinate (Magic Trackpad 2 / USB-C)

```
x ∈ [-3678, +3934]      ≈ 7612 unità su ~160 mm  →  ~47,6 unità/mm
y ∈ [-2478, +2587]      ≈ 5065 unità su ~115 mm  →  ~44   unità/mm
```

**Verso degli assi, verificato sul dispositivo**: dopo la decodifica x cresce
verso destra e **y cresce verso il basso**, cioe' verso il bordo vicino a chi
usa il trackpad — la stessa convenzione dello schermo, quindi in coordinate
schermo **non va invertita**.

E' il punto in cui e' piu' facile sbagliare. La negazione nella formula di y
serve proprio a ottenere questo verso; chi copia la formula e poi tratta la y
come se crescesse verso l'alto inverte tutto il verticale — puntatore e
scroll — e si ritrova le zone di bordo sul lato opposto del pad.

Questi valori sono coerenti con la tua cattura reale:

```
finger id=6  x=-747  y=1094  pressure=6   size=12
finger id=7  x=1153  y=895   pressure=12  size=17
finger id=8  x=217   y=537   pressure=11  size=14
```

## Tracking id

L'id a 4 bit è **stabile per la durata del contatto** e viene riusato dopo il
rilascio. È quello che permette di distinguere "due dita che scrollano" da
"un dito sollevato e riappoggiato", ed è il motivo per cui il bridge può fare
gesture serie e non solo delta grezzi.


## Fonte

Le costanti sono verificate contro `drivers/hid/hid-magicmouse.c` del kernel
Linux, che dalla 6.x gestisce esplicitamente questo modello:

```c
#define USB_DEVICE_ID_APPLE_MAGICTRACKPAD2_USBC  0x0324
#define TRACKPAD2_USB_REPORT_ID 0x02
#define TRACKPAD2_BT_REPORT_ID  0x31

const u8 feature_mt_trackpad2_usb[] = { 0x02, 0x01 };
const u8 feature_mt_trackpad2_bt[]  = { 0xF1, 0x02, 0x01 };

case TRACKPAD2_USB_REPORT_ID:
    /* Expect twelve bytes of prefix and N*9 bytes of touch data. */
    if (size < 12 || ((size - 12) % 9) != 0)
        return 0;
```

Il decoder dei contatti segue `magicmouse_emit_touch`, ramo
`USB_DEVICE_ID_APPLE_MAGICTRACKPAD2 / _USBC`.
