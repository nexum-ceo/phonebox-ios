# PhoneBox für iPhone

iOS-Version der PhoneBox-Android-App (https://github.com/ersinkoc/phonebox, MIT, aktuell Version **0.9.32**), gebaut für das iPhone 13
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

## Der Mac wird automatisch wiedergefunden

Die Kopplung speichert die Adresse des Macs, und die stimmt nur in dem Netz, in dem du gekoppelt hast. Damit das
iPhone den Mac nach einem Netzwechsel (anderes WLAN, neue Adresse vom Router) selbst findet, gilt:

- Der **PhoneBox Starter** meldet dem iPhone über die bestehende, signierte Verbindung den **Bonjour-Namen** des Macs
  (z. B. `Mein-MacBook.local`, der „Computername für Freigaben“ aus Systemeinstellungen › Allgemein ›
  Info › Name). Er gilt in jedem Netz. Das iPhone lernt ihn, sobald es einmal verbunden war, und hängt ihn an die Adressen an.
- Schlagen die Adressen fehl, probiert die App den Namen. Sie merkt sich, worüber es zuletzt ging, und nimmt es beim
  nächsten Start zuerst, sodass eine alte Adresse nichts mehr kostet.
- Voraussetzung: Der PhoneBox Starter lief einmal, während das iPhone verbunden war. Beide Geräte müssen im selben Netz
  sein (oder per Tailscale). Ohne den gelernten Namen hilft nur eine neue Kopplung.

## Claude-Code-Chat (nur iPhone)

Auf jeder **Claude**-Karte des Widgets „AI Quotas“ (und auf Claude-Quota-Ringen) sitzt ein **💬**-Knopf. Er öffnet ein
Chatfenster, in dem du mit **Claude Code auf deinem Mac** schreibst. Das nutzt dein Claude-Abo, also die Quota, die
das Widget anzeigt.

So läuft eine Nachricht:

```
iPhone ──(bestehende, verschlüsselte PhoneBox-Verbindung)──▶ Agent: Push-Speicher pbchat.req
PhoneBox Starter (Mac) liest sie lokal ──▶ claude -p … (im Chat-Ordner) ──▶ Antwort nach pbchat.res ──▶ iPhone
```

- Es braucht **keinen zusätzlichen Port** und **keine zweite Kopplung**. Der Agent bleibt unverändert.
- Jede Nachricht und jede Antwort ist mit dem **Kopplungsschlüssel des iPhones signiert** (HMAC-SHA256). Andere
  Absender, etwa Geräte mit dem Webhook-Schlüssel des Agenten, können Claude Code deshalb nicht steuern.
- Das Gespräch wird fortgesetzt (`--resume`), bis du **Neuer Chat** tippst. **Stopp** bricht eine laufende Antwort ab.
- **Hochformat:** Der Chat funktioniert auch, wenn du das iPhone aufrecht hältst. Beim Öffnen folgt er der Lage des
  iPhones; der Knopf **⟳** in der Kopfzeile dreht zwischen Hoch- und Querformat, auch bei gesperrter Drehung. Im
  Hochformat ist die Kopfzeile kompakt (Ordner, Status, ⟳, Neuer Chat, ✕), und das Eingabefeld bleibt über der
  Tastatur sichtbar. Schließt du den Chat, kehrt das Panel in seine eigene Ausrichtung zurück.
- **Projektordner wechseln:** Tipp in der Kopfzeile auf **📁 Ordnername ▾**. Die Liste zeigt die Unterordner deines
  Projektordners (Standard `~/CEO`) und die Ordner, in denen du Claude Code zuletzt benutzt hast. Gewechselt wird nur
  in einen Ordner, den der Mac selbst anbietet. Mit dem Ordner beginnt ein neues Gespräch.
- **Claude antwortet immer auf Deutsch**, auch wenn du in einer anderen Sprache schreibst. Code und Befehle bleiben
  unverändert. Abschaltbar im Starter-Menü unter „Claude antwortet auf Deutsch“.
- Im Menü des **PhoneBox Starter**:
  - **Claude-Chat fürs iPhone** schaltet die Funktion an oder aus.
  - **Chat-Ordner** legt den Ordner fest, in dem Claude arbeitet (auch vom iPhone aus wechselbar).
  - **Projekte aus** legt fest, welche Ordner ihre Unterordner als Projekte anbieten.
  - **Claude darf Dateien bearbeiten** (standardmäßig aus) erlaubt Claude, Dateien zu ändern.
- Ob Claude Befehle ausführen darf, regeln deine Claude-Code-Berechtigungen. Ist der Claude-Code-Hook von PhoneBox
  installiert (Einstellungen am Mac), erscheinen Rückfragen als Erlauben/Ablehnen-Karte auf dem iPhone.
- Voraussetzung: Das iPhone ist per WLAN gekoppelt, und der PhoneBox Starter läuft auf dem Mac.

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

Ein neueres Panel aus dem Android-Repo übernehmen: das Release-Archiv laden (`…/archive/refs/tags/vX.Y.Z.tar.gz`),
`android/app/src/main/assets/www` nach `PhoneBox/Resources/www` und `android/app/src/main/res/values*` nach
`upstream-android-res/` kopieren, `VERSION` in `tools/generate.py` anpassen und das Skript erneut ausführen. Neue
Methoden der Android-Bridge (`MainActivity.kt`, `@JavascriptInterface`) muss die Hülle nachbauen, sonst fehlt die
Funktion auf dem iPhone (das Panel fragt sie optional ab).

**Nur Android, auf dem iPhone nicht verfügbar (seit 0.9.32):** Benachrichtigungen und Zwischenablage zum Mac,
„Teilen mit Mac“ und Handy-Medien (Wiedergabe, Lautstärke des Handys). Sie brauchen Android-Rechte, die iOS Apps nicht
gibt; das Panel blendet sie auf dem iPhone aus.
