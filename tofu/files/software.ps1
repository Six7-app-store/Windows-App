# -----------------------------------------------------------------------------
# Softwareinstallation beim ersten Start der Nutzer-VM
# - Basiswerkzeuge ueber Chocolatey: Python, Node.js, Git, Editoren
# - Idempotent: ein zweiter Lauf installiert nichts doppelt
#
# Frueher lief das im Packer-Build und landete fertig im Image. Seit der
# Umstellung auf OpenTofu (ADR 0010 im deployment-Repo) gibt es keinen
# Image-Bau mehr: windows-multi-user.ps1.tpl legt diese Datei beim ersten
# Start ab und ruft sie als eigenen PowerShell-Prozess auf. Die Ausgabe
# landet in C:\Windows\Temp\appstore-setup.log.
#
# Kein Warten auf cloudbase-init mehr, wie es im Packer-Skript stand: dieses
# Skript laeuft jetzt INNERHALB von cloudbase-init. Die Schleife wuerde auf
# sich selbst warten, bis ihre Frist ablaeuft.
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # sonst bremsen die Fortschrittsbalken jeden Download

Write-Output "=== Softwareinstallation startet ==="

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
# --no-progress haelt das Protokoll lesbar.
# Ohne diese drei ist die VM ihren Zweck nicht wert - fehlt eines, endet
# das Skript mit einem Fehler, und das steht im Protokoll.
$pflicht = @("python3", "nodejs-lts", "git")

# Bequemlichkeit, kein Kursinhalt. Ein Ausfall hier soll den Rest nicht
# verhindern: Chocolatey-Pakete fuer Fremdsoftware aendern sich haeufig,
# googlechrome faellt regelmaessig ueber Pruefsummen. Fehlt eines, steht das
# am Ende im Protokoll.
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
# die eigenen Meldungen ebenso wie die von choco. Das Protokoll sah dann
# minutenlang aus, als haenge es, waehrend in Wahrheit fuenf Pakete
# heruntergeladen wurden. Was fehlschlaegt, wird stattdessen in
# $script:fehlgeschlagen vermerkt.
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
        throw "choco install $Name endete mit Code $LASTEXITCODE - ohne dieses Paket ist die VM unbrauchbar."
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

Write-Output "=== Softwareinstallation beendet ==="
Write-Output ""

# -----------------------------------------------------------------------------
# Protokoll: was ist tatsaechlich installiert?
# -----------------------------------------------------------------------------
# Alles ab hier ist reine Auskunft. Es darf den Lauf unter keinen Umstaenden
# als gescheitert melden - am Ende steht deshalb ein ausdrueckliches exit 0.
#
# Der Grund ist Erfahrung: hier stand "choco list --local-only", ein Schalter,
# den Chocolatey seit Version 2.0 nicht mehr kennt (das Image bringt 2.7.4
# mit). Der Aufruf endete mit Code 1. Weil die drei Werkzeuge in dieser
# Sitzung noch nicht im PATH standen und ihre Aufrufe im catch landeten, blieb
# $LASTEXITCODE auf dieser 1 stehen und wurde zum Ergebnis des Skripts. Ein
# Protokollblock hat so einen vollstaendig erfolgreichen Lauf verworfen.
try {
    # Chocolatey setzt PATH in der Maschinen-Umgebung, die laufende Sitzung
    # sieht das nicht. Ohne diese Zeile sind python, node und git hier
    # unbekannt, obwohl sie installiert sind. Eine neue Anmeldung liest den
    # PATH frisch - die Studierenden brauchen dafuer keinen Neustart.
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

# Erfolgreich, wenn es bis hierher gekommen ist. Was oben wirklich
# schiefgehen kann, wirft eine Ausnahme oder ruft throw auf.
exit 0
