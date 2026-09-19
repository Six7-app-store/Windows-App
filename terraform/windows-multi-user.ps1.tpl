#ps1_sysnative
# =============================================================================
# Startskript der Nutzer-VM. Wird von cloudbase-init ausgefuehrt
# (Plugin "UserDataPlugin"), das Gegenstueck zu cloud-init unter Linux.
#
# Die Kopfzeile #ps1_sysnative ist Pflicht - daran erkennt cloudbase-init,
# dass der Rest PowerShell ist und in der 64-Bit-Umgebung laufen soll.
#
# Terraform rendert diese Datei mit templatefile(). Zwei Zeichenfolgen sind
# darin nicht woertlich zu nehmen: $${ steht fuer ein literales
# Dollar-Klammer-Paar, %%{ fuer ein Prozent-Klammer-Paar. Letzteres leitet
# sonst eine Template-Direktive ein - auch mitten in einem Kommentar, denn
# Terraform kennt PowerShell-Kommentare nicht. Wo PowerShell %%{ } als
# Kurzform fuer ForEach-Object kennt, steht hier der ausgeschriebene Name.
# =============================================================================

$ErrorActionPreference = "Continue"
$logFile = "C:\Windows\Temp\appstore-setup.log"

function Write-Log($message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $message"
    $line | Out-File -Append -FilePath $logFile -Encoding utf8
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

$existing = Get-LocalUser -Name '${username}' -ErrorAction SilentlyContinue
if ($null -eq $existing) {
    Write-Log "Lege Konto ${username} an"
    New-LocalUser -Name '${username}' `
                  -Password $securePassword `
                  -FullName '${email}' `
                  -Description 'App-Store Kurszugang, Team ${team}' `
                  -AccountNeverExpires `
                  -PasswordNeverExpires
} else {
    Write-Log "Konto ${username} existiert bereits, setze nur das Passwort"
    Set-LocalUser -Name '${username}' -Password $securePassword -PasswordNeverExpires $true
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
# 4. Remotedesktop einschalten
# -----------------------------------------------------------------------------
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
# 5. Kursmaterial im Profil bereitstellen
# -----------------------------------------------------------------------------
# Das Material liegt im Image unter C:\Users\Default (das Windows-Gegenstueck
# zu /etc/skel). Windows kopiert es beim ersten Anmelden in das neue Profil.
# Hier wird nur nachgesehen, ob es da ist - fehlt es, gehoert der Fehler in
# das Packer-Skript, nicht hierher.
if (Test-Path 'C:\Users\Default\Desktop\Windows-Kurs') {
    Write-Log "Kursmaterial im Standardprofil gefunden"
} else {
    Write-Log "WARNUNG: kein Kursmaterial unter C:\Users\Default - Image pruefen"
}

# -----------------------------------------------------------------------------
# 6. Nachweis fuer die Fehlersuche
# -----------------------------------------------------------------------------
Write-Log "--- Ergebnis ---"
$user = Get-LocalUser -Name '${username}' -ErrorAction SilentlyContinue
Write-Log "Konto aktiv: $($user.Enabled)"
Write-Log "fDenyTSConnections: $((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections)"
Write-Log "TermService: $((Get-Service TermService).Status)"
Write-Log "IPv4: $((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object -First 1).IPAddress)"
Write-Log "=== Einrichtung beendet ==="
