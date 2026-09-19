# =============================================================================
# Letzter Schritt des Builds: Build-Spuren entfernen und cloudbase-init so
# hinterlassen, dass es beim naechsten Start der abgeleiteten VM erneut
# laeuft. Ohne diesen Schritt haelt cloudbase-init sich fuer fertig und
# legt auf den Nutzer-VMs kein Konto an.
#
# Bewusst KEIN sysprep /generalize.
#
# Der lehrbuchmaessige Weg waere Sysprep, und er hat einen echten Vorteil:
# jede abgeleitete VM bekaeme eine eigene Maschinen-SID. Dagegen steht,
# dass Sysprep auf einem Windows-11-Client mit frisch installierter
# Software regelmaessig abbricht ("SYSPRP Package ... was installed for a
# user but not provisioned for all users"), und dass ein abgebrochener
# Sysprep das Image unbrauchbar macht, ohne dass der Build das merkt.
#
# Die gemeinsame SID ist hier vertretbar: jede VM gehoert genau einem
# Studierenden, keine tritt einer Domaene bei, und sie reden nicht
# miteinander. Wer das aendern will, braucht eine Unattend-Datei, die
# cloudbase-init nach dem Generalisieren wieder einschaltet - die liegt im
# Image unter "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\".
# =============================================================================

$ErrorActionPreference = "Continue"

Write-Output "=== Aufraeumen vor dem Abbild ==="

# -----------------------------------------------------------------------------
# cloudbase-init zuruecksetzen
# -----------------------------------------------------------------------------
# cloudbase-init merkt sich in der Registry, dass es seine Plugins schon
# ausgefuehrt hat. Ohne Loeschen dieses Zweigs laeuft auf der abgeleiteten
# VM weder CreateUserPlugin noch UserDataPlugin - die Nutzer-VM haette dann
# kein Konto und niemand kaeme hinein.
Write-Output "Setze cloudbase-init zurueck"
$cbInitKey = 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init'
if (Test-Path $cbInitKey) {
    Remove-Item -Path $cbInitKey -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "  Registry-Zweig entfernt"
}

Set-Service -Name 'cloudbase-init' -StartupType Automatic -ErrorAction SilentlyContinue
Write-Output "  Dienst auf Automatisch gesetzt"

# -----------------------------------------------------------------------------
# Aufraeumen
# -----------------------------------------------------------------------------
Write-Output "Leere temporaere Verzeichnisse"
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue

Write-Output "Leere Ereignisprotokolle"
Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
    Where-Object { $_.RecordCount -gt 0 } |
    ForEach-Object {
        try { [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($_.LogName) } catch { }
    }

# Nullt den freien Speicher, damit das Abbild kleiner wird. Bei 80 GB lohnt
# sich das: die nicht beschriebenen Bloecke komprimieren dann gegen Null.
Write-Output "Nulle freien Speicher (dauert einige Minuten)"
$zeroFile = 'C:\zero.tmp'
try {
    fsutil file createnew $zeroFile 1 | Out-Null
    Remove-Item $zeroFile -Force -ErrorAction SilentlyContinue
    & "$env:SystemRoot\System32\cipher.exe" /w:C | Out-Null
} catch {
    Write-Output "  uebersprungen: $($_.Exception.Message)"
}

# -----------------------------------------------------------------------------
# Das Build-Konto wird hier NICHT entfernt
# -----------------------------------------------------------------------------
# Es waere naheliegend, 'packer' als letzten Schritt zu loeschen. Genau das
# stand hier, und genau daran ist der Build gescheitert:
#
#     Entferne Build-Konto 'packer'
#     Retryable error: http response error: 401 - invalid content type
#
# Packer meldet sich mit diesem Konto bei JEDER WinRM-Anfrage neu an. Wer es
# waehrend eines Provisioners entfernt, nimmt Packer die Zugangsdaten mitten
# im Lauf weg - ein Deaktivieren oder ein neues Passwort haette dieselbe
# Wirkung.
#
# Entfernt wird es deshalb beim ersten Start jeder Nutzer-VM, durch
# windows-multi-user.ps1.tpl. Das laeuft ueber cloudbase-init und damit
# garantiert, bevor sich ein Studierender anmelden kann.
#
# Im Abbild selbst bleibt das Konto bestehen. Sein Passwort wird bei jedem
# Build neu erzeugt und steht nur im Build-Protokoll.

Write-Output "=== Aufraeumen beendet ==="

# Ausdruecklich, aus demselben Grund wie in provision.ps1: Packers Wrapper
# beendet das Skript mit "exit $LastExitCode". In diesem Skript laufen
# fsutil und cipher, die beide ungleich null zurueckgeben koennen, ohne
# dass etwas Wichtiges schiefgegangen waere - das Nullen des freien
# Speichers ist Kosmetik fuer die Abbildgroesse. Alles, was hier wirklich
# zaehlt, laeuft ueber Cmdlets und wuerde eine Ausnahme werfen.
exit 0
