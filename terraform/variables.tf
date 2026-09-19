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

variable "image_name" {
  description = "Glance-Image-Name — vom Worker zur Apply-Zeit gesetzt. @platform:internal"
  type        = string
}

################################################
# Konfigurierbare Variablen
################################################

variable "network_uuid" {
  description = "Hauptnetzwerk @openstack:network:id"
  type        = string
  default     = "9b579624-d844-4df3-b38d-89978b31d37d"
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
