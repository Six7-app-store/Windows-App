terraform {
  required_version = ">= 1.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.54"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10"
    }
  }
}

provider "openstack" {
  cloud = "openstack"
  # Auth via OS_CLOUD + clouds.yaml (oder OS_* env vars)
}

############################
# APP-DEFAULTS (vom App-Entwickler vorgegeben)
############################

locals {
  app_name = "windows-user"

  # Kleinster Flavor, der das Image traegt: das Glance-Image verlangt
  # min_disk 64 GB und min_ram 4096 MB. Die gp1-Familie scheidet damit aus,
  # sie hat durchgehend 10 GB Systemplatte. win11.medium liefert 2 vCPU,
  # 8 GB RAM und 80 GB - und bootet ohne Cinder-Volume, was bei einem
  # Ausfall des Volume-Dienstes den Unterschied macht.
  flavor = "win11.medium"

  # Kein Keypair: Windows meldet sich per RDP mit Benutzername und Passwort
  # an. Der oeffentliche Schluessel waere hier wirkungslos - das Image
  # bringt keinen SSH-Server mit.
  key_pair = ""

  # Adressen in DHBWv4 sind oeffentlich geroutet, die feste Adresse der
  # Instanz ist also fuer sich erreichbar.
  enable_floating_ip = false

  # RDP statt SSH.
  login_port = 3389

  metadata = {}
}

############################
# USER MANAGEMENT (CONTRACT)
############################

# Flatten users from teams - EXAKT wie im Contract vorgegeben
locals {
  all_users = flatten([
    for team, members in var.users : [
      for member in members : {
        id    = "${team}-${replace(split("@", member.email)[0], ".", "-")}"
        team  = team
        email = member.email
        # Windows begrenzt lokale Benutzernamen auf 20 Zeichen. Laengere
        # legt New-LocalUser gar nicht erst an - ohne Kuerzung hier waere
        # der Fehler erst im Startskript der VM sichtbar, also nach dem
        # Apply und ohne Bezug zur Ursache.
        username = substr(replace(split("@", member.email)[0], ".", ""), 0, 20)
      }
    ]
  ])

  unique_teams = distinct([for user in local.all_users : user.team])

  # Eine VM pro Nutzer. Windows 11 ist ein Client-Betriebssystem und laesst
  # nur eine interaktive Sitzung gleichzeitig zu - auf einer geteilten VM
  # wuerden sich die Studierenden gegenseitig aus der Sitzung werfen.
  vm_count = length(local.all_users)

  usernames = [for user in local.all_users : user.username]
  emails    = [for user in local.all_users : user.email]
  user_ids  = [for user in local.all_users : user.id]
}

# Bricht ab, bevor irgendetwas angelegt wird. Ohne diese Pruefung liefe der
# Apply bis zum Quota-Fehler von Nova und liesse dabei bereits erzeugte
# Instanzen stehen.
resource "terraform_data" "user_limit" {
  lifecycle {
    precondition {
      condition     = length(local.all_users) <= var.max_users
      error_message = "Diese App legt eine VM je Nutzer an (Windows 11 erlaubt nur eine Sitzung gleichzeitig). Angefordert: ${length(local.all_users)}, erlaubt: ${var.max_users}. Entweder max_users anheben oder den Kurs aufteilen."
    }
  }
}

# Passwörter für jeden User generieren
#
# override_special ist bewusst enger als der Standard: Windows-Passwoerter
# landen hier in einem PowerShell-Skript in einfachen Anfuehrungszeichen.
# Ein Apostroph darin wuerde die Zeichenkette beenden und das Skript
# zerlegen; die Zeichen unten sind alle unkritisch.
resource "random_password" "user_passwords" {
  count            = length(local.all_users)
  length           = 16
  special          = true
  override_special = "!@%^*_-+="
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

# Packer-built image lookup by name (keine IDs hardcoden)
data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}

# External network nur noetig, wenn Floating IP aktiviert ist - und nur
# dann wird es auch abgefragt.
#
# Ohne count laeuft die Abfrage bedingungslos und bricht den Plan ab, wenn
# das Netz im Projekt nicht existiert: "Your query returned no results".
# Genau das ist passiert - der Standardwert "DHBW" stammt aus der
# Ubuntu-App, im Projekt ma_wwi_24sea_appstore_g1 gibt es nur NAT und
# DHBWV6. Da enable_floating_ip hier ohnehin false ist, wurde ein Netz
# gesucht, das niemand braucht.
data "openstack_networking_network_v2" "external" {
  count = local.enable_floating_ip ? 1 : 0
  name  = var.floating_ip_pool
}

# -----------------------------------------------------------------------------
# Eine VM je Nutzer
# -----------------------------------------------------------------------------
resource "openstack_compute_instance_v2" "user_vm" {
  count       = local.vm_count
  name        = "${local.app_name}-${local.usernames[count.index]}"
  image_id    = data.openstack_images_image_v2.image.id
  flavor_name = local.flavor
  key_pair    = local.key_pair != "" ? local.key_pair : null

  security_groups = [var.shared_secgroup_id]

  # Windows braucht fuer den ersten Start deutlich laenger als Linux: das
  # 80-GB-Image wird aus dem Objektspeicher gelesen, danach laeuft die
  # Geraetekonfiguration. 15 Minuten wie bei der Ubuntu-App reichen nicht.
  timeouts {
    create = "30m"
    delete = "20m"
  }

  network {
    uuid = var.network_uuid
  }

  # cloudbase-init statt cloud-init. Das Skript wird vom UserDataPlugin
  # ausgefuehrt - nachgewiesen am Image "Windows 11 25H2 (UEFI)", dessen
  # Plugin-Liste UserDataPlugin enthaelt.
  user_data = templatefile("${path.module}/windows-multi-user.ps1.tpl", {
    username = local.usernames[count.index]
    password = random_password.user_passwords[count.index].result
    team     = local.all_users[count.index].team
    email    = local.all_users[count.index].email
  })

  metadata = merge(local.metadata, {
    team  = local.all_users[count.index].team
    user  = local.usernames[count.index]
    email = local.all_users[count.index].email
  })

  depends_on = [terraform_data.user_limit]
}

# -----------------------------------------------------------------------------
# Optional Floating IP (eine je Nutzer-VM)
# -----------------------------------------------------------------------------
resource "openstack_networking_floatingip_v2" "fip" {
  count = local.enable_floating_ip ? local.vm_count : 0
  pool  = data.openstack_networking_network_v2.external[0].name
}

# Warten bis die VMs vollständig gebootet sind
resource "time_sleep" "wait_for_vm" {
  count           = local.enable_floating_ip ? 1 : 0
  depends_on      = [openstack_compute_instance_v2.user_vm]
  create_duration = "120s"
}

# Port-ID je VM finden
data "openstack_networking_port_v2" "vm_port" {
  count     = local.enable_floating_ip ? local.vm_count : 0
  device_id = openstack_compute_instance_v2.user_vm[count.index].id
  depends_on = [
    openstack_compute_instance_v2.user_vm,
    time_sleep.wait_for_vm
  ]
}

resource "openstack_networking_floatingip_associate_v2" "fip_assoc" {
  count       = local.enable_floating_ip ? local.vm_count : 0
  floating_ip = openstack_networking_floatingip_v2.fip[count.index].address
  port_id     = data.openstack_networking_port_v2.vm_port[count.index].id

  depends_on = [
    data.openstack_networking_port_v2.vm_port,
    time_sleep.wait_for_vm
  ]
}
