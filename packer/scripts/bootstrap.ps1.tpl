#ps1_sysnative
# =============================================================================
# Wird von cloudbase-init auf der Build-VM ausgefuehrt, bevor Packer sich
# verbindet. Einziger Zweck: ein Konto schaffen, mit dem Packer ueber WinRM
# hereinkommt.
#
# Warum nicht das Administrator-Konto: Windows liefert es deaktiviert aus.
# cloudbase-init versucht ihm ein Passwort zu setzen und scheitert mit
# "Der Benutzer kann sich nicht anmelden, da das Konto momentan deaktiviert
# ist" - das Passwort wird zwar gesetzt, anmelden kann sich damit aber
# niemand.
#
# Packer rendert diese Datei mit templatefile(). $${ steht darin fuer ein
# literales Dollar-Klammer-Paar, %%{ fuer ein Prozent-Klammer-Paar -
# letzteres waere sonst eine Template-Direktive, auch innerhalb eines
# Kommentars: Packer kennt PowerShell-Kommentare nicht.
# =============================================================================

$ErrorActionPreference = "Continue"
$logFile = "C:\Windows\Temp\packer-bootstrap.log"

function Write-Log($message) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $message" |
        Out-File -Append -FilePath $logFile -Encoding utf8
}

Write-Log "=== Bootstrap fuer den Packer-Build ==="

$securePassword = ConvertTo-SecureString '${build_password}' -AsPlainText -Force

# Description hat bei lokalen Konten ein hartes Limit von 48 Zeichen.
# Eine laengere laesst New-LocalUser mit "Das Argument umfasst zu viele
# Zeichen" scheitern - und weil ErrorActionPreference auf Continue steht,
# laeuft das Skript danach weiter, oeffnet brav den WinRM-Port und
# hinterlaesst kein Konto. Packer meldet dann "401 - invalid content
# type", was nach einem Netz- oder Zertifikatsproblem aussieht und keines
# ist. Genau so ist der Build am 19.09.2026 gescheitert.
if ($null -eq (Get-LocalUser -Name 'packer' -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name 'packer' `
                  -Password $securePassword `
                  -FullName 'Packer Build' `
                  -Description 'Temporaeres Build-Konto' `
                  -AccountNeverExpires `
                  -PasswordNeverExpires
    Write-Log "Konto packer angelegt"
} else {
    Set-LocalUser -Name 'packer' -Password $securePassword -PasswordNeverExpires $true
    Write-Log "Konto packer existierte, Passwort gesetzt"
}

# Ohne Konto ist alles Weitere sinnlos. Lieber hier mit klarer Meldung
# abbrechen, als Packer eine halbe Stunde gegen eine 401 laufen zu lassen.
if ($null -eq (Get-LocalUser -Name 'packer' -ErrorAction SilentlyContinue)) {
    Write-Log "ABBRUCH: Konto 'packer' existiert nach dem Anlegen nicht."
    exit 1
}

# Ueber die SID, nicht den Namen: das Image ist deutschsprachig, die Gruppe
# heisst dort "Administratoren".
$admins = Get-LocalGroup -SID 'S-1-5-32-544'
try {
    Add-LocalGroupMember -Group $admins -Member 'packer' -ErrorAction Stop
    Write-Log "packer ist Mitglied von '$($admins.Name)'"
} catch {
    Write-Log "Gruppenzuweisung: $($_.Exception.Message)"
}

# Den Listener richtet cloudbase-init selbst ein (ConfigWinRMListenerPlugin).
# Offen sein muss der Port trotzdem - und die Basis-Authentifizierung
# eingeschaltet, sonst weist WinRM Packer ab.
Write-Log "Oeffne WinRM-Port und erlaube Basic-Auth"
if ($null -eq (Get-NetFirewallRule -DisplayName 'Packer WinRM 5986' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'Packer WinRM 5986' `
                        -Direction Inbound -Protocol TCP -LocalPort 5986 `
                        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
}
winrm set winrm/config/service/auth '@{Basic="true"}' 2>&1 | Out-File -Append $logFile
winrm set winrm/config/service '@{AllowUnencrypted="false"}' 2>&1 | Out-File -Append $logFile

Write-Log "WinRM-Listener:"
winrm enumerate winrm/config/listener 2>&1 | Out-File -Append $logFile

Write-Log "=== Bootstrap beendet ==="
