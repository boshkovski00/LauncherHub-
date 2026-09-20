# Launcher Hub

Ein kleiner Windows-Launcher mit großen Kacheln für deine installierten Game-Launcher.

## Starten

1. Lade das Repository als ZIP herunter und entpacke es.
2. Starte `LauncherHub.cmd` per Doppelklick.

Windows 10 oder 11 und Windows PowerShell 5.1 werden benötigt. Alle Dateien müssen im selben Ordner bleiben. Das Programm selbst enthält keine Spiele oder Launcher.

## Funktionen

- **Auto-Erkennung** sucht bekannte Launcher im Startmenü, auf dem Desktop und in Windows-Installationseinträgen.
- **Hinzufügen** nimmt eigene `.exe`-, `.lnk`- oder `.url`-Dateien auf.
- Das **×** auf einer Kachel entfernt den Eintrag nur aus dem Hub. Das Programm bleibt installiert.
- Der grüne Punkt zeigt einen erkannten laufenden Prozess an.
- Die Versionsprüfung nutzt WinGet, falls es auf dem PC verfügbar ist. Ein WinGet-Hinweis ist kein sicherer Beleg für ein notwendiges Update. Der Hub installiert nichts.

Jeder Windows-Nutzer hat eine eigene Auswahl unter `%APPDATA%\LauncherHub\config.json`. Diese Konfigurationsdatei gehört **nicht** zum Download; jeder PC erkennt seine eigenen Launcher.
