# Indagine: il canale comandi vendor

Obiettivo: scoprire se la Magic Trackpad USB-C puo' essere configurata per
emettere report multitouch a **lunghezza fissa**. Se esistesse un comando per
farlo, il vincolo descritto in [`05-runbook.md`](05-runbook.md) cadrebbe e si
avrebbe il multitouch pieno su Catalina.

## Perche' proprio questo

Il report descriptor originale del dispositivo dichiara, oltre al mouse di
compatibilita' e alla batteria, un canale comandi:

```
06 02 FF     Usage Page (Vendor Defined 0xFF02)
09 55        Usage (0x55)
85 55        Report ID (0x55)
15 00 26 FF 00
75 08 95 40  64 byte
B1 A2        Feature
```

Cioe' **feature report `0x55`, 64 byte**, su Bluetooth. Su USB esiste il
gemello: output report `0x53`, 64 byte, sull'interfaccia vendor `0xFF00/0x0D`
(vedi [`04-usb.md`](04-usb.md)).

Il protocollo di questo canale non e' documentato, e il driver Linux
`hid-magicmouse` non lo usa affatto: manda solo `F1 02 01` e poi si arrangia
con report a lunghezza variabile, cosa che sul suo stack e' possibile perche'
riceve il buffer grezzo qualunque lunghezza abbia.

Tentare a caso non ha senso: 64 byte di spazio di comando sono troppi.

## Il modo serio: guardare cosa fa Apple

Sul Mac recente lo stesso trackpad funziona nativamente. Qualunque cosa
faccia macOS moderno per inizializzarlo, la si puo' **osservare**.

1. Sul Mac recente, apri PacketLogger e avvia la cattura.
2. Spegni e riaccendi il trackpad, e aspetta che si riconnetta. La sequenza
   di inizializzazione passa tutta in quel momento.
3. Ferma la cattura e salvala.

Nel file cerca il traffico **verso** il dispositivo, cioe' le SET_REPORT sul
canale di controllo. Interessa tutto quello che non sia `F1 02 01`, e in
particolare qualsiasi feature report `0x55`.

Il decoder in `tools/mt_decode.py --pklg` legge i report in arrivo; per quelli
in uscita conviene guardare direttamente la GUI, che li mostra con direzione e
payload.

## Cosa cercare

| Se si vede | Significa |
|---|---|
| solo `F1 02 01` | macOS moderno usa lo stesso comando, e la lunghezza variabile la gestisce nel suo stack: nessun comando da trovare, la strada e' chiusa |
| uno o piu' `0x55 ...` prima o dopo l'enable | c'e' una configurazione, e vale la pena capirla |
| report in arrivo a lunghezza **fissa** | il dispositivo e' stato configurato per farlo, e il comando e' in quella cattura |

La terza riga e' la piu' facile da verificare, e da sola risponde alla domanda:
**su un Mac dove il trackpad funziona, i report `A1 31` hanno tutti la stessa
lunghezza, oppure variano col numero di dita?**

Se variano, non c'e' niente da trovare: Apple gestisce la lunghezza variabile
nel kernel, come Linux, e su Catalina quella porta resta chiusa.

## Nota

Le catture della GUI di PacketLogger contengono i payload completi; quelle
della CLI no, per lo scrubbing descritto in [`02-analisi.md`](02-analisi.md).
Usa la GUI.
