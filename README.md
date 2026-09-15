# Magic Trackpad USB-C su macOS Catalina

Far funzionare una **Apple Magic Trackpad USB-C** (VID `0x004C`, PID `0x0324`)
su **macOS Catalina 10.15.8**, che la riconosce solo come mouse generico.

## Risolto

Catalina ha gia' il driver nativo per la Magic Trackpad — ma per il modello
**Lightning**, PID `0x0265`. I due modelli sono funzionalmente identici:
stesso Force Touch, stesso Taptic Engine, stesso multi-touch. Cambia il
connettore, e cambia quel numero.

Quel numero sta nella cache Bluetooth di macOS. Riscrivendolo, Catalina
riconosce il dispositivo e gli affida il driver nativo:

```bash
sudo ./tools/sdp_patch.py --spoof-pid --addr <indirizzo del trackpad>
sudo killall -9 cfprefsd bluetoothd
```

Poi si spegne e riaccende il trackpad. Trackpad nativo: multi-touch completo,
Force Touch, gesture, pannello nelle Preferenze di Sistema. Nessun kext,
nessun bridge, SIP attivo.

Procedura completa e ripristino: [`docs/07-travestimento.md`](docs/07-travestimento.md).

**Confermato funzionante anche su macOS High Sierra 10.13.6 (17G14042)**, con
lo stesso identico dispositivo, la stessa procedura, SIP sempre attivo. La
struttura della cache Bluetooth su 10.13.6 è risultata praticamente identica
a quella di Catalina — stesso archivio annidato, stesso punto dove si nasconde
il ProductID. Il Magic Trackpad 2 Lightning richiede solo macOS 10.11 (El
Capitan) o successivo, quindi il driver nativo è disponibile su qualunque
versione da lì in poi.

## Il resto del repo

Tutto quello che c'e' oltre a questo e' il percorso fatto per arrivarci, e
resta utile a chi debba capire come macOS tratta un dispositivo HID
Bluetooth non riconosciuto.

| | |
|---|---|
| [`01-handoff.md`](docs/01-handoff.md) | stato iniziale dell'indagine |
| [`02-analisi.md`](docs/02-analisi.md) | perche' l'injector kext e la pista PacketLogger non potevano funzionare |
| [`03-report-0x31.md`](docs/03-report-0x31.md) | protocollo multitouch completo, verificato sul dispositivo |
| [`04-usb.md`](docs/04-usb.md) | i tre report descriptor su USB, decodificati |
| [`05-runbook.md`](docs/05-runbook.md) | la regola con cui IOHIDFamily filtra i report per lunghezza |
| [`06-indagine-vendor.md`](docs/06-indagine-vendor.md) | il canale comandi vendor, rimasto inesplorato |

Il bridge in `src/` legge i report multitouch e li traduce in eventi di
sistema. Serviva quando il driver nativo non si agganciava; ora non serve
piu', ma resta funzionante e documentato.

## Strumenti

```
tools/sdp_patch.py       travestimento del ProductID, patch del descriptor, ripristino
tools/bt_cache_dump.py   dove macOS tiene i dati dei dispositivi Bluetooth
tools/triage.sh          come questo Mac vede il trackpad
tools/mt_enable.c        abilita il multitouch e osserva i report
tools/mt_decode.py       decodifica report e catture PacketLogger
tools/syntax-check/      analisi dei sorgenti macOS su qualunque macchina
```

## Ripristino

```bash
sudo ./tools/sdp_patch.py --restore
sudo killall -9 cfprefsd bluetoothd
```

Riporta ProductID e report descriptor ai valori originali. **Annulla anche il
travestimento**, quindi va usato solo per tornare davvero indietro.
