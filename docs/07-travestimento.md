# Far dichiarare al dispositivo il ProductID del modello Lightning

## L'idea

I due modelli di Magic Trackpad sono **funzionalmente identici**: stesso
Force Touch, stesso Taptic Engine, stesso multi-touch, stessa superficie.
Cambia il connettore, e cambia il ProductID:

| Modello | ProductID | Catalina |
|---|---|---|
| Magic Trackpad 2, Lightning | `0x0265` (613) | **supportato nativamente** |
| Magic Trackpad, USB-C | `0x0324` (804) | sconosciuto |

Il supporto nativo per 613 e' gia' installato, dentro

```
/System/Library/Extensions/AppleTopCase.kext/Contents/PlugIns/
    AppleHSBluetoothDriver.kext/Contents/Info.plist
```

nella personality `Trackpad Device`, che dichiara `VendorID = 76`,
`ProductID = 613`, `PSM = 17`, `IOClass = AppleHSBluetoothDevice`.

E il ProductID del dispositivo e' un valore scritto nella cache Bluetooth,
che sappiamo modificare.

## Perche' non e' il tentativo di stamattina

Il primo approccio aveva modificato il **driver** perche' accettasse 804:
personality clonata, `IOProbeScore` alzato, injector caricato. Non ha
funzionato perche' la decisione di instradare il dispositivo verso
`IOBluetoothHIDDriver` viene presa prima, da `bluetoothd`, e una personality
alternativa non revoca un attach gia' avvenuto (vedi
[`02-analisi.md`](02-analisi.md) §1).

Qui si modifica il **dispositivo** perche' dichiari 613. E' lo stesso numero
che `bluetoothd` legge *prima* di scegliere il driver.

Soprattutto: non si sta camuffando un dispositivo diverso. Sappiamo per prova
diretta che questa trackpad, su Bluetooth, parla esattamente il protocollo
che `AppleHSBluetoothDriver` si aspetta dal PID 613 — `F1 02 01` seguito da
report `0x31` nel formato del Magic Trackpad 2. Il ProductID e' l'unica cosa
che li distingue.

## Procedura

**1.** Guarda dove compare il ProductID.

```bash
sudo ./tools/sdp_patch.py --show-pid --addr 04:B5:B2:7A:B9:8F
```

**2.** Applica il travestimento. Il backup e' automatico.

```bash
sudo ./tools/sdp_patch.py --spoof-pid --addr 04:B5:B2:7A:B9:8F
sudo killall -9 cfprefsd bluetoothd
```

**3.** Spegni e riaccendi il trackpad, aspetta che si riconnetta. **Non
avviare il bridge**: se il driver nativo si aggancia, i due si
contenderebbero il dispositivo.

**4.** Verifica.

```bash
ioreg -r -c AppleHSBluetoothDevice -l | head -40
ioreg -r -c AppleMultitouchDevice | grep -c '+-o'
```

## Esiti

| | |
|---|---|
| compare `AppleHSBluetoothDevice` | il travestimento e' stato accettato: trackpad nativo, gesture e Force Touch, pannello nelle Preferenze di Sistema, niente bridge e niente patch del descriptor |
| non compare, ma il trackpad funziona ancora come mouse | `bluetoothd` non usa quel valore per instradare, oppure il driver rifiuta il dispositivo per altri campi (versione firmware, `LMPSubversion`) |
| il trackpad non funziona piu' | nessun driver si e' agganciato: ripristina |

## Ripristino

```bash
sudo ./tools/sdp_patch.py --restore
sudo killall -9 cfprefsd bluetoothd
```

Riporta ProductID e report descriptor ai valori originali.

## Cosa puo' andare storto

`bluetoothd` potrebbe rifare la query SDP alla riconnessione e riscrivere il
ProductID vero. In quel caso il valore torna 804 da solo, e lo si vede con
`--show-pid`.

Il driver nativo potrebbe inoltre controllare altri campi oltre al ProductID
— la versione firmware, per esempio, qui `0x0319`. Se li controlla, il
travestimento non basta.
