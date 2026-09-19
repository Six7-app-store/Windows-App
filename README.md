# Windows 11 Desktop App

Eine Windows-Lernumgebung für Hochschulkurse. Jeder Studierende bekommt eine
eigene Windows-11-VM mit RDP-Zugang und ein vorgefertigtes Kursverzeichnis mit
Übungsaufgaben und einer PowerShell-Kurzreferenz.

Das Gegenstück zur [Ubuntu Terminal App](../Ubuntu-App). Gleicher Vertrag,
gleiche Ausgaben — drei Dinge sind aber anders, und die sind es wert, vorher
gelesen zu werden.

## Was anders ist als bei Ubuntu

| | Ubuntu-App | Windows-App |
|---|---|---|
| VMs | **1**, von allen geteilt | **1 pro Nutzer** |
| Zugang | SSH, Port 22 | RDP, Port 3389 |
| Provisionierung | cloud-init | cloudbase-init (PowerShell) |
| Flavor | `gp1.small` | `win11.medium` |
| Packer-Verbindung | SSH | WinRM über HTTPS, Port 5986 |

**Warum eine VM pro Nutzer?** Windows 11 ist ein Client-Betriebssystem und
lässt nur eine interaktive Sitzung gleichzeitig zu. Auf einer geteilten VM
würden sich die Studierenden gegenseitig aus der Sitzung werfen. Das ist keine
Konfigurationsfrage, sondern eine Lizenzbeschränkung von Windows Client.

**Das kostet Kontingent.** Jede VM belegt 2 vCPU und 8 GB RAM. Bei einem
RAM-Kontingent von 128 GB sind das höchstens 16 VMs, und davon braucht das
Projekt einen Teil für anderes. `max_users` steht deshalb auf **12** und bricht
den Apply mit einer erklärenden Meldung ab, statt mitten im Anlegen an einem
Quota-Fehler zu scheitern.

## Vorinstallierte Software

- Python 3 (inkl. pip)
- Node.js 24 (inkl. npm)
- Git, Visual Studio Code, Notepad++, 7-Zip, Chrome
- Chocolatey als Paketmanager

## Kursverzeichnis

Nach der ersten Anmeldung liegt auf dem Desktop:

    Desktop\Windows-Kurs\
    ├── LIES_MICH.txt              ← PowerShell-Kurzreferenz, mit Linux-Vergleich
    ├── beispieldaten\
    │   ├── studenten.csv          ← CSV für Übungen mit Import-Csv, Where-Object
    │   └── server.log             ← Logdatei für Übungen mit Select-String
    └── uebungen\
        ├── 01-explorer-und-pfade\
        ├── 02-powershell-grundlagen\
        ├── 03-dateien-und-rechte\
        ├── 04-prozesse-und-dienste\
        └── 05-skripte\

Das Material liegt im Image unter `C:\Users\Default` — dem Windows-Gegenstück
zu `/etc/skel`. Windows kopiert es beim ersten Anmelden in das neue Profil.

Die Kurzreferenz stellt jedem PowerShell-Befehl bewusst das Linux-Äquivalent
gegenüber. Wer den Ubuntu-Kurs kennt, sucht genau das.

## User-Management

- **Ein Account und eine eigene VM pro Nutzer**, abgeleitet aus der
  E-Mail-Adresse (`alice.smith@dhbw.de` → `alicesmith`)
- Benutzernamen werden auf **20 Zeichen gekürzt** — Windows legt längere
  lokale Konten nicht an
- Jeder Nutzer erhält ein automatisch generiertes, zufälliges Passwort
- Mitglied in *Remotedesktopbenutzer* und *Administratoren* (analog zu `sudo`
  bei der Ubuntu-App)
- RDP-Login mit Benutzername und Passwort

Die Gruppen werden über ihre SID zugewiesen (`S-1-5-32-555`, `S-1-5-32-544`),
nicht über den Namen: das Basis-Image ist deutschsprachig, die Gruppen heißen
dort *Remotedesktopbenutzer* und *Administratoren*.

## VM-Deployment

| | |
|---|---|
| VMs gesamt | **1 pro Nutzer** |
| VMs pro Team | — |
| VMs pro Nutzer | **1** |
| Flavor | `win11.medium` (2 vCPU, 8 GB RAM, 80 GB) |
| Netz | `DHBWV6` — doppelstapelig, IPv4 `10.200.0.0/19` und IPv6 |
| Floating IP | Nein — die Instanz ist über ihre IPv6-Adresse direkt erreichbar |

Die `gp1`-Familie scheidet aus: das Basis-Image verlangt `min_disk` 64 GB,
`gp1` liefert durchgehend 10 GB. `win11.medium` bootet außerdem ohne
Cinder-Volume, was bei einem Ausfall des Volume-Dienstes den Unterschied
zwischen „läuft" und „läuft nicht" ausmacht.

## Konfigurierbare Variablen

| Variable | Beschreibung | Pflicht |
|---|---|---|
| `network_uuid` | UUID des internen Netzwerks | Ja |
| `floating_ip_pool` | Name des External Networks für Floating IPs | Ja |
| `shared_secgroup_id` | ID der gemeinsamen Security Group | Ja |
| `max_users` | Obergrenze gleichzeitiger Nutzer-VMs (Standard 12) | Nein |

> **Die voreingestellte Security Group heißt `windows-app`** und erlaubt TCP
> 3389 (RDP für die Studierenden) sowie TCP 5986 (WinRM, nur für den
> Packer-Build) — beides aus `2001:7c0:1b20::/48` und `141.72.0.0/16`, also
> aus dem Campusnetz. **Studierende brauchen damit das DHBW-VPN.** Das ist
> Absicht: RDP mit Passwort-Anmeldung offen ins Internet zu stellen, ist einer
> der meistgenutzten Angriffswege überhaupt.
>
> Ist 5986 zu, hängt der Packer-Build bis zum Timeout und meldet nur
> `waiting for WinRM`, ohne die Ursache zu nennen. Die Ubuntu-App kommt mit
> Port 22 aus, weil Packer dort über SSH provisioniert.

## Deployment-Dauer

| Schritt | Dauer (ca.) |
|---|---|
| Packer Image Build | 25–40 min |
| Terraform apply | 10–20 min |
| **Gesamt (Erstdeployment)** | **35–60 min** |

Deutlich länger als bei Ubuntu, und das hat handfeste Gründe: das Basis-Image
ist 80 GB groß und wird beim ersten Start aus dem Objektspeicher gelesen,
danach läuft die Windows-Gerätekonfiguration. Die Timeouts in `main.tf` stehen
deshalb auf 30 Minuten statt auf 15.

Bei Folge-Deployments (Image bereits gebaut) nur Terraform: **10–20 min**.

## Stand der Erprobung

Ehrlichkeitshalber, weil das für die Bewertung des Codes zählt:

**Nachgewiesen** an einer Testinstanz des Basis-Images `Windows 11 25H2 (UEFI)`:

- Das Image bootet auf `win11.medium` ohne Cinder-Volume
- cloudbase-init läuft durch und führt `UserDataPlugin` aus — ein
  mitgegebenes PowerShell-Skript wird tatsächlich ausgeführt
- Das Skript kann Firewallregeln anlegen (`Enabled: True` im Konsolenlog)
- cloudbase-init richtet einen WinRM-HTTPS-Listener ein — die Grundlage für
  den Packer-Build
- Das eingebaute `Administrator`-Konto ist deaktiviert und für die Anmeldung
  unbrauchbar. Deshalb legen sowohl `bootstrap.ps1.tpl` als auch
  `windows-multi-user.ps1.tpl` ein eigenes Konto an, statt das vorhandene zu
  benutzen.

- **Windows holt sich seine IPv6-Adresse per DHCPv6 nicht.** Eine Testinstanz
  hatte die in Neutron reservierte Adresse nie auf der Karte und antwortete
  nicht einmal auf Ping, während eine Linux-VM im selben Netz einwandfrei
  lief. `NetworkConfigPlugin` benennt die Karte nur um und setzt die MTU.
  Das Startskript liest die Adresse deshalb aus `network_data.json` und setzt
  sie selbst — die Metadaten enthalten sie samt Gateway.

**Nicht erprobt:**

- Ein vollständiger Packer-Build dieses Images
- Ein `terraform apply` mit echten Nutzern
- Der RDP-Zugang durch einen Studierenden
- Ob die selbst gesetzte IPv6-Adresse die Instanz tatsächlich erreichbar macht
- Die Softwareinstallation über Chocolatey **bis Node.js** — Chocolatey,
  Python 3.14.7 und zwölf Abhängigkeiten liefen durch
- Was danach kommt: Git, VS Code, das Kursverzeichnis, Neustart, Aufräumen

**Ein zweiter Versuch am 19.09.2026 scheiterte an `401 - invalid content type`.**
Ursache war weder Netz noch Zertifikat: `New-LocalUser` lehnte eine
Beschreibung mit 54 Zeichen ab — bei lokalen Konten sind höchstens 48 erlaubt.
Das Build-Konto entstand nie, der Rest des Skripts lief aber weiter und öffnete
den WinRM-Port, sodass es nach einem Verbindungsproblem aussah. Beide Skripte
prüfen jetzt nach dem Anlegen, ob das Konto existiert, und brechen sonst mit
klarer Meldung ab.

**Ein erster Deploy-Versuch am 19.09.2026 ist gescheitert**, und zwar an
Voreinstellungen, die aus der Ubuntu-App übernommen und nicht gegen diesen
Tenant geprüft waren: `Unable to find security_group with name or id
'4ffaf007-...'`. Netz- und Security-Group-IDs sind seither die des Projekts
`ma_wwi_24sea_appstore_g1`.

**Ein dritter Versuch scheiterte an einer geratenen Versionsnummer:**
`choco install nodejs-lts --version=24.0.0` fand nichts — Chocolatey führt
unter `nodejs-lts` die echten Node-Releases, und eine glatte `24.0.0` ist
keines davon. Die Festlegung ist entfallen; installiert wird die jeweils
aktuelle LTS-Fassung, und die tatsächlich installierten Versionen stehen am
Ende des Build-Protokolls. Außerdem sind die Pakete jetzt in Pflicht
(Python, Node, Git) und Kür (Editoren, Browser) geteilt — ein fehlendes
Kür-Paket wirft keinen halbstündigen Build mehr weg.

**Ein vierter Versuch lief acht Minuten und scheiterte am Protokollblock.**
`choco list --local-only` — ein Schalter, den Chocolatey seit Version 2.0 nicht
mehr kennt, während das Image 2.7.4 mitbringt. Der Aufruf endete mit Code 1.
Weil `python`, `node` und `git` in derselben Sitzung noch nicht im `PATH`
standen (Chocolatey warnt ausdrücklich davor), blieb `$LASTEXITCODE` auf dieser
1 stehen, und Packers Wrapper beendet das Skript mit `exit $LastExitCode`.
Eine reine Auskunft hat damit einen vollständig erfolgreichen Build verworfen.

Beide Skripte enden jetzt mit einem ausdrücklichen `exit 0`, und der
Protokollblock lädt vorher den `PATH` aus der Maschinen-Umgebung nach.
