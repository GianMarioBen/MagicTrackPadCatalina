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
| USB       | `0x02` | `02 01 00 00 00 00 00 00 00` |

Va inviato come **feature report**. Dopo l'invio il dispositivo esce dalla
modalità mouse di compatibilità: il puntatore smette di muoversi (è la
conferma che il comando ha preso) e comincia a emettere report multitouch.

Il comando **va rinviato a ogni riconnessione**: dopo sleep, spegnimento del
trackpad o riconnessione Bluetooth il dispositivo torna in modalità mouse.

## Struttura del report

| Transport | Report ID | Header | Per contatto |
|---|---|---|---|
| Bluetooth | `0x31` | 4 byte | 9 byte |
| USB       | `0x02` | 6 byte | 9 byte |

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
state       = t[7] & 0xF0     // != 0 → dito giù
id          = t[8] & 0x0F     // tracking id, stabile per tutta la gesture
orientation = (t[8] >> 5) - 4
```

Gli shift servono a fare l'estensione del segno: si porta il bit alto in cima
a un intero a 32 bit e si fa uno shift aritmetico a destra.

## Range delle coordinate (Magic Trackpad 2 / USB-C)

```
x ∈ [-3678, +3934]      ≈ 7612 unità su ~160 mm  →  ~47,6 unità/mm
y ∈ [-2478, +2587]      ≈ 5065 unità su ~115 mm  →  ~44   unità/mm
```

y cresce verso l'alto (per questo il decoder lo nega): in coordinate schermo
va invertito di nuovo.

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
