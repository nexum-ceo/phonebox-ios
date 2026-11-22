# PhoneBox für iPhone

iOS-Version der PhoneBox-Android-App (https://github.com/ersinkoc/phonebox, MIT), gebaut für das iPhone 13
(läuft auf jedem iPhone mit iOS 16 oder neuer).

Die Oberfläche ist **1:1 dieselbe**: Das komplette Panel der Android-App (`PhoneBox/Resources/www`, 129 Widgets,
Templates, alle Sprachen) läuft unverändert. Neu geschrieben (Swift) ist nur die native Hülle, die bei Android in
Kotlin steckt:

| Android (Kotlin)      | iOS (Swift)                    | Aufgabe |
|-----------------------|--------------------------------|---------|
| `MainActivity.kt`     | `PanelViewController.swift`    | Vollbild-WebView, Bridge `window.Android`, Lebenszyklus, Helligkeit, Vibration, Ausrichtung |
| WebViewAssetLoader    | `PanelSchemeHandler.swift`     | liefert das Panel aus und leitet `/agent/...` an den Agenten weiter |
| `AgentLink.kt`        | `AgentLink.swift`              | Verbindung zum PC: TLS mit Zertifikat-Pinning, Token, mehrere PCs, QR-Kopplung |
| `AgentStream.kt`      | `AgentStream.swift`            | Live-Stream (Server-Sent Events) |
| `TrackpadSocket`      | `TrackpadSocket.swift`         | Trackpad über WebSocket |
| `WakePacket.kt`       | `WakePacket.swift`             | Wake-on-LAN |
| `Dictation.kt`        | `Dictation.swift`              | Diktat-Widget (Apple-Spracherkennung, optional nur auf dem Gerät) |
| `strings.xml`         | `Resources/*.lproj`            | Kopplungsdialoge in denselben 23 Sprachen |
| `PanelTile.kt`        | `PhoneBoxControls/`            | Schnelleinstellungs-Kachel → Kontrollzentrum-Schalter (iOS 18+) |

## Auf das iPhone 13 installieren

1. **Xcode öffnen** (im Projektordner):

   ```bash
   open PhoneBox.xcodeproj
   ```

2. **Apple-ID hinzufügen** (einmalig, eine kostenlose Apple-ID reicht): Xcode › Settings › Accounts › „+“ › Apple ID.
3. Links das Projekt **PhoneBox** › Target **PhoneBox** › **Signing & Capabilities** › bei **Team** deine Apple-ID
   („Personal Team“) wählen. Falls die Bundle-ID schon vergeben ist, `net.oxog.phonebox.deskpanel.ios` z. B. um
   deinen Namen ergänzen.
4. iPhone per Kabel oder WLAN verbinden, oben als Ziel dein iPhone wählen und **▶ Run** (⌘R).
5. Auf dem iPhone beim ersten Mal:
   - **Entwicklermodus** einschalten: Einstellungen › Datenschutz & Sicherheit › Entwicklermodus › an (Neustart).
   - Dem Entwickler vertrauen: Einstellungen › Allgemein › VPN & Geräteverwaltung › deine Apple-ID › Vertrauen.

Mit einer kostenlosen Apple-ID läuft die Signatur nach **7 Tagen** ab; dann einfach in Xcode erneut ▶ Run drücken.
Mit einem bezahlten Developer-Account (99 €/Jahr) gilt sie ein Jahr.

## Mit dem Computer koppeln

Wie bei der Android-App ohne USB-Kabel, über **WLAN oder Tailscale**:

1. Am Mac die PhoneBox-Einstellungen öffnen: <http://127.0.0.1:8765>
2. **General › Wi-Fi & Tailscale › Let the phone connect without the USB cable** einschalten, **Save**, dann oben
   **Restart to apply**.
3. **Pair a phone over Wi-Fi** wählen, der Mac zeigt einen QR-Code.
4. Den QR-Code mit der **Kamera-App** des iPhones scannen und auf der Seite **„Open in PhoneBox“** tippen.
5. Prüfen, dass der Code im Dialog mit dem am Mac übereinstimmt, dann **Pair**.

iOS fragt beim ersten Verbinden nach **„Lokales Netzwerk“**: erlauben, sonst erreicht die App den Mac nicht.

## Bedienung wie bei Android

- **Zurück-Taste** → vom linken oder rechten Bildschirmrand wischen (zurück zur Startseite, sonst „Alle Seiten“).
- **Lautstärketasten** blättern die Seiten. Steht die Lautstärke ganz oben oder unten, rückt die App sie eine Stufe
  nach innen, damit beide Tasten reagieren, und stellt sie danach wieder zurück.
- **Schnelleinstellungs-Kachel** → Kontrollzentrum › „+“ › **PhoneBox** (öffnet das Panel).
- **Annäherungssensor**: Eine Handbewegung weckt den Nachtbildschirm. Der Sensor ist nur aktiv, solange das Panel
  dunkel ist, damit iOS den Bildschirm nicht abschaltet, wenn etwas davor ist (bei Android schaltet er nie ab).

## Was iOS nicht zulässt

- **USB/adb**: Ein iPhone kann nicht per adb mit dem Agenten sprechen. Deshalb gibt es weder Kopplung noch App-Updates
  über das Kabel; Updates kommen über Xcode.
- **Umgebungslicht-Sensor**: iOS gibt Apps keinen Lux-Wert. Die Helligkeit nach Raumlicht und „dunkler Raum ⇒ Nacht“
  entfallen. Der Zeitplan für die Nacht funktioniert.
- **Bildschirm anheften / als Startbildschirm**: Das kann eine App unter iOS nicht selbst einschalten. Ersatz:
  **Geführter Zugriff** (Einstellungen › Bedienungshilfen › Geführter Zugriff, dann Seitentaste 3×).
- **Akku**: iOS nennt weder Temperatur noch Ladequelle (USB, Netzteil, kabellos), nur Ladestand und „lädt“.
- **Wake-on-LAN**: Broadcasts brauchen unter iOS Apples Multicast-Berechtigung. Deshalb sendet die App zusätzlich
  direkt an die Adresse des PCs. Ob das deinen PC weckt, hängt von Netzwerkkarte und Router ab.
- **Diktat** nutzt Apples Spracherkennung statt der von Google, und das Panel läuft in WebKit statt Chrome.

## PhoneBox Starter (Mac)

`mac-starter/` ist eine kleine Menüleisten-App für den Mac, die den PhoneBox-Agenten (den Server, mit dem sich das
iPhone verbindet) **startet, stoppt und neu startet**. Das Symbol zeigt den Zustand: iPhone mit Funkwellen = läuft,
durchgestrichen = gestoppt.

```bash
mac-starter/build.sh --install
```

Das baut `PhoneBox Starter.app`, kopiert sie nach `~/Applications` und öffnet sie. Im Menü:

- **Starten / Stoppen / Neu starten**
- **Einstellungen öffnen** (http://127.0.0.1:8765) und **Log anzeigen**
- **Agent beim Öffnen starten** und **Starter beim Anmelden öffnen**: Zusammen startet PhoneBox automatisch beim Login.

Auch ohne Menü, z. B. im Terminal oder in der Kurzbefehle-App („Shell-Skript ausführen“):

```bash
~/Applications/PhoneBox\ Starter.app/Contents/MacOS/PhoneBoxStarter --stop
```

Die anderen Befehle sind `--start`, `--restart` und `--status`.

## Projekt neu erzeugen

`PhoneBox.xcodeproj`, `Info.plist`, das App-Icon und die Übersetzungen erzeugt ein Skript (ohne Zusatz-Tools):

```bash
python3 tools/generate.py
```

Ein neueres Panel aus dem Android-Repo übernehmen: `android/app/src/main/assets/www` nach
`PhoneBox/Resources/www` kopieren. Danach `VERSION` in `tools/generate.py` anpassen und das Skript erneut ausführen.
