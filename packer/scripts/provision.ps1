# -----------------------------------------------------------------------------
# Provisioning-Skript fuer das Golden Image "Windows 11 25H2"
# - Basiswerkzeuge ueber Chocolatey: Python, Node.js, Git, Editoren
# - Kursverzeichnis unter C:\Users\Default (das Windows-Gegenstueck zu
#   /etc/skel - Windows kopiert es beim ersten Anmelden in jedes neue Profil)
# - Idempotent, reproduzierbar, CI/CD-tauglich
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # sonst bremsen die Fortschrittsbalken jeden Download

$NodeVersion = "24"

Write-Output "=== Provisioning startet ==="

# -----------------------------------------------------------------------------
# Auf cloudbase-init warten
# -----------------------------------------------------------------------------
# Das Gegenstueck zu `cloud-init status --wait`. Laeuft cloudbase-init noch,
# waehrend hier installiert wird, streiten sich zwei Prozesse um den
# Windows-Installer und einer davon verliert.
Write-Output "Warte auf cloudbase-init..."
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    $svc = Get-Service -Name 'cloudbase-init' -ErrorAction SilentlyContinue
    if ($null -eq $svc -or $svc.Status -ne 'Running') { break }
    Start-Sleep -Seconds 10
}
Write-Output "  weiter"

# -----------------------------------------------------------------------------
# Chocolatey
# -----------------------------------------------------------------------------
# Windows hat kein apt. Chocolatey ist der verbreitetste Paketmanager und
# laesst sich unbeaufsichtigt bedienen, was hier die Bedingung ist.
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Output "Installiere Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:PATH = "$env:PATH;$env:ALLUSERSPROFILE\chocolatey\bin"
} else {
    Write-Output "Chocolatey ist bereits vorhanden"
}

choco feature enable -n allowGlobalConfirmation

# -----------------------------------------------------------------------------
# Software
# -----------------------------------------------------------------------------
# Entspricht dem, was die Ubuntu-App mitbringt: Python, Node, Git, Editoren.
# --no-progress haelt das Build-Log lesbar.
$pakete = @(
    "python3",
    "nodejs-lts --version=$NodeVersion.0.0",
    "git",
    "vscode",
    "notepadplusplus",
    "7zip",
    "googlechrome"
)

foreach ($paket in $pakete) {
    Write-Output "Installiere $paket ..."
    $argumente = $paket -split ' '
    & choco install @argumente -y --no-progress --ignore-checksums
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
        # 3010 heisst "erfolgreich, Neustart noetig" - kein Fehler.
        throw "choco install $paket endete mit Code $LASTEXITCODE"
    }
}

# -----------------------------------------------------------------------------
# Kursverzeichnis im Standardprofil
# -----------------------------------------------------------------------------
# C:\Users\Default ist die Vorlage fuer jedes neu angelegte Profil. Was hier
# liegt, findet der Studierende nach der ersten Anmeldung auf dem Desktop.
Write-Output "Lege Kursverzeichnis an..."

$kurs = "C:\Users\Default\Desktop\Windows-Kurs"
$verzeichnisse = @(
    "$kurs",
    "$kurs\beispieldaten",
    "$kurs\uebungen\01-explorer-und-pfade",
    "$kurs\uebungen\02-powershell-grundlagen",
    "$kurs\uebungen\03-dateien-und-rechte",
    "$kurs\uebungen\04-prozesse-und-dienste",
    "$kurs\uebungen\05-skripte"
)
foreach ($v in $verzeichnisse) {
    New-Item -ItemType Directory -Path $v -Force | Out-Null
}

# Kurzreferenz. Bewusst als Gegenueberstellung zu Linux: die meisten
# Studierenden kennen den Kurs aus der Ubuntu-App und suchen das Aequivalent.
$liesMich = @'
WINDOWS-KURS - KURZREFERENZ
===========================

PowerShell oeffnen: Windows-Taste, "powershell" tippen, Enter.

NAVIGATION
  Get-Location            pwd          Wo bin ich?
  Set-Location C:\Temp    cd           Verzeichnis wechseln
  Get-ChildItem           ls / dir     Inhalt anzeigen
  Get-ChildItem -Recurse  ls -R        Auch Unterverzeichnisse

DATEIEN
  New-Item datei.txt              touch      Datei anlegen
  Get-Content datei.txt           cat        Inhalt anzeigen
  Get-Content datei.txt -Tail 10  tail       Letzte 10 Zeilen
  Copy-Item a b                   cp         Kopieren
  Move-Item a b                   mv         Verschieben/Umbenennen
  Remove-Item datei.txt           rm         Loeschen

SUCHEN
  Select-String "muster" datei.txt    grep     In Dateien suchen
  Get-ChildItem -Filter *.log         find     Nach Namen suchen

PROZESSE UND DIENSTE
  Get-Process                  ps        Laufende Programme
  Stop-Process -Name notepad   kill      Programm beenden
  Get-Service                  systemctl Dienste auflisten
  Restart-Service -Name Spooler          Dienst neu starten

SYSTEM
  Get-ComputerInfo                       Systemuebersicht
  Get-Volume                   df        Laufwerke und freier Platz
  Get-NetIPAddress             ip addr   Netzwerkadressen

HILFE
  Get-Help Get-ChildItem -Examples       Beispiele zu einem Befehl
  Get-Command *service*                  Befehle suchen

MERKE: PowerShell arbeitet mit Objekten, nicht mit Text. Deshalb geht
  Get-Process | Where-Object { $_.CPU -gt 10 } | Sort-Object CPU
ohne einen einzigen Aufruf von grep, awk oder cut.
'@
Set-Content -Path "$kurs\LIES_MICH.txt" -Value $liesMich -Encoding UTF8

# Beispieldaten - dieselben wie im Linux-Kurs, damit die Uebungen vergleichbar
# bleiben.
$studenten = @'
Nachname,Vorname,Matrikelnummer,Kurs,Note
Mueller,Anna,1234567,WWI23B,1.7
Schmidt,Ben,1234568,WWI23B,2.3
Weber,Clara,1234569,WWI23A,1.3
Fischer,David,1234570,WWI23A,2.7
Wagner,Emma,1234571,WWI23B,1.0
Becker,Felix,1234572,WWI23A,3.0
'@
Set-Content -Path "$kurs\beispieldaten\studenten.csv" -Value $studenten -Encoding UTF8

$serverLog = @'
2026-09-01 08:12:03 INFO  Dienst gestartet
2026-09-01 08:12:44 INFO  Anmeldung erfolgreich benutzer=amueller
2026-09-01 09:03:11 WARN  Speicherauslastung 87 Prozent
2026-09-01 09:14:52 ERROR Datenbankverbindung verloren
2026-09-01 09:14:55 INFO  Wiederverbindung erfolgreich
2026-09-01 11:41:09 ERROR Zeitueberschreitung bei Anfrage id=4711
2026-09-01 14:22:30 INFO  Anmeldung fehlgeschlagen benutzer=unbekannt
2026-09-01 17:58:01 INFO  Dienst beendet
'@
Set-Content -Path "$kurs\beispieldaten\server.log" -Value $serverLog -Encoding UTF8

# Je eine Aufgabenstellung pro Uebung.
$aufgaben = @{
    "01-explorer-und-pfade" = @'
UEBUNG 1 - EXPLORER UND PFADE

1. Finde heraus, in welchem Verzeichnis PowerShell startet.
2. Wechsle in dein Kursverzeichnis auf dem Desktop.
3. Lass dir den Inhalt anzeigen, auch die versteckten Eintraege.
4. Was ist der Unterschied zwischen C:\Users\Public und deinem Profil?

Tipp: Get-Location, Set-Location, Get-ChildItem -Force
'@
    "02-powershell-grundlagen" = @'
UEBUNG 2 - POWERSHELL-GRUNDLAGEN

1. Lass dir alle laufenden Prozesse anzeigen, nach Speicherverbrauch sortiert.
2. Zeige nur die fuenf groessten an.
3. Gib nur die Spalten Name und WorkingSet aus.

Tipp: Get-Process, Sort-Object, Select-Object -First

Frage zum Nachdenken: Unter Linux braeuchtest du dafuer ps, sort, head und
awk. Warum kommt PowerShell mit drei Befehlen aus?
'@
    "03-dateien-und-rechte" = @'
UEBUNG 3 - DATEIEN UND RECHTE

1. Lege im Kursverzeichnis eine Datei notizen.txt an und schreibe etwas hinein.
2. Haenge eine zweite Zeile an, ohne die erste zu ueberschreiben.
3. Lass dir die Zugriffsrechte der Datei anzeigen.
4. Nimm der Gruppe "Benutzer" das Schreibrecht.

Tipp: Set-Content, Add-Content, Get-Acl, Set-Acl
'@
    "04-prozesse-und-dienste" = @'
UEBUNG 4 - PROZESSE UND DIENSTE

1. Starte den Editor (notepad) aus PowerShell heraus.
2. Finde seine Prozess-ID.
3. Beende ihn wieder, ohne die Maus zu benutzen.
4. Welche Dienste laufen gerade, deren Name mit "Win" beginnt?

Tipp: Start-Process, Get-Process, Stop-Process, Get-Service
'@
    "05-skripte" = @'
UEBUNG 5 - SKRIPTE

1. Schreibe ein Skript auswertung.ps1, das studenten.csv einliest.
2. Gib alle Studierenden des Kurses WWI23B aus.
3. Berechne den Notendurchschnitt.
4. Sortiere die Ausgabe nach Note.

Tipp: Import-Csv, Where-Object, Measure-Object -Average, Sort-Object

Hinweis: Skripte duerfen erst laufen, wenn die Ausfuehrungsrichtlinie es
erlaubt. Im Kurs-Image ist sie bereits gelockert - schau mit
Get-ExecutionPolicy nach, was eingestellt ist.
'@
}

foreach ($name in $aufgaben.Keys) {
    Set-Content -Path "$kurs\uebungen\$name\AUFGABE.txt" -Value $aufgaben[$name] -Encoding UTF8
}

# -----------------------------------------------------------------------------
# Ausfuehrungsrichtlinie
# -----------------------------------------------------------------------------
# Standardmaessig weigert sich Windows, eigene Skripte auszufuehren. Fuer
# Uebung 5 ist das genau die Huerde, an der der Kurs sonst endet.
# RemoteSigned bleibt dabei sicher: heruntergeladene Skripte brauchen weiter
# eine Signatur, selbst geschriebene nicht.
Write-Output "Setze ExecutionPolicy auf RemoteSigned"
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

Write-Output "=== Provisioning beendet ==="
Write-Output "Installiert:"
& choco list --local-only --limit-output
