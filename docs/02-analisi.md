# Analisi e strategia

## 1. Perché la strada kext non poteva funzionare

L'injector su `AppleHSBluetoothDriver` è stato costruito bene (personality
accettata da `IOCatalogue`, `kextutil` soddisfatto), ma non poteva attaccarsi,
per un motivo strutturale e non di matching:

1. **Il canale L2CAP ha già un proprietario.** Chi decide a quale driver
   consegnare un canale L2CAP in ingresso non è `IOCatalogue` in modo
   simmetrico: è `bluetoothd` + `IOBluetoothFamily`, che per un device il cui
   record SDP dichiara il servizio HID istanzia `IOBluetoothHIDDriver` e gli
   passa PSM 17/19. Quando la nostra personality viene consultata, il canale è
   già stato aperto e posseduto. `IOProbeScore` ordina i candidati *sullo
   stesso provider nello stesso istante di matching*; non revoca un attach già
   avvenuto. Ecco perché alzarlo a 1000 non ha cambiato nulla.

2. **`AppleHSBluetoothDevice` non è un driver HID generico.** "HS" sta per il
   percorso proprietario Apple (lo stesso di TopCase/Lightning). Il suo
   `start()` esegue una sequenza di init specifica del modello e si aspetta il
   device dentro quel percorso di pairing. Anche se gli avessi consegnato il
   canale, il probe interno lo avrebbe rifiutato: è esattamente la conclusione
   a cui eri arrivato al punto 3 dell'handoff, ed è corretta.

3. Anche se avesse funzionato, ti servirebbe SIP disabilitato per sempre. Non
   è un punto d'arrivo accettabile.

**Conclusione: la strada kernel è chiusa, e va bene così — non serve.**

## 2. Perché PacketLogger è un vicolo cieco (e va abbandonato)

Lo scrubbing dei payload HID non lo fa la CLI: lo fa **`bluetoothd`**, prima di
emettere il pacchetto sul canale di trace, in base al privilegio del
consumatore. La GUI di PacketLogger ottiene lo stream non filtrato perché è
firmata Apple e usa un percorso privato (le stringhe
`setSkipAuthentication:authorization:` che hai trovato sono la traccia di
quel meccanismo).

Le conseguenze pratiche:

- Non esiste un "file temporaneo" da intercettare: la GUI tiene la cattura in
  memoria e la serializza al salvataggio — è esattamente il comportamento che
  hai osservato con `MammettaLiveTap.py` (offset fermo a 44145).
- Anche se trovassi il framework privato, dipenderesti da un entitlement che
  non puoi ottenere e da un binario Apple che non puoi ridistribuire.
- E soprattutto: **anche vincendo, otterresti una pipeline di debug, non un
  driver.** Latenza alta, dipendenza da un'app aperta, permessi root.

La curiosità sul perché 3 dita passino e 1 e 2 no è legittima (quasi certamente
un filtro euristico sulla lunghezza/forma del payload considerato "digitazione"
e quindi privacy-sensitive), ma non porta da nessuna parte di utile.

## 3. La diagnosi vera

Il blocco è in **una riga sola**:

```
MaxInputReportSize = 8
```

`IOBluetoothHIDDriver` pubblica un `IOHIDDevice` il cui report descriptor è
quello di *compatibilità mouse*. IOHIDFamily alloca i buffer e valida i report
in ingresso su quel descriptor: un report `0x31` da 32 byte, per quel device,
**non esiste**. Viene scartato nel kernel, molto prima di IOHIDManager. Ecco
perché il tuo `MammettaMTProbe` dice `Reports received: 0` pur avendo il
dispositivo aperto correttamente.

Quindi non serve un rubinetto raw. Serve **dire a Catalina come è fatto
davvero questo dispositivo**. Fatto questo, i report `0x31` arrivano in user
space per via ordinaria, per 1, 2, 3, 5 dita, senza scrubbing, senza root,
senza SIP disabilitato, con latenza da driver.

## 4. Il piano, in ordine di costo crescente

### Traccia A — USB (30 minuti, da fare per prima)

È un **Magic Trackpad USB-C**. Collegalo col cavo.

Su USB il report descriptor **non viene dalla cache SDP: viene letto dal
dispositivo**. Quindi Catalina riceve il descriptor vero, con il report
multitouch (su USB è il report ID `0x02`, header di 6 byte anziché 4), e
IOHIDFamily lo accetta senza che tu debba toccare niente.

Due esiti possibili, entrambi buoni:

- `AppleMultitouchDevice` compare da solo → hai finito, trackpad nativo via cavo.
- Non compare → ma `IOHIDManager` riceve comunque i report: il bridge in
  `src/` funziona via cavo **oggi stesso**.

In più, se serve un injector, la personality USB di `AppleMultitouchDriver` è
molto meno model-specific di quella Bluetooth: è lì che un PID injection ha
qualche probabilità reale.

Comando: `tools/triage.sh` con il cavo inserito. Guarda `MaxInputReportSize`:
se è ~64 anziché 8, sei dentro.

### Traccia B — Patch del report descriptor su Bluetooth (la soluzione)

Per un device Bluetooth HID, il report descriptor che `IOBluetoothHIDDriver`
pubblica proviene dall'attributo SDP **`0x0206` (HIDDescriptorList)**, messo in
cache al pairing dentro:

```
/Library/Preferences/com.apple.Bluetooth.plist
  → CachedDevices → <indirizzo> → SDPServiceRecords → <servizio HID> → 518
```

(518 decimale = 0x0206.)

Il piano:

1. Sul Mac moderno dove il trackpad funziona, dumpa il report descriptor vero
   con `tools/mt_desc_dump` (legge `kIOHIDReportDescriptorKey`).
2. Su Catalina, con `tools/sdp_patch.py`, sostituisci il blob nella cache SDP
   (backup automatico dell'originale).
3. `sudo killall -9 bluetoothd`, riconnetti il trackpad.
4. Ricontrolla con `tools/triage.sh`: `MaxInputReportSize` deve essere salito.

A quel punto `IOHIDDeviceRegisterInputReportCallback` riceve i `0x31` live.

Due avvertenze oneste:

- `bluetoothd` può rifare la query SDP alla riconnessione e riscrivere la
  cache. Se succede, il patch va riapplicato: `sdp_patch.py --watch` lo fa.
- Se esponi il report `0x31` come collection digitizer standard, Catalina
  potrebbe provare a interpretarlo da sé (male). Se dà fastidio, usa
  `--vendor-usage`: marca la collection come vendor-defined, così nessun
  driver di sistema la rivendica e resta tutta al nostro bridge.

### Traccia C — Possesso diretto del canale L2CAP (fallback)

Il tuo tentativo con `setDelegate` su un canale esistente non poteva
funzionare: il canale è già posseduto dal kext, e `setDelegate` non è
promiscuo. L'unica variante che ha senso è **registrarsi prima che il canale
esista**:

```objc
[IOBluetoothL2CAPChannel registerForChannelOpenNotifications:self
    selector:@selector(channelOpened:channel:)
    withPSM:19
    direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
```

e tenere il processo vivo *prima* che il trackpad si riconnetta. Vale un test
da mezz'ora, ma resta una corsa contro `IOBluetoothHIDDriver`: ci provi solo
se la Traccia B viene riscritta da `bluetoothd` in modo irreparabile.

### Traccia D — Multitouch nativo

Va detto chiaramente: **`AppleMultitouchDevice` non è falsificabile da user
space.** Non è un device HID, è un nodo IOKit pubblicato da un kext. Senza
scrivere un kext (SIP, firma, nessun futuro oltre Catalina) l'obiettivo
"integrazione nativa" non è raggiungibile.

Il che significa che l'obiettivo pratico — puntatore, scroll a due dita,
click destro, gesture — si raggiunge meglio dal bridge user space. E si
raggiunge *tutto*.

## 5. Il bridge

`src/mammetta_bridge.m` è un daemon che:

- trova il device (VID `0x004C`, PID `0x0324`), USB o Bluetooth;
- invia il comando di abilitazione multitouch giusto per il transport;
- lo rinvia automaticamente a ogni riconnessione (è la ragione per cui dopo
  ogni sleep ti si "rompeva" tutto);
- decodifica i contatti (id, x, y, pressione, dimensione, stato);
- genera `CGEvent`: puntatore con accelerazione, scroll pixel-preciso con
  fasi (quindi inerzia ed elastico veri), click, click destro a due dita,
  tap-to-click, swipe a tre dita.

Perché lo scroll con le fasi conta: `kCGScrollWheelEventScrollPhase`
(began/changed/ended) è ciò che fa capire a macOS che stai usando un trackpad
e non una rotella. Senza, lo scroll è a scatti e non hai né momentum né
rubber-banding.

## 6. Ordine operativo consigliato

```
1. tools/triage.sh              (senza cavo, poi col cavo)
2. se USB espone i report  → make bridge && ./build/mammetta_bridge
3. mt_desc_dump sul Mac moderno → sdp_patch.py su Catalina
4. triage.sh di nuovo: MaxInputReportSize salito?
5. bridge su Bluetooth
6. csrutil enable  (non serve più niente di tutto questo)
```
