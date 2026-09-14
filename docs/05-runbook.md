# Runbook — far funzionare il trackpad su Bluetooth

Perche' Bluetooth e non USB: [`04-usb.md`](04-usb.md). In breve, su USB il
report multitouch non e' dichiarato nel report descriptor, e su USB il
descriptor viene letto dal dispositivo — non e' modificabile. Su Bluetooth
viene dalla cache SDP di macOS, che invece si puo' riscrivere.

## Dove sta il descriptor

Non e' un valore leggibile nel plist. Sta dentro

```
DeviceCache/<indirizzo>/Services
```

che e' un blob binario contenente un plist serializzato (NSKeyedArchiver): il
descriptor e' uno degli oggetti del suo array `$objects`. Una seconda copia
sta sotto `CoreBluetoothCache/<UUID>/Services`, e vengono modificate entrambe.

Sulla macchina di prova e' lungo 135 byte e dichiara:

| Report | Cos'e' |
|---|---|
| `0x02` | mouse di compatibilita', 8 byte — da qui il `MaxInputReportSize = 8` |
| `0x55` | feature da 64 byte, canale comandi vendor |
| `0x90` | telemetria della batteria |

Il report `0x31` non e' dichiarato. E' la conferma, letta dal disco, del
motivo per cui IOHIDFamily scarta i report multitouch nel kernel: per macOS
quel report non esiste.

## Il principio

Non serve il descriptor originale di Apple. Serve solo che macOS **sappia
che esiste** un report `0x31` abbastanza lungo, altrimenti IOHIDFamily lo
scarta nel kernel prima che arrivi in user space.

Quindi si **aggiunge in coda** al descriptor esistente una collection vendor
di 23 byte:

```
06 00 FF     Usage Page (Vendor Defined 0xFF00)
09 31        Usage (0x31)
A1 01        Collection (Application)
  85 31        Report ID (0x31)
  09 31        Usage (0x31)
  15 00        Logical Minimum (0)
  26 FF 00     Logical Maximum (255)
  75 08        Report Size (8 bit)
  95 5D        Report Count (93)
  81 02        Input (Data, Var, Abs)
C0           End Collection
```

Il conteggio 93 non e' arbitrario: rende la lunghezza totale del report
`93 + 1 = 94 = 4 + 9 x 10`, cioe' la forma esatta del formato multitouch per
dieci contatti. Cosi' sia che macOS consegni la lunghezza realmente ricevuta,
sia che riempia fino alla dimensione dichiarata, il decoder trova sempre un
numero intero di contatti, e quelli di riempimento hanno i bit di stato a
zero e vengono scartati come dito sollevato. Verificato in entrambi i casi.

Il resto del descriptor non viene toccato: il mouse di compatibilita' resta
dichiarato com'era.

## Procedura

Scollega il cavo, riaccendi il Bluetooth, fai riconnettere il trackpad.

Nota: i blocchi qui sotto non contengono commenti. Nello zsh interattivo
`#` non introduce un commento (l'opzione `interactive_comments` e' disattiva
di default), quindi una riga di commento incollata viene eseguita come
comando, e un apostrofo al suo interno lascia il terminale appeso al prompt
`quote>`. Se succede, basta Ctrl-C.

**1.** Guarda cosa c'e' ora in cache.

```bash
cd ~/Desktop/MTCatalina
git pull && make
sudo ./tools/sdp_patch.py --show --addr 04:B5:B2:7A:B9:8F
```

**2.** Aggiungi la dichiarazione del report `0x31`. Il backup e' automatico.

```bash
sudo ./tools/sdp_patch.py --add-multitouch --addr 04:B5:B2:7A:B9:8F
sudo killall -9 cfprefsd bluetoothd
```

**3.** Spegni e riaccendi l'interruttore del trackpad, e aspetta che si
riconnetta.

**4.** Verifica: `MaxInputReportSize` deve valere 94, non 8.

```bash
./tools/triage.sh
```

**5.** Avvia il bridge.

```bash
./build/mammetta_bridge -v
```

## Cosa aspettarsi

Al passo 4, `MaxInputReportSize = 94` significa che macOS ha accettato il
descriptor modificato. Se vale ancora 8, `bluetoothd` ha rifatto la query SDP
e riscritto la cache: si riapplica la patch tenendola sotto sorveglianza con

```bash
sudo ./tools/sdp_patch.py --watch --add-multitouch --addr 04:B5:B2:7A:B9:8F
```

Al passo 5, il bridge invia `F1 02 01`, il puntatore di sistema si ferma (e'
il segnale che il cambio di modo e' avvenuto) e da quel momento il puntatore
lo muove il bridge.

## Per tornare indietro

```bash
sudo ./tools/sdp_patch.py --restore
sudo killall -9 cfprefsd bluetoothd
```

Il trackpad torna a comportarsi come prima, cioe' come un mouse.

## Se non funziona

Il punto di controllo e' uno solo: `MaxInputReportSize`.

- **Resta 8** → la patch non ha preso, o e' stata sovrascritta. Problema di
  cache SDP, non di protocollo.
- **Diventa 94 ma il bridge non riceve niente** → il descriptor e' a posto e
  il problema e' altrove: verifica con `./build/mt_enable --secs 20` che
  l'invio di `F1 02 01` riesca e guarda se il puntatore si ferma.
- **Diventa 94 e arrivano report `0x31`** → e' fatta.
