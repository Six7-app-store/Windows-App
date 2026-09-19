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
# Build-Konto entfernen - als allerletztes
# -----------------------------------------------------------------------------
# Das Passwort dieses Kontos steht im Build-Protokoll von Packer. Bliebe das
# Konto im Image, haette jeder, der ein Build-Log sieht, einen
# Administratorzugang auf saemtlichen Nutzer-VMs.
#
# Die Reihenfolge ist nicht beliebig: dieses Skript laeuft selbst unter
# 'packer'. Wird das Konto frueher entfernt, koennen die nachfolgenden
# Schritte an ihrem Zugriffstoken scheitern. Deshalb steht es hier unten,
# wenn nichts Wichtiges mehr kommt.
Write-Output "Entferne Build-Konto 'packer'"
Remove-Item -Path 'C:\Windows\Temp\packer-bootstrap.log' -Force -ErrorAction SilentlyContinue
Remove-LocalUser -Name 'packer' -ErrorAction SilentlyContinue
# Das Profilverzeichnis ist waehrend der laufenden Sitzung gesperrt und
# bleibt in der Regel stehen. Das ist hinnehmbar - es enthaelt keine
# Zugangsdaten, nur die Reste einer Anmeldung.
Remove-Item -Path 'C:\Users\packer' -Recurse -Force -ErrorAction SilentlyContinue

Write-Output "=== Aufraeumen beendet ==="
