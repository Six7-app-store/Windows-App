# OpenTofu erwartet weiterhin das Schluesselwort "terraform"; die Provider
# werden ueber registry.opentofu.org aufgeloest. .tofu-Dateien ab 1.8.
terraform {
  required_version = ">= 1.8"

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
# ADRESSFAMILIEN (var.ip_mode)
############################

locals {
  ethertypes = {
    ipv4 = ["IPv4"]
    ipv6 = ["IPv6"]
    dual = ["IPv4", "IPv6"]
  }[var.ip_mode]

  # Bei dual liegt die Hauptschnittstelle im IPv6-Netz, die oeffentliche IPv4
  # kommt als zweite Karte dazu. Windows holt sich deren Adresse per DHCP
  # und antwortet dank Strong-Host-Modell ueber die Karte, an der die Anfrage
  # ankam - eine eigene Routing-Tabelle wie bei den Linux-Apps braucht es
  # nicht.
  primary_network_id = var.ip_mode == "ipv4" ? var.network_v4_uuid : var.network_uuid

  dual = var.ip_mode == "dual"
}

# RDP je Adressfamilie. Bisher kam 3389 allein aus der gemeinsamen Gruppe
# windows-app, die ausserhalb dieses Repos gepflegt wird. Die App bringt
# ihre Regel jetzt selbst mit, wie die Kali-App, mit denselben
# Campus-Praefixen. Eine IPv4-Regel laesst kein IPv6-Paket durch und
# umgekehrt.
#
# Der Name braucht einen Zufallsanhang. Nova loest die Gruppen einer Instanz
# ueber den Namen auf, auch wenn dort die ID steht. Gibt es den Namen zweimal
# im Projekt (zweites Deployment, liegengebliebene Gruppe), scheitert jeder
# Bauversuch mit "Multiple security groups found matching", und die VMs enden
# in ERROR (Kali auf Staging, 24.10.2026).
resource "random_string" "secgroup_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "openstack_networking_secgroup_v2" "rdp" {
  name        = "${local.app_name}-rdp-${random_string.secgroup_suffix.result}"
  description = "RDP zu den Windows-VMs (${var.ip_mode})"
}

resource "openstack_networking_secgroup_rule_v2" "rdp" {
  for_each = toset(local.ethertypes)

  security_group_id = openstack_networking_secgroup_v2.rdp.id
  direction         = "ingress"
  ethertype         = each.key
  protocol          = "tcp"
  port_range_min    = local.login_port
  port_range_max    = local.login_port
  remote_ip_prefix  = each.key == "IPv4" ? var.rdp_source_cidr_v4 : var.rdp_source_cidr
  description       = "RDP (${each.key})"
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

# Unveraendertes Basis-Image, per Name nachgeschlagen (keine IDs
# hardcoden). Ein eigenes Image wird nicht mehr gebaut: Software und
# Kursmaterial richtet windows-multi-user.ps1.tpl beim ersten Start ein.
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

# Fuer alle VMs gleich, deshalb einmal hier statt je Instanz.
locals {
  software_gz = base64gzip(file("${path.module}/files/software.ps1"))
  kurs_json = jsonencode({
    for f in fileset("${path.module}/files/windows-kurs", "**") :
    f => base64gzip(file("${path.module}/files/windows-kurs/${f}"))
  })
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

  # Per ID: Nova nimmt beides an, ein Name ist aber nicht eindeutig, sobald
  # ein zweites Deployment im Projekt eine gleichnamige Gruppe hat.
  security_groups = [var.shared_secgroup_id, openstack_networking_secgroup_v2.rdp.id]

  # Windows braucht fuer den ersten Start deutlich laenger als Linux: das
  # 80-GB-Image wird aus dem Objektspeicher gelesen, danach laeuft die
  # Geraetekonfiguration. 15 Minuten wie bei der Ubuntu-App reichen nicht.
  timeouts {
    create = "30m"
    delete = "20m"
  }

  # Nur die Hauptschnittstelle; die zweite bei dual haengt interface_attach
  # unten an die laufende Instanz.
  network {
    uuid = local.primary_network_id
  }

  # cloudbase-init statt cloud-init. Das Skript wird vom UserDataPlugin
  # ausgefuehrt - nachgewiesen am Image "Windows 11 25H2 (UEFI)", dessen
  # Plugin-Liste UserDataPlugin enthaelt.
  #
  # Softwareskript und Kursmaterial gehen gzip+base64 mit: so stoeren die
  # $-Zeichen von PowerShell das Template nicht, und user_data bleibt weit
  # unter dem Nova-Limit von 64 KB.
  user_data = templatefile("${path.module}/windows-multi-user.ps1.tpl", {
    username    = local.usernames[count.index]
    password    = random_password.user_passwords[count.index].result
    team        = local.all_users[count.index].team
    email       = local.all_users[count.index].email
    software_gz = local.software_gz
    kurs_json   = local.kurs_json
  })

  metadata = merge(local.metadata, {
    team  = local.all_users[count.index].team
    user  = local.usernames[count.index]
    email = local.all_users[count.index].email
  })

  depends_on = [terraform_data.user_limit, openstack_networking_secgroup_rule_v2.rdp]

  lifecycle {
    precondition {
      condition     = var.ip_mode == "ipv6" || var.network_v4_uuid != ""
      error_message = "ip_mode \"${var.ip_mode}\" braucht ein IPv4-Netz in network_v4_uuid."
    }
    precondition {
      condition     = var.ip_mode == "ipv4" || var.network_uuid != ""
      error_message = "ip_mode \"${var.ip_mode}\" braucht ein IPv6-Netz in network_uuid."
    }
  }
}

# Zweite Karte fuer dual: ein Port je VM im IPv4-Netz, an die laufende
# Instanz gehaengt. Windows bezieht die Adresse selbst per DHCP.
resource "openstack_networking_port_v2" "v4" {
  count      = local.dual ? local.vm_count : 0
  name       = "${local.app_name}-${local.usernames[count.index]}-v4"
  network_id = var.network_v4_uuid

  security_group_ids = [
    var.shared_secgroup_id,
    openstack_networking_secgroup_v2.rdp.id,
  ]
}

resource "openstack_compute_interface_attach_v2" "v4" {
  count       = local.dual ? local.vm_count : 0
  instance_id = openstack_compute_instance_v2.user_vm[count.index].id
  port_id     = openstack_networking_port_v2.v4[count.index].id
}

# -----------------------------------------------------------------------------
# Optional Floating IP (eine je Nutzer-VM)
# -----------------------------------------------------------------------------
resource "openstack_networking_floatingip_v2" "fip" {
  count = local.enable_floating_ip ? local.vm_count : 0
  pool  = data.openstack_networking_network_v2.external[0].name
}

# Warten, bis cloudbase-init Konto und RDP eingerichtet hat. Ohne das meldet
# OpenTofu fertig, sobald die Instanz ACTIVE ist - die Zugangsdaten gingen
# dann raus, bevor die Anmeldung funktioniert.
#
# Bewusst nicht bis zum Ende der Softwareinstallation (10 bis 20 Minuten
# mehr): der Worker bricht ein Apply nach 30 Minuten ab, und das Anlegen der
# Instanz selbst kann davon schon die Haelfte brauchen.
resource "time_sleep" "wait_for_vm" {
  depends_on      = [openstack_compute_instance_v2.user_vm, openstack_compute_interface_attach_v2.v4]
  create_duration = "300s"
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
