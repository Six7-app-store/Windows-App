#ps1_sysnative
# =============================================================================
# Startskript der Nutzer-VM. Wird von cloudbase-init ausgefuehrt
# (Plugin "UserDataPlugin"), das Gegenstueck zu cloud-init unter Linux.
#
# Die Kopfzeile #ps1_sysnative ist Pflicht - daran erkennt cloudbase-init,
# dass der Rest PowerShell ist und in der 64-Bit-Umgebung laufen soll.
#
# Es gibt kein vorgefertigtes Image mehr (ADR 0010 im deployment-Repo: kein
# Packer). Die VM startet vom unveraenderten Basis-Image, und dieses Skript
# erledigt beim ersten Start alles, was frueher der Image-Bau tat:
# Kursmaterial ablegen und Software installieren. Beides kommt
# gzip-komprimiert und base64-kodiert mit, siehe main.tofu.
#
# OpenTofu rendert diese Datei mit templatefile(). Zwei Zeichenfolgen sind
# darin nicht woertlich zu nehmen: $${ steht fuer ein literales
# Dollar-Klammer-Paar, %%{ fuer ein Prozent-Klammer-Paar. Letzteres leitet
# sonst eine Template-Direktive ein - auch mitten in einem Kommentar, denn
# OpenTofu kennt PowerShell-Kommentare nicht. Wo PowerShell %%{ } als
# Kurzform fuer ForEach-Object kennt, steht hier der ausgeschriebene Name.
# =============================================================================

$ErrorActionPreference = "Continue"
$logFile = "C:\Windows\Temp\appstore-setup.log"

function Write-Log($message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $message"
    $line | Out-File -Append -FilePath $logFile -Encoding utf8
}

# Gegenstueck zu base64gzip() in main.tofu. Das Komma vor dem Ergebnis ist
# noetig: ohne es zerlegt PowerShell das Byte-Array beim Zurueckgeben in
# einzelne Werte.
function Expand-Gzip($base64) {
    $eingang = New-Object System.IO.MemoryStream(, [Convert]::FromBase64String($base64))
    $gzip = New-Object System.IO.Compression.GZipStream($eingang, [System.IO.Compression.CompressionMode]::Decompress)
    $ausgang = New-Object System.IO.MemoryStream
    $gzip.CopyTo($ausgang)
    $gzip.Dispose()
    return , $ausgang.ToArray()
}

Write-Log "=== Einrichtung startet ==="
Write-Log "Nutzer: ${username}   Team: ${team}   Mail: ${email}"

# -----------------------------------------------------------------------------
# 1. Lokales Konto anlegen
# -----------------------------------------------------------------------------
# Das eingebaute Administrator-Konto wird bewusst NICHT benutzt. Windows
# liefert es deaktiviert aus, und cloudbase-init kann ihm zwar ein Passwort
# setzen, aber keine Anmeldesitzung eroeffnen - der Versuch scheitert mit
# "Das Konto ist momentan deaktiviert". Ein eigenes Konto umgeht das.
$securePassword = ConvertTo-SecureString '${password}' -AsPlainText -Force

# Description hat bei lokalen Konten ein hartes Limit von 48 Zeichen, und
# der Teamname kommt von aussen - seine Laenge ist hier nicht vorhersehbar.
# Eine zu lange Beschreibung laesst New-LocalUser scheitern, das Konto
# fehlt, und die RDP-Anmeldung wird abgewiesen, ohne dass irgendwo
# "Beschreibung zu lang" steht. Am 19.09.2026 ist der Packer-Build genau
# daran gescheitert; hier wird deshalb gekuerzt statt gehofft.
$beschreibung = 'App-Store Kurs, Team ${team}'
if ($beschreibung.Length -gt 48) {
    $beschreibung = $beschreibung.Substring(0, 48)
}

$existing = Get-LocalUser -Name '${username}' -ErrorAction SilentlyContinue
if ($null -eq $existing) {
    Write-Log "Lege Konto ${username} an"
    New-LocalUser -Name '${username}' `
                  -Password $securePassword `
                  -FullName '${email}' `
                  -Description $beschreibung `
                  -AccountNeverExpires `
                  -PasswordNeverExpires
} else {
    Write-Log "Konto ${username} existiert bereits, setze nur das Passwort"
    Set-LocalUser -Name '${username}' -Password $securePassword -PasswordNeverExpires $true
}

# Ohne Konto kommt der Studierende nicht auf seine VM. Das soll im
# Konsolenlog stehen und nicht stillschweigend durchlaufen.
if ($null -eq (Get-LocalUser -Name '${username}' -ErrorAction SilentlyContinue)) {
    Write-Log "ABBRUCH: Konto ${username} existiert nach dem Anlegen nicht."
    exit 1
}

# -----------------------------------------------------------------------------
# 2. Gruppen zuweisen
# -----------------------------------------------------------------------------
# Ueber die SID, nicht ueber den Namen: dieses Image ist deutschsprachig,
# dort heissen die Gruppen "Remotedesktopbenutzer" und "Administratoren".
# Ein englischer Name schluege hier fehl, und die SIDs sind in jeder
# Sprachfassung dieselben.
#
#   S-1-5-32-555  Remotedesktopbenutzer  - ohne die Mitgliedschaft weist
#                 Windows die RDP-Anmeldung ab, auch bei richtigem Passwort
#   S-1-5-32-544  Administratoren        - wie die Ubuntu-App, die ihren
#                 Nutzern sudo gibt. Die VM gehoert genau einem Studierenden
#                 und wird nach dem Kurs verworfen.
foreach ($sid in @('S-1-5-32-555', 'S-1-5-32-544')) {
    $group = Get-LocalGroup -SID $sid -ErrorAction SilentlyContinue
    if ($null -ne $group) {
        try {
            Add-LocalGroupMember -Group $group -Member '${username}' -ErrorAction Stop
            Write-Log "Zu Gruppe '$($group.Name)' hinzugefuegt"
        } catch {
            Write-Log "Gruppe '$($group.Name)': $($_.Exception.Message)"
        }
    } else {
        Write-Log "Gruppe mit SID $sid nicht gefunden"
    }
}

# -----------------------------------------------------------------------------
# 3. IPv6 aus den Metadaten setzen
# -----------------------------------------------------------------------------
# Ohne diesen Abschnitt ist die VM von aussen nicht erreichbar.
#
# Das Netz vergibt IPv6 per dhcpv6-stateful. Der DHCPv6-Client von Windows
# holt sich die Adresse hier nachweislich nicht: eine Testinstanz am
# 19.09.2026 hatte die in Neutron reservierte Adresse nie auf der Karte und
# antwortete nicht einmal auf Ping, waehrend eine Linux-VM im selben Netz
# einwandfrei lief. cloudbase-inits NetworkConfigPlugin benennt die Karte
# nur um und setzt die MTU - die Adressvergabe ueberlaesst es dem
# DHCP-Client.
#
# Die Adresse steht aber in den Metadaten, samt Gateway. Also wird sie von
# dort gelesen und statisch gesetzt. Der Wert muss exakt der von Neutron
# reservierte sein: die Port-Security verwirft Pakete mit jeder anderen
# Absenderadresse.
Write-Log "Konfiguriere IPv6 aus den Metadaten"
try {
    $netzDaten = Invoke-RestMethod -Uri 'http://169.254.169.254/openstack/latest/network_data.json' `
                                   -TimeoutSec 20 -UseBasicParsing

    foreach ($netz in $netzDaten.networks) {
        if ($netz.type -notlike 'ipv6*') { continue }
        if ([string]::IsNullOrEmpty($netz.ip_address)) {
            Write-Log "  $($netz.id): keine Adresse in den Metadaten"
            continue
        }

        # Die Karte wird ueber die MAC gesucht, nicht ueber den Namen:
        # cloudbase-init benennt sie in "tap<port-id>" um, und der Name
        # ist bei jeder Instanz ein anderer.
        $verbindung = $netzDaten.links | Where-Object { $_.id -eq $netz.link } | Select-Object -First 1
        $mac = $verbindung.ethernet_mac_address
        $karte = Get-NetAdapter | Where-Object { ($_.MacAddress -replace '-', ':') -ieq $mac } | Select-Object -First 1
        if ($null -eq $karte) {
            Write-Log "  keine Netzwerkkarte mit MAC $mac gefunden"
            continue
        }

        # Praefixlaenge aus der Netzmaske: ffff:ffff:ffff:ffff:: sind
        # 16 Stellen zu je 4 Bit, also /64.
        $praefix = 64
        if (-not [string]::IsNullOrEmpty($netz.netmask)) {
            $stellen = ($netz.netmask -replace ':', '').ToCharArray() | Where-Object { $_ -eq 'f' }
            if ($stellen.Count -gt 0) { $praefix = $stellen.Count * 4 }
        }

        $schonDa = Get-NetIPAddress -InterfaceIndex $karte.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -eq $netz.ip_address }
        if ($null -eq $schonDa) {
            New-NetIPAddress -InterfaceIndex $karte.ifIndex `
                             -IPAddress $netz.ip_address `
                             -PrefixLength $praefix -ErrorAction Stop | Out-Null
            Write-Log "  $($netz.ip_address)/$praefix auf '$($karte.Name)' gesetzt"
        } else {
            Write-Log "  $($netz.ip_address) war schon gesetzt"
        }

        $gateway = ($netz.routes | Where-Object { $_.network -eq '::' } | Select-Object -First 1).gateway
        if (-not [string]::IsNullOrEmpty($gateway)) {
            $route = Get-NetRoute -InterfaceIndex $karte.ifIndex -DestinationPrefix '::/0' -ErrorAction SilentlyContinue
            if ($null -eq $route) {
                New-NetRoute -InterfaceIndex $karte.ifIndex -DestinationPrefix '::/0' `
                             -NextHop $gateway -ErrorAction Stop | Out-Null
                Write-Log "  Standardroute ueber $gateway gesetzt"
            } else {
                Write-Log "  Standardroute war schon da"
            }
        }
    }
} catch {
    Write-Log "IPv6-Konfiguration fehlgeschlagen: $($_.Exception.Message)"
    Write-Log "Die VM ist dann nur ueber IPv4 im Projektnetz erreichbar."
}

# -----------------------------------------------------------------------------
# 4. Kursmaterial im Standardprofil ablegen
# -----------------------------------------------------------------------------
# C:\Users\Default ist das Windows-Gegenstueck zu /etc/skel: Windows kopiert
# es beim ersten Anmelden in das neue Profil. Das Konto oben hat noch kein
# Profil, es entsteht erst bei der ersten RDP-Anmeldung. Deshalb muss das
# Material hier liegen, BEVOR Remotedesktop eingeschaltet wird.
#
# Die Dateien liegen im Repo unter tofu/files/windows-kurs/. Der JSON-Text
# ordnet jedem relativen Pfad seinen gzip-komprimierten Inhalt zu.
Write-Log "Lege Kursmaterial an"
$kurs = 'C:\Users\Default\Desktop\Windows-Kurs'
try {
    $kursDateien = '${kurs_json}' | ConvertFrom-Json
    foreach ($eintrag in $kursDateien.PSObject.Properties) {
        $ziel = Join-Path $kurs ($eintrag.Name -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path $ziel -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($ziel, (Expand-Gzip $eintrag.Value))
    }
    Write-Log "  $(@($kursDateien.PSObject.Properties).Count) Dateien unter $kurs"
} catch {
    Write-Log "Kursmaterial fehlgeschlagen: $($_.Exception.Message)"
}

# Standardmaessig weigert sich Windows, eigene Skripte auszufuehren. Fuer
# Uebung 5 ist das genau die Huerde, an der der Kurs sonst endet.
# RemoteSigned bleibt dabei sicher: heruntergeladene Skripte brauchen weiter
# eine Signatur, selbst geschriebene nicht.
#
# Ueber die Registry statt Set-ExecutionPolicy: cloudbase-init startet
# dieses Skript mit einer eigenen Process-Richtlinie, und die ist
# spezifischer als LocalMachine. Set-ExecutionPolicy setzt den Wert zwar,
# meldet aber trotzdem eine SecurityException wegen der Ueberschreibung.
# Jede PowerShell, die danach startet, liest den neuen Wert.
$richtlinie = 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell'
New-Item -Path $richtlinie -Force | Out-Null
Set-ItemProperty -Path $richtlinie -Name 'ExecutionPolicy' -Value 'RemoteSigned'
Write-Log "ExecutionPolicy auf RemoteSigned gesetzt"

# -----------------------------------------------------------------------------
# 5. Remotedesktop einschalten
# -----------------------------------------------------------------------------
# Bewusst VOR der Softwareinstallation. Die dauert 10 bis 20 Minuten, und
# OpenTofu meldet das Deployment schon vorher als fertig - der Worker bricht
# ein Apply nach 30 Minuten ab, und davon braucht der erste Windows-Start
# bereits einen guten Teil. Wer sich in dieser Zeit anmeldet, kommt hinein
# und sieht Python, Node und Git nach und nach erscheinen.
Write-Log "Schalte Remotedesktop ein"
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                 -Name 'fDenyTSConnections' -Value 0

# Regelnamen sind nicht uebersetzt, Anzeigenamen und Gruppen schon - deshalb
# -Name und nicht -DisplayGroup.
foreach ($rule in @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
    Enable-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
}

# Sicherheitsnetz, falls die eingebauten Regeln im Image fehlen oder
# umbenannt wurden.
if ($null -eq (Get-NetFirewallRule -DisplayName 'AppStore RDP 3389' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'AppStore RDP 3389' `
                        -Direction Inbound -Protocol TCP -LocalPort 3389 `
                        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
}

Write-Log "Starte Terminaldienst"
Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name TermService -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# 6. Software installieren
# -----------------------------------------------------------------------------
# tofu/files/software.ps1, als eigener Prozess: das Skript arbeitet mit
# ErrorActionPreference = Stop und bricht bei einem fehlenden Pflichtpaket
# mit throw ab. Hier soll das nur im Protokoll stehen - Konto und RDP sind
# zu diesem Zeitpunkt schon eingerichtet und bleiben es.
Write-Log "Starte Softwareinstallation (dauert 10 bis 20 Minuten)"
$softwareSkript = 'C:\Windows\Temp\appstore-software.ps1'
try {
    [System.IO.File]::WriteAllBytes($softwareSkript, (Expand-Gzip '${software_gz}'))
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -NoProfile -ExecutionPolicy Bypass -File $softwareSkript *>&1 |
        Out-File -Append -FilePath $logFile -Encoding utf8
    Write-Log "Softwareinstallation beendet mit Code $LASTEXITCODE"
} catch {
    Write-Log "Softwareinstallation fehlgeschlagen: $($_.Exception.Message)"
}

# -----------------------------------------------------------------------------
# 7. Nachweis fuer die Fehlersuche
# -----------------------------------------------------------------------------
Write-Log "--- Ergebnis ---"
$user = Get-LocalUser -Name '${username}' -ErrorAction SilentlyContinue
Write-Log "Konto aktiv: $($user.Enabled)"
Write-Log "fDenyTSConnections: $((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections)"
Write-Log "TermService: $((Get-Service TermService).Status)"
Write-Log "IPv4: $((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object -First 1).IPAddress)"
Write-Log "=== Einrichtung beendet ==="

# Ausdruecklich: ohne exit gilt der Erfolg des letzten Befehls, und den
# bestimmt hier ein Protokollaufruf. cloudbase-init wertet den Code aus -
# 1001 bis 1003 hiessen sogar "neu starten" bzw. "beim naechsten Start
# erneut ausfuehren".
exit 0
