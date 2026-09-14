# Handoff — stato al 14/09/2026

Lavoro svolto prima di questo repo. Riassunto per non rifare l'archeologia.

## Hardware

Mac di test: MacBook Pro Intel, macOS Catalina 10.15.8 (`19H2036`),
Bluetooth Broadcom, `AppleMultitouchDriver 3440.1.1`, `AppleHSBluetoothDriver 3430.1`.

Magic Trackpad USB-C: VID `0x004C`, PID `0x0324`, firmware `0x0319`,
BD_ADDR `04:B5:B2:7A:B9:8F`. Funziona nativamente su macOS moderno.

## Cosa è già dimostrato

| Fatto | Esito |
|---|---|
| Il trackpad si collega su Catalina | ✅ come mouse generico |
| Si attacca a `IOBluetoothHIDDriver` / `AppleUserHIDEventService` | ✅ |
| Non si attacca a `AppleMultitouchDevice` / `AppleHSBluetoothDevice` | ✅ (mai comparso) |
| Catalina può inviare `F1 02 01` | ✅ `IOHIDDeviceSetReport` → `kIOReturnSuccess` |
| Dopo `F1 02 01` il puntatore si ferma | ✅ (esce dalla modalità mouse) |
| Il trackpad trasmette veri report `A1 31` | ✅ provato con PacketLogger |
| I report contengono tracking id, x, y, pressione, size | ✅ decodificati |
| `IOHIDManager` riceve quei report | ❌ `Reports received: 0` |

## Tentativi chiusi

**Injector kext su `AppleHSBluetoothDriver`** (PID 613→804, poi versione
permissiva solo PSM 17 + `IOProbeScore 1000`): personality accettata da
`IOCatalogue`, ma `ioreg -r -c AppleHSBluetoothDevice` sempre vuoto.
Motivo in [`02-analisi.md`](02-analisi.md) §1.

**Lettura raw L2CAP** con `setDelegate` su canale esistente: 0 pacchetti.
Il canale è già posseduto da `IOBluetoothHIDDriver` e `setDelegate` non è
promiscuo.

**PacketLogger CLI**: applica scrubbing ai payload di 1 e 2 dita
(`Scrubbed ACL Receive`), lascia passare quelli di 3 dita. Verificato con
scanner binario sul `.pklg`: 199 header a 1 dito e 174 a 2 dita tutti senza
payload, 225 a 3 dita tutti completi. Lo scrubbing avviene **prima** della
scrittura del file.

**PacketLogger GUI**: salva tutto completo, ma tiene la cattura in memoria —
il tail live del `.pklg` non vede crescere il file. Motivo in
[`02-analisi.md`](02-analisi.md) §2.

## Stato del sistema

SIP era stato disabilitato (`csrutil disable`) per i test kext. Le personality
caricate con `kextutil -m` erano transitorie; `/System/Library/Extensions` non
è stata modificata. **Nulla di quanto c'è in questo repo richiede SIP off**:
va riabilitato da Recovery con `csrutil enable`.

Il file `/Library/Preferences/com.apple.MobileBluetooth.debug.plist` creato per
il debug (`HCITraces`, `HCISkipAuth`) può essere rimosso.
