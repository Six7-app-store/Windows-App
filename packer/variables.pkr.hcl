variable "image_name" {
  type        = string
  description = "Glance-Image-Name — vom Worker zur Build-Zeit gesetzt. @platform:internal"
  default     = "windows-v1"
}

variable "networks" {
  type        = list(string)
  description = "@openstack:network:id:list Build-Netzwerke"
  default     = ["9b579624-d844-4df3-b38d-89978b31d37d"]
}

# ACHTUNG: Diese Gruppe muss eingehend TCP 5986 erlauben.
#
# Die Ubuntu-App kommt mit einer Gruppe aus, die Port 22 freigibt, weil
# Packer dort ueber SSH provisioniert. Windows kennt keinen SSH-Server;
# Packer spricht WinRM ueber HTTPS auf 5986. Ist der Port zu, haengt der
# Build bis zum Timeout und meldet nur "waiting for WinRM" - die Ursache
# steht dann nirgends.
variable "security_groups" {
  type        = list(string)
  description = "@openstack:security_group:id:list Build-Security-Groups (muss TCP 5986 erlauben)"
  default     = ["693004c0-0935-41a2-b981-08c50d67b69d"]
}

variable "source_image_name" {
  type        = string
  description = "Basis-Image aus Glance @openstack:image:name"
  default     = "Windows 11 25H2 (UEFI)"
}

# Die gp1-Familie scheidet aus: das Basis-Image verlangt min_disk 64 GB,
# gp1 liefert durchgehend 10 GB. win11.medium hat 2 vCPU, 8 GB RAM und
# 80 GB - und bootet ohne Cinder-Volume.
variable "flavor" {
  type        = string
  description = "Flavor fuer die Build-VM @openstack:flavor:name"
  default     = "win11.medium"
}
