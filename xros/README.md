# Henge auf visionOS: Machbarkeitstest

Stand 13.11.2026, auf Henge-Commit `e98920c`. Ziel war die Frage, ob sich Henge, das macOS auf iPhone und iPad
emuliert, für Apple Vision Pro bauen lässt.

## Ergebnis

| Schritt | Ergebnis |
| --- | --- |
| Engine (JIT, MMU, Geräte, Metal-Renderer) für visionOS | baut ohne Quelltextänderung |
| Installer (libimobiledevice, usbmuxd, idevicerestore) | baut |
| Mac-Apps-Schicht (`tl/`) | baut |
| libffi, glib, libslirp | bauen mit eigenem Skript |
| App `HengeVision` für Simulator und Gerät | baut und linkt |
| Start im visionOS-27-Simulator | läuft, Oberfläche erscheint |
| JIT-Selbsttest im Simulator | bestanden |
| Start auf Apple Vision Pro M5, visionOS 27.3 | läuft, Speicherlimit 8187 MB |
| **JIT auf der Vision Pro über lldb** | **bestanden**, 512 MB Region, Code lief in 64 von 64 Stichproben-Seiten |
| **JIT auf der Vision Pro ohne Mac** | **bestanden**, eingebauter Helfer, 1536 MB Region, 10 s nach App-Start |
| **macOS installieren und booten** | **läuft**: Sequoia 15.6.1 installiert und gestartet in Henge JIT, 4 Kerne, vom Nutzer am Gerät gesehen |

## JIT auf der Vision Pro: was gemessen wurde

Gemessen am 13.11.2026 auf `RealityDevice17,1` mit visionOS 27.3, Verbindung über WLAN.

| Versuch | Ergebnis |
| --- | --- |
| Ohne Debugger | `MAP_JIT` verweigert, kein ausführbarer Speicher |
| Debugger angehängt, App legt Speicher selbst an, hohe Adresse | Fehler `EXC_BAD_ACCESS (code=50)`, ein Code-Signatur-Fehler |
| Dasselbe im unteren Adressbereich | derselbe Fehler |
| Debugger vergibt Speicher (`_M…,rx`), schreibt aber nicht hinein | derselbe Fehler |
| Debugger vergibt Speicher und schreibt in jede Seite | **läuft** |

Die Vision Pro verhält sich damit wie iOS 26 und neuer. Ein angehängter Debugger allein reicht nicht.
Der Debugger muss den Speicher anlegen und in jede 16-KB-Seite einmal schreiben.

Das Skript `xros/lldb/henge_jit.py` macht genau das für lldb. Es beantwortet dieselben `brk`-Anfragen, die auf
iOS das StikDebug-Skript `henge-jit.js` bedient. Danach koppelt sich der Debugger ab, und die App läuft allein weiter.

**Kosten:** Jeder Schreibzugriff ist ein Hin und Her zum Gerät. Das Skript trifft mit zwei Bytes über eine
Seitengrenze zwei Seiten pro Zugriff.

| Region | Seiten | Dauer über WLAN |
| --- | --- | --- |
| 512 MB | 32768 | 151 bis 177 s |
| 1536 MB, Henges Vorgabe bei diesem Speicherlimit | 98304 | rund 8 min, hochgerechnet |

Über USB mit Developer Strap sollte es deutlich schneller gehen. Das ist nicht gemessen.

### Starten mit JIT

```bash
xros/scripts/run_on_device.sh <Geräte-ID> <Bundle-ID> 512
```

Die Geräte-ID zeigt `xcrun devicectl list devices`. Die App muss vorher installiert sein.

## Variante ohne Mac: eingebauter Helfer

Stand 13.11.2026: **läuft auf der Vision Pro M5.** Zehn Sekunden nach dem App-Start steht JIT mit dem vollen
1536-MB-Bereich, 64 von 64 Stichproben-Seiten liefen, der Helfer koppelt sich danach ab. Kein Mac ist am Start beteiligt.

Die App enthält wie auf iOS den Helfer `HengeJITHelper.appex` und `StikJIT.framework`. Der Helfer hängt sich als
Debugger an die eigene App und vergibt den Speicher direkt auf dem Gerät. Alle 98304 Seiten bereitet er in rund
zwei Sekunden vor, statt in Minuten über WLAN.

| Baustein | Stand |
| --- | --- |
| StikJIT als visionOS-Framework | läuft auf dem Gerät |
| Helfer-Erweiterung, gestartet über `NSExtension` | läuft auf dem Gerät |
| Eigener Schleifen-Tunnel `HengeVisionTunnel.appex` statt LocalDevVPN | läuft auf dem Gerät |
| Kopplung in der App, mit Code-Eingabe | läuft auf dem Gerät |
| Entwickler-Abbild | war durch Xcode schon eingebunden, Einbinden durch die App ungetestet |

Was die Messung auf dem Gerät ergab:

- **Kopplung läuft andersherum als auf iOS 27.** Die Brille bietet keine Gegenstelle in ihren Einstellungen an.
  Sie kündigt sich mit geöffneter Seite „Remote-Geräte“ als `_remotepairing-manual-pairing._tcp` an, die Gegenstelle
  verbindet sich, die Brille zeigt einen Code. Das ist dieselbe Richtung wie bei Apple TV.
- **Verbindungen vom Gerät an sich selbst werden zurückgesetzt.** Dieselbe Pairing-Datei wird vom Mac aus angenommen
  und von der eigenen WLAN-Adresse der Brille aus abgelehnt. Darum der Tunnel: Er schickt Pakete an `10.7.0.1`
  über eine Tunnelschnittstelle zurück, sodass sie wie von außen ankommen.
- **Die Kopplung in der App funktioniert.** Die Seite „Pair on this Apple Vision Pro“ startet den Tunnel, findet den
  Kopplungsdienst der Brille und nimmt den Code entgegen (`Vision/VisionPairing.swift`, Bibliothek
  `libhenge_rpclient.a` aus `xros/tools/henge-pair`). „Remote-Geräte“ muss dabei geöffnet bleiben.
- **Der Adressraum ist knapp.** Eine App hat dort oberhalb von `0x7000000000` genau 64 GB und darunter kaum etwas:
  bis `0x180000000` die App selbst, dann der gemeinsame Cache und eine Sperrzone. Henge hält 60 GB davon für die
  Mac-Apps-Funktion frei. Übrig blieb ein Stück von 4 GB, und der RAM des Macs passte nicht hinein: „Cannot build
  the machine“. Auf visionOS gibt die App diese Reserve jetzt frei, bevor ein Mac startet
  (`henge_ios_jit_release_high_room`). Die Berechtigung für erweiterte Adressierung ist gesetzt und wird signiert,
  ändert an den 64 GB aber nichts.
- **Der reservierte Adressbereich darf nicht vorzeitig frei werden.** Ein Startversuch ohne Debugger gab ihn frei,
  danach landete der Block des Debuggers oberhalb von `0x7000000000`.

Zwei Rust-Bibliotheken liegen nur für iOS vor. `xros/scripts/retag_static_lib.sh` schreibt in ihren Objektdateien die
Plattform auf visionOS um. Der Code ist derselbe, aber das ist kein offizieller visionOS-Build.

Der Tunnel braucht die Berechtigung „Network Extensions“ und damit ein bezahltes Entwickler-Team.

### Einrichten

```bash
xros/scripts/build_stikjit_xros.sh        # braucht ../StikJIT und ../Husk als Checkouts, dazu cargo
# App aus dem Ziel HengeVision bauen und installieren, dann einmalig koppeln:
cd xros/tools/henge-pair && cargo build --release
dns-sd -L "<Name der Brille>" _remotepairing-manual-pairing._tcp     # Port ablesen, Seite „Remote-Geräte“ offen
./target/release/henge-pair <IP>:<Port> pairing.plist                 # Code von der Brille eintippen
xcrun devicectl device copy to --device <Geräte-ID> --domain-type appDataContainer \
    --domain-identifier <Bundle-ID> --source pairing.plist --destination Documents/StikJIT/pairingFile.plist
```

Danach in der App „Turn On JIT“, oder in den Einstellungen JIT beim Start einschalten. Beim ersten Mal fragt
visionOS, ob Henge eine VPN-Konfiguration hinzufügen darf.

Im StikJIT-Checkout ergänzt dieser Test ein Ziel `StikJIT-visionOS` in `project.yml`. Die Änderung liegt als
`xros/patches/stikjit-visionos.patch` bei (gegen StikJIT a9ccad9, MPL-2.0 wie StikJIT): im Checkout `git apply` damit.

### Noch offen

1. **Sitzungsleiste und Mausrad.** Auf visionOS liegt die Leiste als Ornament unter dem Fenster, ohne den Knopf zum
   Ausblenden: Tastatur, Einfügen, Zoom, Details, Ausschalten (im Simulator geprüft). Das Mausrad kommt dort auf der
   zweiten Achse an, nicht auf der ersten wie beim Magic Keyboard am iPad, und wurde als waagerechtes Scrollen
   weitergegeben. Die Zuordnung ist für visionOS korrigiert, die Richtung am Gerät noch nicht bestätigt.
2. **Zeiger, Tastatur und Sondertasten auf visionOS.** Gebaut, am Gerät noch nicht bestätigt.
   - Der Mac bekommt auf visionOS ein drittes USB-Gerät: einen Zeiger, der Positionen meldet (`HV_USB_POINTER`,
     `devices/xhci.c`, Beschreibung und Kennungen wie QEMUs usb-tablet). Darüber sitzt der Zeiger des Macs exakt und
     ohne Verzögerung dort, wo der Systemzeiger ist. Solange macOS das Gerät nicht eingerichtet hat, greift die
     Regelschleife als Rückfall. Abschaltbar mit dem Startparameter `-henge.vision.usbPointer NO`. macOS
     Sequoia nimmt das Gerät an (am Gerät gesehen). Tasten und Mausrad gehen dann ebenfalls über dieses Gerät:
     Kam ein Tastendruck über die virtio-Maus, sprang der Zeiger des Macs bei jedem Drücken und Loslassen ein paar
     Zentimeter nach unten rechts. Vermutlich wiederholt macOS dabei die letzte gemeldete Bewegung dieser Maus.
     Ob der Sprung damit weg ist, ist am Gerät noch nicht bestätigt.
   - Während einer Sitzung ist die Tab-Leiste links ausgeblendet. Die Sitzungsleiste hat dafür einen Knopf, der ein
     zweites Henge-Fenster öffnet, etwa für einen Download neben dem laufenden Mac.
   - visionOS sperrt den Systemzeiger nicht weg. Mit der rohen Mausbewegung liefen zwei Zeiger auseinander, der
     des Systems wanderte auf Tab-Leiste und Bedienleiste. Jetzt führt der Systemzeiger: `Vision/VisionPointer.swift`
     holt den Zeiger des Macs dorthin, wo der Systemzeiger über dem Mac-Bild steht. Der Mac hat nur eine relative
     Maus, deshalb als Regelschleife pro Bild. Klicks und Mausrad zählen nur über dem Mac-Bild.
   - Der Tastatur-Knopf verkleinert den Mac-Bildschirm auf visionOS nicht mehr und holt die Systemtastatur.
   - Dazu erscheint unter der Bedienleiste eine Reihe Sondertasten nach dem Vorbild von Everdesk
     (`Vision/VisionKeyRow.swift`): esc, Tab, einrastende ⇧ ⌃ ⌥ ⌘, Pfeile, dazu F1 bis F12 und Navigation als Sätze.
3. **Sitzung, Auflösung und Fensterform auf visionOS.** Gebaut, am Gerät noch nicht bestätigt.
   - visionOS nimmt einem Fenster die Szene weg, wenn die Brille abgesetzt wird, und baut danach eine neue auf. Der
     Mac lief weiter, das neue Fenster zeigte aber die Liste, und ein erneuter Start meldete „The previous Mac is
     still running“ über dem sichtbaren Mac. Jetzt merkt sich die App den laufenden Mac (`RunningMac`), zeigt ihn
     in einem neuen Fenster wieder an und startet nichts doppelt.
   - Der Klick-Sprung blieb auch mit Tasten über das USB-Zeigegerät. Die Position wird jetzt nur noch aus dem Hover
     genommen. Vom Tastendruck zählt nur, wie weit sich der Zeiger bewegt. Die ersten Klicks schreiben beide Orte
     ins Protokoll (`pointer: press at …; the hover was at …`).
   - Wechselt der Mac die Auflösung, nimmt die Ansicht die neue Form an (`henge_vm_display_size`). Vorher blieb sie
     bei der Startform, das Bild wurde eingepasst, und Klicks landeten daneben.
   - Nach einem Auflösungswechsel in macOS trafen Klicks nicht mehr (vom Nutzer am Gerät gesehen, zuletzt am
     Anmeldebildschirm, der die umgestellte Auflösung behält). Ursache nach den Messwerten: macOS meldet den Ort
     seines Zeigers (Anzeigeseite +0xe00) immer in der Größe des einen Modus, mit dem der Mac gestartet wurde,
     auch wenn das Bild inzwischen kleiner ist. `devices/pvg_metal.m` zeichnete den Zeiger mit diesem Wert direkt
     ins Bild, bei 1600 × 900 nach Start mit 1920 × 1080 also beim 1,2-Fachen. Der Systemzeiger ist über dem Mac
     ausgeblendet, man zielt mit dem gezeichneten Zeiger, und der Klick ging an die richtige, aber andere Stelle.
     Jetzt wird der Ort beim Zeichnen und beim Zurücklesen (`hv_vm_pointer`) auf die Bildgröße umgerechnet.
     Zwei Versuche davor waren falsch: Sie skalierten die Klicks statt des gezeichneten Zeigers und verschoben
     sie damit erst recht. Mit der Maus vom Nutzer am Gerät bestätigt, das Protokoll zeigt Zeiger und Ziel auf
     den Pixel gleich. Betrifft vermutlich auch Henge auf iOS.
   - Ecken und Ränder: Ein visionOS-Fenster hat runde Ecken, der Hover endet an der Rundung. Der Zeiger des Macs
     kam deshalb nicht in die Ecken (vom Nutzer gesehen). Verlässt der Systemzeiger das Mac-Bild näher als 20
     Punkte an einem Rand, läuft der Zeiger des Macs jetzt bis an den Rand, näher als 34 Punkte an beiden bis in
     die Ecke (`Trackpad.swift`, `pinToEdge`). Nicht, wenn der Hover wegen eines Tastendrucks endet. Am Gerät
     noch nicht bestätigt.
   - Finger auf visionOS (Blick und Pinch): Der Bildschirm bleibt ein Trackpad wie auf iOS, das will der Nutzer
     so. Sein Fehlerbild: Nach dem Bewegen des Zeigers mit den Fingern landete ein Tipp woanders und zog dabei.
     Vermutete Ursache: Tipps und Halten schickten die Taste noch über die virtio-Maus, bei der der Zeiger des
     Macs neben einem USB-Zeigegerät beim Drücken und Loslassen springt. Jetzt liest `VisionPointer.buttonHere`
     den Ort des Mac-Zeigers zurück und schickt die Taste mit genau diesem Ort über das USB-Zeigegerät. Vom
     Nutzer am Gerät bestätigt. Das Protokoll nennt bei jedem Fingerkontakt den Ort des Mac-Zeigers und wie lange
     der Systemzeiger zuletzt gesprochen hat (`pointer: finger down …`, `pointer: press by a finger …`).
     Ein Zwischenstand, bei dem ein Tipp an der Blickstelle klickte, war nicht gewünscht und ist wieder entfernt.
   - Versuch, gescheitert: Der Bildschirm meldete zusätzlich die anderen Formen als Modi an (`HV_DISPLAY_MODES`,
     `devices/pvg_lite.c`), damit macOS unter „Displays“ auch 21:9 und 32:9 anbietet. Angenommen war eine Liste aus
     8-Byte-Einträgen ab +0x210 mit der Anzahl bei +0x208. Am Gerät zeichnete macOS Sequoia damit weiter, zeigte
     aber kein Bild mehr (0 statt 40 bis 500 Bilder pro 10 s). Der Aufbau stimmt also nicht. Der Code bleibt für
     weitere Versuche, ist aber aus und nur mit `-henge.vision.displayModes YES` an. Ultrawide gibt es damit nur
     über die Bildschirmauswahl in den Einstellungen eines Macs.
   - Das Fenster nimmt die Form des Mac-Bildschirms an und lässt sich nur noch proportional skalieren.
   - In den Einstellungen eines Macs gibt es auf visionOS eine Bildschirmauswahl, auch 21:9 und 32:9. Sie gilt ab
     dem nächsten Start des Macs. Mehr Pixel kosten Tempo.
4. **Bedienung im laufenden Mac.** Die Details-Ansicht hatte auf visionOS keinen Schließen-Knopf (behoben, „Done“).
   Eingabe, Fenstergröße und Tempo sind noch nicht systematisch geprüft. Die Brille meldete beim ersten Lauf
   „Hot, performance reduced“.
2. **Entwickler-Abbild nach Neustart der Brille.** StikJIT bindet es sonst selbst ein, findet für visionOS aber
   keinen Download. Xcode legt das Abbild unter `/Library/Developer/DeveloperDiskImages/xrOS_DDI` ab.
3. **Oberfläche.** Die Einrichtung in der App nennt noch iOS-Wege und LocalDevVPN.
4. **Portsuche des Helfers.** `RSDPortResolver` nimmt den ersten `_remotepairing._tcp`-Dienst im Netz. In einem Lauf
   war das ein iPhone im selben WLAN, nicht die Brille. Es ging gut, weil beide Port 49152 nutzten. Nach einem
   Neustart der Brille mit anderem Port könnte JIT daran scheitern.

### Aus Leviidev/Henge#157 übernommen

Stand 2026-11-13, als Patch auf den Arbeitsstand angewendet (`git diff 801e7af d52865d`), nicht gemergt. Übernommen
sind 12 der 15 Commits, alles bis vor dem Fenster-Prototyp:

- `HV_SHARED_KEEP=1`: Nutzer-TLB-Einträge der dyld-Shared-Region bleiben über einen Prozesswechsel stehen, wenn
  beide Prozesse sie über dieselbe Seitentabelle erreichen. Das ist die einzige echte Beschleunigung im PR.
  `=2` prüft zusätzlich jeden 64. solchen Wechsel nach und zählt veraltete Einträge. **Standardmäßig aus**, vom
  Autor und hier auf keinem Gerät gelaufen. Einschalten ohne Neubau: `HV_SHARED_KEEP=2` in `Documents/henge-env.txt`
  der App, gilt ab dem nächsten Start eines Macs. Die Statistikzeile `shared tables kept live: …` zeigt die Wirkung.
  Erster Lauf am Gerät (2026-11-13, macOS 27.2, 29 Minuten, `=2`): rund 13000 Prozesswechsel pro Sekunde, kein
  einziger hat Einträge behalten, die Zeile `shared tables kept live` erschien nie. Kein Gewinn, kein Schaden.
  Dazugebaut (nicht aus dem PR): Zähler nach Grund, Statistikzeile `shared keep, switches/s that kept nothing: …`.
  Zweiter Lauf mit den Zählern: Jeder Wechsel hat entweder eine leere alte oder eine leere neue Tabelle, je rund
  7500 pro Sekunde, kein anderer Grund kommt vor. xnu wechselt also nie direkt von Prozess zu Prozess, sondern
  immer über eine leere Seitentabelle (A, leer, B, und sehr oft A, leer, A). Der Vergleich aus dem PR findet
  darum nie zwei Prozesse nebeneinander. So wie er ist, wirkt `HV_SHARED_KEEP` mit macOS nicht.
  Behebung, gebaut am 2026-11-13, eigene Arbeit und nicht aus dem PR: Bit 4 in `HV_SHARED_KEEP` schiebt den
  Wechsel auf die leere Tabelle auf (`core/mmu.c`, `switch_user`, `HvPerCpu.defer_from`). Die Einträge bleiben
  stehen, bis das nächste TTBR0 sagt, wohin es wirklich ging. A, leer, A kostet dann nichts, A, leer, B wird als
  Wechsel von A nach B ausgeführt, mit dem Vergleich aus dem PR. Werte: 4 nur aufschieben, 5 dazu behalten,
  6 dazu nachprüfen. Standard bleibt aus.
  Absicherung: Als leer gilt eine Tabelle nur mit ASID 0 und ohne gültigen Eintrag in der Wurzel (ein neuer
  Prozess hat eine leere Tabelle, aber eine eigene ASID). Solange aufgeschoben ist, wird für Nutzeradressen nichts
  in den TLB gefüllt, und eine Rückkehr nach EL0 führt den Wechsel vorher aus (`hv_tlb_defer_end`).
  `HV_SWITCH_FLUSH` wirkt nicht zusammen mit `HV_SHARED_KEEP`. `test_mmu` hat dafür 52 neue Prüfungen (179 statt
  127), die bei vier absichtlich kaputten Varianten anschlagen. Statistikzeile:
  `switches to the empty table put off: …`.
  Erster Gerätelauf mit `HV_SHARED_KEEP=6` (macOS 27.2, rund 80 Sekunden Start und Anmeldung, vom Nutzer als
  funktionierend gemeldet): 8000 bis 21000 Wechsel pro Sekunde aufgeschoben, davon 700 bis 1300 zurück zum selben
  Prozess; 6000 bis 20000 Wechsel pro Sekunde behielten im Schnitt 600 bis 900 Einträge. Die Annahme zur ASID 0
  stimmt (leere Tabellen mit ASID: 0). Die Rückkehr nach EL0 musste nie eingreifen. Ein Tempovergleich ist daraus
  nicht ableitbar, die Läufe davor waren andere Phasen.
  **Offen:** Die Nachprüfung fand in 22 von rund 12000 Prüfungen etwas Veraltetes. Von den 16 protokollierten
  Einträgen waren 14 weggelegte Nutzereinträge anderer Prozesse (keine Abbildung mehr, Fehler auf Ebene 2), 2
  lebende Kernel-Einträge, kein lebender Nutzereintrag. Kernel-Einträge fasst die neue Logik nicht an, und
  weggelegte Einträge toter Prozesse kennt auch der Autor (Kommentar zu `HV_SWITCH_FLUSH`). Ob die Funde also
  ohnehin da sind oder von der neuen Logik kommen, ist ohne Vergleich nicht zu sagen. Dafür gibt es jetzt Bit 8
  (`HV_SHARED_KEEP=8`: nur nachprüfen, nichts behalten, nichts aufschieben) und Zähler nach Art in der Zeile
  `checks after a switch: …`.
  Vergleichsmessung mit `=8` (macOS 27.2, 11,5 Minuten, ohne Behalten und ohne Aufschieben): rund 107000
  Prüfungen, 308 fanden etwas, also 0,29 %. Im Lauf mit der neuen Logik waren es 22 von rund 12000, also 0,18 %.
  Veraltet waren in der Vergleichsmessung 2503 weggelegte Einträge, 51 lebende Kernel-Einträge und 17 lebende
  Nutzereinträge. Die Funde gibt es also auch ganz ohne die neue Logik, in mindestens derselben Rate. Sie
  stammen aus Henge selbst oder aus dem Zeitfenster zwischen dem Löschen eines Seitentabelleneintrags und dem
  TLBI einer anderen CPU, das die Prüfung nicht ausschließt. Ein Hinweis, dass die neue Logik veraltete Einträge
  erzeugt, ist das nicht; ein Beweis des Gegenteils auch nicht, der Lauf mit ihr war nur 80 Sekunden lang und
  zählte noch nicht nach Art. Die Brille steht seit 2026-11-13 wieder auf 14 (behalten, aufschieben, immer
  nachprüfen). Auszuwerten: dieselbe Zeile, vor allem „live user“ gegen 17 in 11,5 Minuten.
  Arbeit beim Prozesswechsel: Vergleichsmessung im Mittel 13355 Wegräum-Vorgänge pro Sekunde mit je 129
  Einträgen, mit der neuen Logik 4000 bis 5000 pro Sekunde (in einer Spitze 11000).
  `test_devices` lief nach diesem Umbau einmal mit 1 Fehler von 135 und danach 46-mal fehlerfrei; welcher Test
  es war, ist nicht festgehalten.
  Die Zähler zeigten außerdem: 40 bis 60 % der EL0-Refills liegen in der Shared Region. Die Brille stand im
  ersten Lauf durchgehend auf Temperaturstufe „Critical“, im zweiten auf „Hot“.
- `ENGINE_DEFS=-DHV_TLB_BITS=N` stellt die Größe des Software-TLB beim Bauen ein (auch für `xros-lib`).
- Messwerkzeug: Profil getrennt nach EL0 und EL1, Refills nach Abbildungsgröße und Adresse, `HV_FAULT_BENCH`,
  Adressbereich im Protokoll bei jedem Start, `tools/prof_words.py`.

Nicht übernommen: `HV_EL0_WINDOW` (3 Commits). Der Prototyp bildet den Nutzerspeicher des Gasts direkt in den
Prozess ab, fängt den ersten Zugriff auf jede Seite als Fehler ab und braucht 2^bits zusammenhängenden Adressraum.
Der Adressraum allein schließt es nicht aus: Das Protokoll nennt seit dem PR 508 GB für den Prozess
(`0x102c7c000-0x8000000000`), nur oberhalb von `0x7000000000` sind es 64 GB. Offen ist, ob die Fehlerbehandlung
unter visionOS trägt. Ungetesteter Prototyp, deshalb nicht übernommen.

Die neun Testreihen aus `TESTS` laufen damit auf dem Mac durch, `test_mmu` mit 127 Prüfungen. `make test` als
Ganzes baut hier nicht, weil `libslirp` für den Mac fehlt. Die Maschinenstruktur hat sich geändert: nach dem
Anwenden alle Engine-Objekte neu bauen (das Makefile kennt keine Header-Abhängigkeiten).

## Bauen

```bash
xros/scripts/build_deps_xros.sh xrsimulator   # einmalig, braucht meson und ninja im PATH
xros/scripts/build_deps_xros.sh xros          # einmalig, für das Gerät
cd ios && xcodegen generate
xcodebuild -project Henge.xcodeproj -scheme HengeVision -sdk xrsimulator \
  -destination 'generic/platform=visionOS Simulator' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

Meson liegt in `../.buildenv` neben dem Checkout: `export PATH="$PWD/../.buildenv/bin:$PATH"`.
Für das Gerät das Schema `HengeVision` in Xcode öffnen, ein Team wählen und mit angehängtem Debugger starten.
Das Ziel signiert mit `Henge.personal.entitlements`, das auch ein kostenloses Team signieren kann.

`xros/scripts/typecheck_xros.sh` prüft nur die Swift-Quellen gegen das visionOS-SDK und ist in Sekunden durch.

## Was geändert wurde

- `Makefile`: Ziel `xros-lib`, mit `XR_PLATFORM=xros` oder `xrsimulator`.
- `tools/build_ios_restore.sh`: Modi `xros` und `xrsimulator`.
- `ios/project.yml`: Ziel `HengeVision`, ohne JIT-Helfer und ohne StikJIT.
- `ios/Henge/Vision/VisionCompat.swift`: Ersatz für `UIScreen`, Haptik und die Lautstärketasten.
- `ios/project.yml`: zusätzlich das Ziel `HengeVisionJITHelper` und die Einstellung `HENGE_DISPLAY_NAME`.
- `xros/scripts/build_stikjit_xros.sh`, `xros/scripts/retag_static_lib.sh`: StikJIT und Pairing für visionOS.
- `ios/Henge/JIT/JITBootstrap.swift`: eigener Weg `prewarmVision`. Im Simulator legt die App die JIT-Region
  selbst an. Auf dem Gerät fragt sie den Debugger, wenn sie mit `HENGE_JIT_SERVICER=1` gestartet wurde.
- `ios/Henge/Native/henge-ios-jit.c`: Stichprobe `henge_ios_jit_spot_check` über die ganze Region. Eine selbst
  angelegte Region oberhalb der Grenze `0x7000000000` wird nicht mehr angesprungen, das hängte die App auf.
- `xros/lldb/henge_jit.py` und `xros/scripts/run_on_device.sh`: JIT-Vergabe über lldb und Start auf dem Gerät.
- Neun weitere Dateien mit je einer `#if os(visionOS)`-Stelle: externes Display, Tastaturzeile, Glas-Effekt.

Der iOS-Build ist unberührt: die iOS-Typprüfung aller Swift-Quellen läuft weiter ohne Fehler.

## Offene Punkte

1. **macOS installieren und booten.** JIT steht, der nächste Beweis ist ein laufender Mac. Die Installation lädt
   rund 17 GB und belegt danach etwa 26 GB auf der Vision Pro.
2. **Start ohne Mac.** Läuft, siehe oben. Offen sind die Kopplung in der App und das Abbild nach einem Neustart.
3. **Startdauer.** Zweieinhalb Minuten über WLAN für 512 MB. USB ist ungemessen. Ein kleinerer Code-Cache als
   512 MB ist in Henge nicht vorgesehen.
4. **Start aus Xcode.** Das Skript ist nur über die Kommandozeile erprobt. In Xcode müsste das Schema die
   Umgebungsvariable `HENGE_JIT_SERVICER=1` setzen und lldb das Skript beim Start laden.
5. **Eingabe.** Die Trackpad-Fläche und die Zusatztasten über der Tastatur sind für Touch gebaut. Auf visionOS
   fehlt die Tastenzeile ganz. Bluetooth-Tastatur und -Trackpad laufen über denselben Code wie auf dem iPad,
   sind aber ungetestet.
6. **Fenstergröße.** Der Mac bekommt fest 1920×1080 Punkte. Das Fenster folgt noch nicht der Größe, die man
   ihm im Raum gibt.
7. **Texte und Icon.** Einige Texte nennen noch iPhone-Wege wie StikDebug. Ein visionOS-App-Icon fehlt.

## Eigenheiten von lldb mit einem Gerät

- Nach `device process attach` meldet lldb den Zustand `connected` statt `stopped`. Ausdrücke lassen sich dann
  nicht auswerten, Fortsetzen geht aber.
- In einem Stop-Hook schlagen Registerzugriffe über lldbs eigene Schnittstelle fehl oder liefern alte Werte.
  Das Skript liest und schreibt Register deshalb direkt mit den Paketen `p` und `P`.
- Ein Pfad als `-v`-Wert am Stop-Hook lässt lldb den Hook ablehnen. Optionen gehen deshalb auch über
  Umgebungsvariablen `HENGE_JIT_…`.
