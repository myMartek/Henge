# Bauen: Henge für Apple Vision Pro, mit macOS und Windows

Diese Anleitung baut die App `HengeVision` so, dass beide Gäste gehen: macOS über Henges eigene Engine und
Windows 11 für ARM über die Engine aus WindowsiOS. Sie ist an frischen Klonen nachgebaut, siehe „Stand“ am Ende.

## Was man braucht

- Einen Mac mit Apple-Chip, Xcode 27 mit dem visionOS-SDK und den Kommandozeilenwerkzeugen.
- Über Homebrew: `brew install xcodegen meson ninja pkg-config cmake`
- Rust mit dem iOS-Ziel: `rustup target add aarch64-apple-ios`
- Rund 2 GB Platz für Quellen und Bauergebnisse.
- Für das Gerät: ein Entwickler-Team in Xcode. Der eingebaute JIT-Weg ohne Mac braucht die Berechtigung
  „Network Extensions“ und damit ein bezahltes Team. Mit einem kostenlosen Team geht JIT nur über lldb am Mac.

## Drei Checkouts nebeneinander

Die Ordner müssen genau so heißen und nebeneinander liegen. Das Xcode-Projekt sucht `../WindowsiOS` und das
StikJIT-Skript sucht `../StikJIT`.

```bash
mkdir visionmac && cd visionmac
git clone -b visionos https://github.com/myMartek/Henge.git
git clone -b visionos https://github.com/myMartek/WindowsiOS.git
git clone https://github.com/StikDebug/StikJIT.git
git -C StikJIT checkout a9ccad9
git -C StikJIT apply ../Henge/xros/patches/stikjit-visionos.patch
```

| Ordner | Wofür |
| --- | --- |
| `Henge` | die App, die Mac-Engine, der Installer für macOS, die Windows-Oberfläche |
| `WindowsiOS` | die Engine für den Windows-PC und der Bau des Installationsmediums |
| `StikJIT` | der Debugger in der App, der JIT ohne Mac einschaltet |

## Bibliotheken bauen, einmalig

Alle Befehle aus dem Ordner `Henge`. `xrsimulator` ist der Simulator, `xros` das Gerät. Wer nur eines davon braucht,
lässt das andere weg.

```bash
cd Henge

# 1. Netzwerk beider Engines: libffi, glib, libslirp. Lädt die Quellen selbst, rund eine Minute je Plattform.
xros/scripts/build_deps_xros.sh xrsimulator
xros/scripts/build_deps_xros.sh xros

# 2. StikJIT und die Kopplungsbibliothek, für beide Plattformen in einem Lauf.
xros/scripts/build_stikjit_xros.sh

# 3. Nur für Windows: wimlib, das Microsofts ESD liest. Lädt die Quelle selbst und prüft die Prüfsumme.
../WindowsiOS/xros/build_wimlib_xros.sh xrsimulator
../WindowsiOS/xros/build_wimlib_xros.sh xros
```

Alles Weitere baut Xcode beim App-Build selbst: Henges Engine (`make xros-lib`), die Windows-Engine
(`make -C ../WindowsiOS xros-lib`), die Installer-Bibliotheken (`tools/build_ios_restore.sh`) und die Hilfsprogramme
für den Mac-Gast. Fehlt einer der drei Schritte oben, bricht der Build mit dem Namen des fehlenden Skripts ab.

## App bauen

```bash
cd ios
xcodegen generate
```

**Simulator**, ohne Signatur:

```bash
xcodebuild -project Henge.xcodeproj -scheme HengeVision -configuration Debug -sdk xrsimulator \
  -destination 'generic/platform=visionOS Simulator' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

**Gerät**, mit eigenem Team und eigener Bundle-ID:

```bash
xcrun devicectl list devices          # Geräte-ID ablesen
xcodebuild -project Henge.xcodeproj -scheme HengeVision -configuration Debug -sdk xros \
  -destination 'id=<Geräte-ID>' -derivedDataPath build/dd-device -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<Team-ID> HENGE_BUNDLE_IDENTIFIER=<eigene.bundle.id> build
xcrun devicectl device install app --device <Geräte-ID> build/dd-device/Build/Products/Debug-xros/Henge.app
```

Mit einem kostenlosen Team zusätzlich `HENGE_VISION_ENTITLEMENTS=Henge/Henge.personal.entitlements` anhängen. Der
Tunnel lässt sich dann nicht signieren, JIT kommt in dem Fall über `xros/scripts/run_on_device.sh` vom Mac.

## JIT einschalten

Ohne JIT startet kein Gast. Zwei Wege, beide in `README.md` beschrieben:

- **Ohne Mac:** einmalig koppeln (Abschnitt „Einrichten“), danach in der App „Turn On JIT“.
- **Über lldb:** `xros/scripts/run_on_device.sh <Geräte-ID> <Bundle-ID> 512` startet die App mit JIT.

## Prüfen, dass beides geht

| Gast | Weg in der App | Was passiert |
| --- | --- | --- |
| macOS | Plus-Knopf, „Install macOS…“ | lädt das Abbild von Apple, installiert, startet den Mac |
| Windows | Plus-Knopf, „Install Windows…“ | Sprache und Edition wählen, lädt das ESD von Microsoft (rund 4,5 GB), baut das Installationsmedium, installiert, startet Windows |

Beide Maschinen stehen danach in derselben Liste. Nach dem Herunterfahren der einen lässt sich die andere starten,
ohne die App zu beenden.

## Wenn etwas hakt

| Meldung oder Zeichen | Ursache |
| --- | --- |
| `error: run xros/scripts/build_deps_xros.sh …` | Schritt 1 fehlt für diese Plattform |
| `error: run xros/scripts/build_stikjit_xros.sh first` | Schritt 2 fehlt |
| `error: run ../WindowsiOS/xros/build_wimlib_xros.sh …` | Schritt 3 fehlt für diese Plattform |
| `make: *** ../WindowsiOS: No such file or directory` | der WindowsiOS-Checkout liegt nicht neben `Henge` |
| Schema `StikJIT-visionOS` nicht gefunden | der Patch ist im StikJIT-Checkout nicht angewendet |
| In der App fehlt „Install Windows…“ | gebaut wurde das iOS-Ziel `Henge`, nicht `HengeVision` |

`xros/scripts/typecheck_xros.sh` prüft nur die Swift-Quellen gegen das visionOS-SDK und ist in Sekunden durch.

## Stand

Nachgebaut am 17.11.2026 aus frischen Klonen der drei Repos, genau mit den Befehlen oben: Xcode 27.1 auf
macOS 27.2, meson 1.12.1, xcodegen 2.45.4, cargo 1.93.1. Alle Schritte liefen ohne Fehler durch, zusammen in rund
sechs Minuten, der Ordner war danach 1,6 GB groß.

| Geprüft | Ergebnis |
| --- | --- |
| App für den Simulator | baut |
| App für das Gerät, ohne Signatur | baut |
| Beide Engines in beiden Apps (`hv_vm_*` und `hv_winvm_x_*`, `winmedia_build`) | enthalten |
| Firmware, Netzwerktreiber, JIT-Helfer und Tunnel im App-Paket | enthalten |

Nicht Teil dieses Nachbaus: die Einrichtung der Werkzeuge auf einem leeren Mac, das Signieren mit einem Team und
der Lauf auf dem Gerät. Signiert, installiert und mit beiden Gästen gelaufen ist derselbe Quellstand aus dem
Arbeitsordner, aus dem diese Klone stammen.
