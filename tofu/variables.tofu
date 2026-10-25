################################################
# PFLICHT-Variablen
################################################

variable "users" {
  description = "Per-team roster — vom Worker injiziert. @platform:internal"
  type = map(list(object({
    email = string
  })))
  default = {}
}

################################################
# Konfigurierbare Variablen
################################################

# Das unveraenderte Basis-Image. Frueher setzte der Worker hier den Namen des
# Packer-Images ein; seit ADR 0010 gibt es keinen Image-Bau mehr, und die
# Einrichtung laeuft beim ersten Start. Das Image muss cloudbase-init mit
# UserDataPlugin mitbringen - nachgewiesen fuer "Windows 11 25H2 (UEFI)".
variable "image_name" {
  description = "Windows-11-Basis-Image mit cloudbase-init @openstack:image:name"
  type        = string
  default     = "Windows 11 25H2 (UEFI)"
}

# Groesse jeder Nutzer-VM. Nur die win-Flavors tragen das Image: es verlangt
# min_disk 64 GB und min_ram 4096 MB, die gp1-Familie hat durchgehend 10 GB
# Systemplatte. Standard ist der kleinste, win11.medium (2 vCPU, 8 GB RAM,
# 80 GB) - er bootet ohne Cinder-Volume, was bei einem Ausfall des
# Volume-Dienstes den Unterschied macht. Die Liste unten wird im App Store
# zur Auswahl; jede VM kostet das gewaehlte Kontingent einmal pro Nutzer.
variable "flavor_name" {
  description = "Größe jeder VM (CPU, Arbeitsspeicher, Systemplatte) @openstack:flavor:name"
  type        = string
  default     = "win11.medium"

  validation {
    condition     = contains(["win11.medium", "win.default", "win.largedisk"], var.flavor_name)
    error_message = "flavor_name muss win11.medium, win.default oder win.largedisk sein - kleinere Flavors tragen das Windows-Image nicht."
  }
}

#   ipv4  eine Karte im IPv4-Netz (network_v4_uuid)
#   ipv6  eine Karte im IPv6-Netz (network_uuid) - Standard
#   dual  IPv6-Netz als Hauptkarte, dazu eine zweite im IPv4-Netz
variable "ip_mode" {
  description = "Adressfamilie: ipv4, ipv6 oder dual (beide)"
  type        = string
  default     = "ipv6"

  validation {
    condition     = contains(["ipv4", "ipv6", "dual"], var.ip_mode)
    error_message = "ip_mode muss \"ipv4\", \"ipv6\" oder \"dual\" sein."
  }
}

# Der Name bleibt network_uuid, damit bestehende Deployments beim Redeploy
# ihre gespeicherte Netzwahl weiter treffen.
variable "network_uuid" {
  description = "Netz mit öffentlicher IPv6, z. B. DHBWV6 - für ipv6 und dual @openstack:network:id"
  type        = string
  default     = "9b579624-d844-4df3-b38d-89978b31d37d"
}

variable "network_v4_uuid" {
  description = "Netz mit öffentlich gerouteter IPv4, z. B. DHBWv4 - für ipv4 und dual @openstack:network:id"
  type        = string
  default     = ""
}

# RDP mit Passwort-Anmeldung offen ins Internet zu stellen, ist einer der
# meistgenutzten Angriffswege. Deshalb wie bei der Gruppe windows-app nur
# Campusnetz und VPN, fuer beide Familien.
variable "rdp_source_cidr" {
  description = "IPv6-Präfix, das auf Port 3389 (RDP) zugreifen darf"
  type        = string
  default     = "2001:7c0:1b20::/48"
}

variable "rdp_source_cidr_v4" {
  description = "IPv4-Präfix, das auf Port 3389 (RDP) zugreifen darf - nur bei ip_mode ipv4 und dual"
  type        = string
  default     = "141.72.0.0/16"
}

variable "floating_ip_pool" {
  description = "Name des External Networks für Floating IPs @openstack:floating_ip_pool:name"
  type        = string
  default     = "DHBW"
}

variable "shared_secgroup_id" {
  description = "ID der gemeinsamen Security Group für alle VMs @openstack:security_group:id"
  type        = string
  default     = "693004c0-0935-41a2-b981-08c50d67b69d"
}

# Windows 11 ist ein Client-Betriebssystem und laesst nur eine interaktive
# Sitzung gleichzeitig zu. Jeder Nutzer bekommt deshalb eine eigene VM, und
# jede davon kostet 2 vCPU und 8 GB RAM.
#
# Die Obergrenze schuetzt davor, dass ein grosser Kurs das Kontingent des
# Projekts aufbraucht und dabei andere Deployments blockiert. Sie bricht den
# Apply mit einer klaren Meldung ab, statt auf halber Strecke an einem
# Quota-Fehler zu scheitern - der waere schwerer zu deuten und liesse
# halbfertige Instanzen zurueck.
variable "max_users" {
  description = "Obergrenze gleichzeitiger Nutzer-VMs @platform:limit"
  type        = number
  default     = 12

  validation {
    condition     = var.max_users >= 1 && var.max_users <= 25
    error_message = "max_users muss zwischen 1 und 25 liegen. Mehr traegt das RAM-Kontingent nicht: 25 VMs zu 8 GB sind bereits 200 GB."
  }
}
