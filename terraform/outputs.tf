
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
      ip       = local.enable_floating_ip ? openstack_networking_floatingip_v2.fip[i].address : openstack_compute_instance_v2.user_vm[i].network[0].fixed_ip_v4
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
      fixed_ip      = openstack_compute_instance_v2.user_vm[i].network[0].fixed_ip_v4
      floating_ip   = local.enable_floating_ip ? openstack_networking_floatingip_v2.fip[i].address : null
      username      = local.usernames[i]
      team          = local.all_users[i].team
      # Windows-Bordmittel. Das Passwort steht bewusst nicht drin - es
      # kommt aus user_accounts, und das ist als sensitive markiert.
      rdp_command = "mstsc /v:${local.enable_floating_ip ? openstack_networking_floatingip_v2.fip[i].address : openstack_compute_instance_v2.user_vm[i].network[0].fixed_ip_v4}:${local.login_port}"
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
