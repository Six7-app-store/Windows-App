
############################
# Adresse, unter der die VM erreichbar ist
############################

# Die Nutzer-VMs haengen in einem doppelstapeligen Netz. Ihre IPv4-Adresse
# stammt aus 10.200.0.0/19 und ist ausschliesslich projektintern - wer sie
# einem Studierenden schickt, schickt ihm eine Adresse, unter der er nichts
# erreicht. Oeffentlich erreichbar ist allein die IPv6-Adresse.
#
# Deshalb steht hier access_ip_v6 und nicht, wie bei der Ubuntu-App,
# network[0].fixed_ip_v4.
#
# Die eckigen Klammern sind Absicht. Die Plattform setzt die Adresse als
# "<ip>:<port>" zusammen; ohne Klammern entstuende daraus
# "2001:7c0:1b20:c913:1::3b1:3389", und niemand koennte sagen, wo die
# Adresse aufhoert und der Port anfaengt. Mit Klammern ist es genau die
# Form, die der RDP-Client erwartet:
#
#     mstsc /v:[2001:7c0:1b20:c913:1::3b1]:3389
#
# Fehlt wider Erwarten eine IPv6-Adresse, faellt die Ausgabe auf IPv4
# zurueck - dann ist die Adresse zwar nur intern brauchbar, aber besser als
# gar keine.
locals {
  vm_adressen = [
    for i in range(local.vm_count) :
    local.enable_floating_ip
    ? openstack_networking_floatingip_v2.fip[i].address
    : (
      openstack_compute_instance_v2.user_vm[i].access_ip_v6 != ""
      ? "[${openstack_compute_instance_v2.user_vm[i].access_ip_v6}]"
      : openstack_compute_instance_v2.user_vm[i].network[0].fixed_ip_v4
    )
  ]
}

############################
# [CONTRACT] User Accounts Output
############################

# Gleiche Form wie bei der Ubuntu-App, damit die Plattform nichts
# Sonderbares fuer Windows kennen muss. Der einzige Unterschied steckt in
# `port`: 3389 statt 22, also RDP statt SSH. `type` bleibt "password" -
# die Anmeldung laeuft in beiden Faellen ueber Benutzername und Passwort.
output "user_accounts" {
  description = "[CONTRACT] User accounts mit Login-Informationen"
  sensitive   = true # Enthält Passwörter
  value = length(local.all_users) > 0 ? {
    for i in range(length(local.all_users)) : local.user_ids[i] => {
      type     = "password"
      ip       = local.vm_adressen[i]
      port     = local.login_port
      username = local.usernames[i]
      auth     = random_password.user_passwords[i].result
      email    = local.emails[i]
      team     = local.all_users[i].team
    }
  } : {}
}

############################
# VM Details
############################

output "team_vms" {
  description = "Details der Nutzer-VMs"
  value = local.vm_count > 0 ? {
    for i in range(length(local.all_users)) : local.user_ids[i] => {
      instance_id   = openstack_compute_instance_v2.user_vm[i].id
      instance_name = openstack_compute_instance_v2.user_vm[i].name
      # Beide Adressen, damit bei einer Stoerung nachvollziehbar ist,
      # welche die VM tatsaechlich bekommen hat.
      address_v6  = openstack_compute_instance_v2.user_vm[i].access_ip_v6
      fixed_ip_v4 = openstack_compute_instance_v2.user_vm[i].network[0].fixed_ip_v4
      floating_ip = local.enable_floating_ip ? openstack_networking_floatingip_v2.fip[i].address : null
      username    = local.usernames[i]
      team        = local.all_users[i].team
      # Windows-Bordmittel. Das Passwort steht bewusst nicht drin - es
      # kommt aus user_accounts, und das ist als sensitive markiert.
      #
      # Der Benutzername braucht das fuehrende .\ - ohne das sucht der
      # RDP-Client das Konto bei Microsoft oder in einer Domaene und
      # findet es nie.
      rdp_command = "mstsc /v:${local.vm_adressen[i]}:${local.login_port}   (Benutzer: .\\${local.usernames[i]})"
    }
  } : {}
}

output "teams_summary" {
  description = "Übersicht: Anzahl VMs und User"
  value = {
    vm_count   = local.vm_count
    user_count = length(local.all_users)
    usernames  = local.usernames
    emails     = local.emails
    teams      = local.unique_teams
  }
}
