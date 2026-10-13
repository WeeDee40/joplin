<!-- cSpell:disable -->
<!-- Written in German for the owner of this fork. -->

# Joplin Ink: nativer PencilKit-Zeichen-Editor (iOS, Phase 1)

Unter iOS/iPadOS werden Zeichnungen mit einem nativen Editor auf Basis von Apple PencilKit bearbeitet statt mit dem WebView-Editor (js-draw). Zeichnungen bleiben normale Joplin-Ressourcen (`image/svg+xml`), synchronisieren wie bisher, werden von allen Joplin-Clients angezeigt und sind dank Handschrifterkennung auf dem Gerät über die Joplin-Suche auffindbar.

Branch: `feature/native-pencilkit-ink` in `WeeDee40/joplin`, basierend auf Upstream-Commit `c87f694`.

## Architektur

```
Note.tsx ──(showImageEditor)──► NativeInkEditor.tsx (iOS, Einstellung an)  │  ImageEditor.tsx (js-draw: Android, Web, Einstellung aus)
                                      │
                                      │ parseInkSvg / buildInkSvg (utils/inkSvg.ts)
                                      │ writeAutosave / clearAutosave (gemeinsam mit ImageEditor)
                                      ▼
                       modules/joplin-ink (lokales Expo-Modul, Swift)
                       ├─ JoplinInkView      PKCanvasView + PKToolPicker, wachsendes Blatt, PNG-Export
                       ├─ SvgRasterizer      rendert alte SVGs mit WebKit (Hintergrundebene)
                       └─ InkTextRecognizer  Handschrift-OCR mit Apple Vision
```

| Datei (unter `packages/app-mobile`) | Zweck |
| --- | --- |
| `modules/joplin-ink/ios/*.swift` | Native View und Modul. Expo verlinkt `./modules` automatisch (keine Podfile-Änderung nötig). |
| `modules/joplin-ink/index.ts` | JS-Bindings. Lädt das native Modul erst bei Bedarf, Android/Web/Jest bleiben unberührt. |
| `components/NoteEditor/NativeInkEditor/NativeInkEditor.tsx` | Editor-Screen: Leiste (Abbrechen / Fertig), Laden, Autosave, Dialog «Änderungen speichern?». Gleiche Props wie `ImageEditor`. |
| `components/NoteEditor/NativeInkEditor/utils/inkSvg.ts` | SVG-Speicherformat bauen/parsen (Jest-Tests in `inkSvg.test.ts`). |
| `components/NoteEditor/NativeInkEditor/utils/saveDrawingOcrText.ts` | Schreibt den erkannten Text in die Ressource. |
| `components/screens/Note/Note.tsx` | Schaltet an einer Stelle zwischen beiden Editoren um; reicht den OCR-Text beim Speichern weiter. |
| `packages/lib/models/settings/builtInMetadata.ts` | Einstellung `editor.mobile.nativeInkEditor` («Nativen iOS-Zeichen-Editor verwenden», Standard an, nur auf iOS sichtbar). |
| `packages/editor/CodeMirror/extensions/rendering/renderBlockImages.ts` | Langes Drücken auf eine Zeichnung (SVG-Ressource) im Markdown-Editor löst das Editor-Event `EditResource` aus; `Note.tsx` öffnet dann den Zeichen-Editor. |
| `ios/JoplinUITests/JoplinUITests.swift` | UI-Tests `testNativeInkDrawing` und `testLegacyDrawingConversion`. |

### Entscheidungen

- **Lokales Expo-Modul in Swift**: Das Projekt nutzt bereits Expo-Autolinking, das `./modules` automatisch findet. Ausser `pod install` braucht es keine Änderung am Xcode-Projekt.
- **Gleiche JS-Schnittstelle wie `ImageEditor`** (`resourceFilename`, `themeId`, `onSave(svgData)`, `onExit`). `onSave` erhält ein optionales zweites Argument `{ ocrText }`; js-draw übergibt es einfach nicht.
- **Feste Blattbreite 768 pt, auf Bildschirmbreite gezoomt** (wie Apples PencilKit-Beispielcode). Eine Zeichnung sieht damit auf iPad/iPhone und im Hoch-/Querformat gleich aus. Das Blatt wächst nach unten: unter dem tiefsten Strich bleiben immer 500 pt Platz. Pinch-Zoom ist in Phase 1 deaktiviert.
- **Finger vs. Stift**: Auf dem iPad `drawingPolicy = .default`. Das folgt der Systemeinstellung *Einstellungen › Apple Pencil › Nur mit Apple Pencil zeichnen* (nach dem Koppeln eines Stifts standardmässig an) und dem passenden Schalter in der Werkzeugpalette: Stift zeichnet, Finger scrollt. Ist die Einstellung aus, zeichnet auch der Finger und gescrollt wird mit zwei Fingern. Auf dem iPhone (kein Stift) zeichnet jede Eingabe.
- **Werkzeugpalette**: gewählte Werkzeuge und Farben bleiben zwischen Sitzungen erhalten (`stateAutosaveName`).
- **Hell/Dunkel**: Im Editor folgt das Papier dem Joplin-Theme, PencilKit zeigt die Tinte im Dunkelmodus invertiert (wie Apple Notizen). Der **Export verwendet immer die Hell-Variante der Tinte auf einer weissen Papierebene**, damit die Zeichnung am Desktop in hellem und dunklem Theme lesbar ist (nie schwarz auf schwarz).
- **Leiste in React Native** statt nativ: passt zum Theme, übersetzbar, konsistent mit dem Rest der App.
- **Autosave**: 2 s nach dem letzten Strich und beim Wechsel der App in den Hintergrund wird die Zeichnung in dieselbe Autosave-Datei wie bei js-draw geschrieben. Wird die App beendet, erscheint beim nächsten Öffnen der Notiz der bestehende Dialog «Es wurde eine automatisch gespeicherte Zeichnung gefunden. Eine Kopie davon an die Notiz anhängen?».
- **Laden erst nach `onReady`**: Unter der New Architecture (Fabric) existiert die native View noch nicht, wenn React den Effekt ausführt. Die View meldet sich deshalb per Event, bevor `loadDrawing` aufgerufen wird.
- **Fehler beim Laden**: Kann eine Zeichnung nicht geladen werden, schliesst der Editor mit einer Meldung, ohne etwas zu speichern. So wird nie eine Zeichnung überschrieben, die nicht korrekt geöffnet wurde.

### Speicherformat

Eine Ressource, Mime-Type unverändert (`image/svg+xml`):

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="768" height="H" viewBox="0 0 768 H" data-joplin-ink="1">
  <rect id="joplin-ink-paper" … fill="#ffffff"/>
  <image id="joplin-ink-background" … href="data:image/png;base64,…"/>   <!-- nur bei konvertierten js-draw-Zeichnungen -->
  <image id="joplin-ink-strokes" … href="data:image/png;base64,…"/>      <!-- Striche in 2x-Auflösung -->
  <metadata id="joplin-pencilkit" data-version="1" data-canvas-width="768">BASE64 PKDrawing</metadata>
</svg>
```

- Sichtbar ist ein PNG in 2x-Auflösung, das alle PencilKit-Tinten (Bleistift, Marker, Aquarell …) exakt wiedergibt. Vektor-Export wäre eine spätere Optimierung.
- `PKDrawing.dataRepresentation()` in `<metadata>` macht die Zeichnung wieder voll editierbar. Andere Clients ignorieren es.
- Die Ebenen sind getrennt: Eine konvertierte js-draw-Zeichnung behält ihr Aussehen und muss nicht bei jedem Speichern neu gerastert werden. Phase 2 (Canvas-Notiz mit Seiten und Textfeldern) kann weitere Ebenen/Metadaten ergänzen, ohne das Format zu brechen; `data-version` erlaubt Migrationen.
- Robustheit: Fehlen die Metadaten, ist die Version unbekannt oder das base64 kaputt, wird die Datei als alte Zeichnung behandelt. Ihr Inhalt geht nie verloren (siehe unten).

### Alte js-draw-Zeichnungen

Ein SVG ohne PencilKit-Metadaten wird mit WebKit gerendert (über ein `<img>`-Element, Skripte im SVG laufen also nie) und als nicht editierbare Hintergrundebene in natürlicher Grösse angezeigt (verkleinert, falls breiter als 768 pt). Beim Öffnen erscheint einmal der Hinweis, dass der alte Teil nicht mehr strichweise bearbeitet werden kann. Beim Speichern werden Hintergrund und neue Striche zusammen abgelegt; ab dann ist die Datei eine PencilKit-Zeichnung (der Hinweis erscheint nicht mehr). Lässt sich die alte Zeichnung nicht rendern, schliesst der Editor ohne Änderung.

### Handschrifterkennung und Suche (Befund)

Beim Speichern wird das zusammengesetzte Bild (Papier + Hintergrund + Striche) an Apple Vision übergeben (`VNRecognizeTextRequest`, `.accurate`, Sprachkorrektur an, Sprachen `de-CH`, `de-DE`, `en-US`; nicht unterstützte werden übersprungen). **`de-CH` wird von Vision derzeit nicht angeboten** (geprüft: unterstützt sind u. a. `de-DE` und `en-US`), daher wird effektiv mit `de-DE` und `en-US` erkannt. Der Text landet in der Ressource:

```
ocr_text      = erkannter Text (max. 100 000 Zeichen)
ocr_status    = 2 (Done)
ocr_driver_id = 2 (HandwrittenText)
ocr_error     = ''
```

Befund aus dem Code (`packages/lib`):

1. **Die `ocr_*`-Felder werden synchronisiert.** `BaseItem.serialize()` schreibt alle Spalten der Tabelle `resources` (`fieldNames()`), und `ocr_text/ocr_status/ocr_error/ocr_details/ocr_driver_id` sind normale Spalten (Migrationen 45 und 48). Der bestehende Test `OcrService.test.ts › should handle conflicts if two clients process the same resource then sync` belegt, dass Client 1 den auf Client 2 erzeugten `ocr_text` erhält.
2. **Die Suche indexiert `ocr_text`.** `SearchEngine.syncTables_()` übernimmt `ocr_text` aller Ressourcen mit `ocr_status = Done` in `items_normalized`/`items_fts`. `SearchEngine.search()` durchsucht auch `items_fts` (Einstellung `ocr.searchInExtractedContent`, Standard an) und ordnet die Ressource den Notizen zu, die sie verlinken. Der Code ist gemeinsam, gilt also für Desktop **und** Mobile.
3. **Desktop-OCR überschreibt nichts.** `OcrService` verarbeitet nur Ressourcen mit Status Todo/Processing/TodoAccessible **und** unterstütztem Mime-Type (PNG, JPEG, PDF …, nicht SVG). Ein SVG mit Status Done wird nie angefasst.

Deshalb ist **kein Workaround im Notiztext nötig**; der Text reist mit der Ressource.

Im iPad-Simulator überprüft: Nach dem Speichern steht `ocr_text = 'TITEL'` mit Status 2/Treiber 2 in der Datenbank, nach etwa 20 s ist der Text im Volltextindex (`items_fts`) und die Ressource über `note_resources` mit der Notiz verknüpft.

Einschränkung: Der Suchindex nimmt Ressourcen nach `updated_time` auf. Eine von einem anderen Gerät synchronisierte Ressource, deren `updated_time` älter ist als die zuletzt lokal indexierte Ressource, wird unter Umständen erst indexiert, wenn sie sich wieder ändert. Das ist eine bestehende Eigenheit der Joplin-OCR-Suche, nicht dieser Funktion.

## Build und Installation auf dem iPad

Einmalige Voraussetzungen: Xcode mit deiner Apple-ID angemeldet (*Xcode › Settings › Accounts*, Team «Patrick Gerber», `C4LESUKP6H`), Homebrew, Node ≥ 22.19. Das Repo liegt in `~/joplin-ink`, die Abhängigkeiten sind schon installiert.

Falls du neu aufsetzen musst:

```bash
brew install cocoapods
```

```bash
corepack enable
```

```bash
cd ~/joplin-ink && NODE_OPTIONS=--no-experimental-strip-types LANG=en_US.UTF-8 yarn install
```

```bash
cd ~/joplin-ink/packages/app-mobile/ios && LANG=en_US.UTF-8 pod install
```

(`NODE_OPTIONS=--no-experimental-strip-types`: Node ≥ 23 entfernt TypeScript-Typen selbst und bricht damit die Gulp-Buildskripte. `LANG=en_US.UTF-8`: CocoaPods scheitert ohne UTF-8-Locale.)

Dann in Xcode:

```bash
open ~/joplin-ink/packages/app-mobile/ios/Joplin.xcworkspace
```

1. Target **Joplin** › *Signing & Capabilities*: Team **Patrick Gerber**, «Automatically manage signing» an. Dasselbe für das Target **ShareExtension**. Xcode registriert dabei die Bundle-IDs `ch.gerber.joplinink` / `ch.gerber.joplinink.ShareExtension` und die App Group `group.ch.gerber.joplinink` in deinem Developer-Account. (Das geht nur in der Xcode-Oberfläche; `xcodebuild` auf der Kommandozeile hatte keinen Zugriff auf dein Xcode-Konto.)
2. iPad per USB oder im selben WLAN verbinden. Falls verlangt, auf dem iPad *Einstellungen › Datenschutz & Sicherheit › Entwicklermodus* einschalten.
3. *Product › Scheme › Edit Scheme… › Run › Build Configuration*: **Release** (das JS-Bundle wird eingebettet, es braucht keinen Metro-Server auf dem Mac).
4. iPad als Ziel wählen und **Run** (⌘R).

Die App erscheint als **Joplin Ink** neben der offiziellen Joplin-App. Sie hat eine eigene Datenbank: Sync neu einrichten (gleiches Sync-Ziel wie die offizielle App ist in Ordnung, beides sind normale Sync-Clients).

Alle Fork-spezifischen Änderungen (Bundle-IDs, App Group, Team, Anzeigename) liegen in einem einzigen Commit, *«iOS (fork only): Own bundle ID …»*, den man vor einem allfälligen Upstream-PR einfach weglässt.

### Tests

```bash
cd ~/joplin-ink/packages/app-mobile && npx jest components/NoteEditor/NativeInkEditor
```

UI-Tests (iPad-Simulator, Debug-Build, Metro muss laufen: `yarn start` in `packages/app-mobile`), in Xcode über den Test-Navigator:

- `testNativeInkDrawing`: neue Notiz › *Draw picture* › «TITEL» zeichnen › *Done* › im Viewer lange drücken › *Edit* › Striche sind wieder da › weiterzeichnen › *Done*.
- `testOpenLegacyDrawing`: braucht vorbereitete Daten (nach `testNativeInkDrawing` die SVG-Datei der Ressource im Simulator-Container durch eine js-draw-Datei ersetzen). Prüft Hinweis, Hintergrundebene, Weiterzeichnen, Speichern und dass beim erneuten Öffnen kein Hinweis mehr kommt. Die js-draw-Zeichnung direkt im Test zu erzeugen ging nicht: Im Simulator öffnet ein Long Press auf manche Bilder im Viewer das iOS-Bildmenü («Share…, Save to Photos, Copy Subject») statt Joplins Menü.

### Was automatisiert geprüft wurde (iPad-Simulator, iOS 26.2)

| Prüfung | Ergebnis |
| --- | --- |
| Jest `inkSvg.test.ts` (Round-Trip, fehlende Metadaten, kaputtes base64, Versionen, Grössen) | 26 Tests grün |
| Neue Zeichnung, speichern, wieder öffnen (Striche einzeln erhalten), weiterzeichnen | UI-Test grün |
| Gespeichertes SVG: 768 pt breit, Papier-, Strich- und Metadaten-Ebene | in der Simulator-Datenbank/Datei geprüft |
| OCR: `ocr_text = 'TITEL'`, `ocr_status = 2`, `ocr_driver_id = 2` | geprüft |
| Suchindex: Text in `items_fts`, Ressource über `note_resources` der Notiz zugeordnet | geprüft (nach ~20 s) |
| Alte js-draw-Zeichnung: Hinweis, Hintergrund, Weiterzeichnen, Speichern mit Hintergrund-Ebene, OCR über beides, kein Hinweis beim zweiten Öffnen | UI-Test grün |
| Einstellung im Konfigurationsscreen (Abschnitt *Editor*) mit Beschreibung sichtbar, Umschalten auf js-draw | per UI-Test bedient |
| Release-Build für echte Geräte (`generic/platform=iOS`, arm64, JS-Bundle eingebettet) | kompiliert (ohne Signatur, siehe oben) |

## Bekannte Einschränkungen

- Nur iOS. Android und Web behalten js-draw (unverändert).
- Kein Pinch-Zoom in Phase 1; das Blatt ist immer auf Bildschirmbreite eingepasst.
- Gespeichert als PNG im SVG: Dateien sind grösser als Vektor-SVGs (z. B. ~40–60 KB für ein paar Wörter), und andere Clients können die Striche nicht bearbeiten (js-draw sieht nur ein Bild). Wird die Einstellung ausgeschaltet und eine PencilKit-Zeichnung mit js-draw bearbeitet, gehen die PencilKit-Daten verloren (der sichtbare Inhalt bleibt).
- Konvertierte js-draw-Zeichnungen: Der alte Teil wird zur Bitmap (nicht mehr strichweise editierbar).
- Erkennungsqualität hängt von Vision ab; `de-CH` ist nicht verfügbar, es wird `de-DE` verwendet. Bei sehr gleichförmigen Zeilen fasst Vision gelegentlich zusammen (im Test wurde zweimal «TITEL» als einmal erkannt).
- Das URL-Schema `joplin://` ist von der offiziellen App und von Joplin Ink registriert; iOS entscheidet, welche App solche Links öffnet.
- Die Autosave-Datei teilt sich der native Editor mit js-draw: Wird die App beim Bearbeiten einer *bestehenden* Zeichnung beendet, wird die wiederhergestellte Zeichnung als Kopie angehängt (gleiches Verhalten wie bisher).
- Eine per Autosave wiederhergestellte Zeichnung hat noch keinen OCR-Text; er entsteht beim nächsten Bearbeiten und Speichern.
- Getestet nur im Simulator (Maus statt Apple Pencil). Latenz, Palm Rejection und Druckempfindlichkeit sind Eigenschaften von PencilKit, aber auf echter Hardware noch nicht geprüft.

## Testcheckliste für dich

- [ ] **Neue Zeichnung**: Notiz öffnen › *⋮ › Bild zeichnen*. Mit dem Apple Pencil ein paar Wörter schreiben, in der Werkzeugpalette Werkzeug/Farbe wechseln, mit dem Finger nach unten scrollen, weiter unten weiterschreiben (das Blatt wächst). *Fertig* tippen. Die Zeichnung erscheint in der Notiz.
- [ ] **Bestehende PencilKit-Zeichnung weiterbearbeiten**: Im Notiz-Viewer lange auf die Zeichnung drücken › *Bearbeiten*. Alle Striche sind da und lassen sich einzeln radieren (Radierer in der Palette). Etwas ändern › *Fertig*.
- [ ] **Im Bearbeitungsmodus bearbeiten**: Notiz im Bearbeitungsmodus, lange (~0,6 s) auf die unter dem Link angezeigte Zeichnung drücken › der Zeichen-Editor öffnet sich. Fotos zeigen weiterhin das normale Verhalten.
- [ ] **Abbrechen**: Etwas ändern › *Abbrechen* › «Änderungen speichern?» erscheint; beide Varianten (*Änderungen verwerfen*, *Änderungen speichern*) prüfen.
- [ ] **Alte js-draw-Zeichnung öffnen**: Notiz mit einer früher (oder in der offiziellen App) erstellten Zeichnung › lange drücken › *Bearbeiten*. Der Hinweis erscheint einmal, die alte Zeichnung ist als Hintergrund sichtbar. Darauf zeichnen › *Fertig*. Alter Inhalt plus neue Striche sind in der Notiz sichtbar. Erneut öffnen: kein Hinweis mehr.
- [ ] **Sync zum Desktop**: Auf iPad und Desktop synchronisieren. Die Zeichnung erscheint am Desktop in der Notiz, scharf und in richtiger Grösse.
- [ ] **Desktop im dunklen Theme**: Die Zeichnung ist lesbar (weisses Papier, dunkle Tinte).
- [ ] **Suche am Desktop**: Nach einem handgeschriebenen Wort suchen (nach dem Sync einen Moment warten, bis indexiert ist). Die Notiz wird gefunden.
- [ ] **Suche auf dem iPad**: Dasselbe Wort in Joplin Ink suchen.
- [ ] **Dark Mode**: Joplin auf ein dunkles Theme stellen. Papier im Editor dunkel, Tinte hell; nach dem Speichern zeigt die Notiz die Version auf weissem Papier.
- [ ] **App während des Zeichnens beenden**: Zeichnen, ~3 s warten, App im App-Umschalter wegwischen. Notiz wieder öffnen: «Es wurde eine automatisch gespeicherte Zeichnung gefunden…» › *Anhängen*. Die Zeichnung ist angehängt.
- [ ] **Einstellung**: *Konfiguration › Editor › Nativen iOS-Zeichen-Editor verwenden* aus › *Bild zeichnen* öffnet wieder js-draw.
- [ ] **Nur Stift**: Mit *Einstellungen › Apple Pencil › Nur mit Apple Pencil zeichnen* an scrollt ein Finger und zeichnet nicht.

<!-- cSpell:enable -->
