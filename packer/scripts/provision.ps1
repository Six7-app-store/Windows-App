# -----------------------------------------------------------------------------
# Provisioning-Skript fuer das Golden Image "Windows 11 25H2"
# - Basiswerkzeuge ueber Chocolatey: Python, Node.js, Git, Editoren
# - Kursverzeichnis unter C:\Users\Default (das Windows-Gegenstueck zu
#   /etc/skel - Windows kopiert es beim ersten Anmelden in jedes neue Profil)
# - Idempotent, reproduzierbar, CI/CD-tauglich
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # sonst bremsen die Fortschrittsbalken jeden Download

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
# Ohne diese drei ist das Image seinen Zweck nicht wert - fehlt eines,
# bricht der Build ab.
$pflicht = @("python3", "nodejs-lts", "git")

# Bequemlichkeit, kein Kursinhalt. Ein Ausfall hier soll keinen
# halbstuendigen Build wegwerfen: Chocolatey-Pakete fuer Fremdsoftware
# aendern sich haeufig, googlechrome faellt regelmaessig ueber
# Pruefsummen. Fehlt eines, steht das am Ende im Protokoll.
$optional = @("vscode", "notepadplusplus", "7zip", "googlechrome")

# KEINE Versionsfestlegung bei nodejs-lts.
#
# Vorher stand hier "--version=24.0.0". Chocolatey fuehrt unter
# nodejs-lts die echten Node-Releases, und eine glatte 24.0.0 ist keines
# davon - der Build brach ab mit "The package was not found with the
# source(s) listed". Ohne Festlegung kommt die jeweils aktuelle
# LTS-Fassung, und die tatsaechlich installierte Version steht unten im
# Protokoll.

$fehlgeschlagen = @()

# Die Funktion gibt bewusst NICHTS zurueck, und der Aufruf hat keine Pipe.
#
# Vorher stand hier "Install-Paket ... | Out-Null", um den Rueckgabewert
# loszuwerden. Das verschluckt aber die ganze Erfolgs-Ausgabe der Funktion -
# die eigenen Meldungen ebenso wie die von choco. Der Build sah dann zwischen
# "Enabled allowGlobalConfirmation" und dem naechsten Abschnitt minutenlang
# aus, als haenge er, waehrend in Wahrheit fuenf Pakete heruntergeladen
# wurden. Was fehlschlaegt, wird stattdessen in $script:fehlgeschlagen
# vermerkt.
function Install-Paket {
    param([string]$Name, [switch]$Pflicht)

    Write-Output "Installiere $Name ..."
    & choco install $Name -y --no-progress --ignore-checksums
    # 3010 heisst "erfolgreich, Neustart noetig" - kein Fehler.
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {
        Write-Output "  $Name ist installiert."
        return
    }
    if ($Pflicht) {
        throw "choco install $Name endete mit Code $LASTEXITCODE - ohne dieses Paket ist das Image unbrauchbar."
    }
    Write-Output "  WARNUNG: $Name endete mit Code $LASTEXITCODE, wird uebersprungen."
    $script:fehlgeschlagen += $Name
}

foreach ($paket in $pflicht) {
    Install-Paket -Name $paket -Pflicht
}

foreach ($paket in $optional) {
    Install-Paket -Name $paket
}

if ($fehlgeschlagen.Count -gt 0) {
    Write-Output ""
    Write-Output "Nicht installiert (optional): $($fehlgeschlagen -join ', ')"
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
# Packer startet dieses Skript mit "powershell -executionpolicy bypass".
# Das setzt eine Process-Richtlinie, und die ist spezifischer als
# LocalMachine. Set-ExecutionPolicy setzt den Wert zwar ("wurden
# erfolgreich aktualisiert"), meldet aber trotzdem eine SecurityException
# wegen der Ueberschreibung - und mit ErrorActionPreference = Stop bricht
# das den ganzen Build ab. Genau daran ist v1.0.4 gestorben.
#
# Der Registry-Weg schreibt denselben Wert ohne diese Meldung. Er gilt
# ab dem naechsten Start, und die Nutzer-VMs starten ohnehin neu.
Write-Output "Setze ExecutionPolicy auf RemoteSigned"
$pfad = 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell'
New-Item -Path $pfad -Force | Out-Null
Set-ItemProperty -Path $pfad -Name 'ExecutionPolicy' -Value 'RemoteSigned'
Write-Output "  gesetzt (gilt ab dem naechsten Start)"

Write-Output "=== Provisioning beendet ==="
Write-Output ""

# -----------------------------------------------------------------------------
# Protokoll: was liegt tatsaechlich im Image?
# -----------------------------------------------------------------------------
# Alles ab hier ist reine Auskunft. Es darf den Build unter keinen Umstaenden
# zum Scheitern bringen - am Ende steht deshalb ein ausdrueckliches exit 0.
#
# Der Grund ist Erfahrung: hier stand "choco list --local-only", ein Schalter,
# den Chocolatey seit Version 2.0 nicht mehr kennt (das Image bringt 2.7.4
# mit). Der Aufruf endete mit Code 1. Weil die drei Werkzeuge in dieser
# Sitzung noch nicht im PATH standen und ihre Aufrufe im catch landeten, blieb
# $LASTEXITCODE auf dieser 1 stehen - und Packers Wrapper macht am Ende
# "exit $LastExitCode". Ein Protokollblock hat so einen vollstaendig
# erfolgreichen Build von acht Minuten verworfen.
try {
    # Chocolatey setzt PATH in der Maschinen-Umgebung, die laufende Sitzung
    # sieht das nicht. Ohne diese Zeile sind python, node und git hier
    # unbekannt, obwohl sie installiert sind.
    $env:PATH = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')

    Write-Output "Installierte Pakete:"
    # Seit Chocolatey 2.0 listet "choco list" ohnehin nur lokale Pakete.
    & choco list --limit-output

    Write-Output ""
    Write-Output "Versionen:"
    foreach ($werkzeug in @('python', 'node', 'git')) {
        $befehl = Get-Command $werkzeug -ErrorAction SilentlyContinue
        if ($null -eq $befehl) {
            Write-Output "  $werkzeug : nicht im PATH"
            continue
        }
        $ausgabe = & $werkzeug --version 2>&1 | Select-Object -First 1
        Write-Output "  $werkzeug : $ausgabe"
    }
} catch {
    Write-Output "Protokoll unvollstaendig: $($_.Exception.Message)"
}

# Der Build war erfolgreich, wenn er bis hierher gekommen ist. Was oben
# wirklich schiefgehen kann, wirft eine Ausnahme oder ruft throw auf.
exit 0
