# Prueft, wie VMs, Zugangsdaten und Startskript aus den Variablen entstehen.
# Alle Provider sind gemockt: der Test braucht keinen OpenStack-Zugang und
# legt nichts an.
#
#   cd tofu && tofu init -backend=false && tofu test

mock_provider "openstack" {
  mock_data "openstack_images_image_v2" {
    defaults = {
      id = "00000000-0000-0000-0000-00000000image"
    }
  }
  mock_resource "openstack_compute_instance_v2" {
    defaults = {
      access_ip_v6 = "2001:db8::42"
      network      = { fixed_ip_v4 = "10.200.0.42" }
    }
  }
  mock_resource "openstack_networking_port_v2" {
    defaults = {
      all_fixed_ips = ["141.72.10.7"]
    }
  }
}

mock_provider "random" {}
mock_provider "time" {}

variables {
  users = {
    "Team #1" = [{ email = "Anna.Alt@dhbw.de" }]
    "team-b" = [
      { email = "ben@dhbw.de" },
      { email = "maximilian.mustermann-schmidt@dhbw.de" },
    ]
  }
}

run "eine_vm_je_nutzer" {
  command = apply

  assert {
    condition     = length(openstack_compute_instance_v2.user_vm) == 3
    error_message = "Jeder Nutzer braucht eine eigene VM - Windows 11 erlaubt nur eine Sitzung."
  }
  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : vm.flavor_name == "win11.medium"])
    error_message = "Das Basis-Image verlangt 64 GB Systemplatte; win11.medium ist der kleinste Flavor dafuer."
  }
  assert {
    condition     = alltrue([for u in local.usernames : length(u) <= 20])
    error_message = "Windows legt lokale Konten mit mehr als 20 Zeichen nicht an."
  }
  assert {
    condition     = contains(local.usernames, "maximilianmustermann")
    error_message = "Lange Namen muessen auf 20 Zeichen gekuerzt werden."
  }
}

run "groessere_vm_waehlbar" {
  command = plan

  variables {
    flavor_name = "win.largedisk"
  }

  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : vm.flavor_name == "win.largedisk"])
    error_message = "Der gewaehlte Flavor muss auf jeder Nutzer-VM ankommen."
  }
}

run "zu_kleiner_flavor_wird_abgelehnt" {
  command = plan

  variables {
    flavor_name = "gp1.small"
  }

  expect_failures = [var.flavor_name]
}

run "startskript" {
  command = apply

  # Ohne diese Kopfzeile fuehrt cloudbase-init das Skript gar nicht aus.
  assert {
    condition     = startswith(openstack_compute_instance_v2.user_vm[0].user_data, "#ps1_sysnative")
    error_message = "user_data muss mit #ps1_sysnative beginnen."
  }
  # Ein uebersehenes Template-Zeichen kaeme als Text auf der VM an.
  assert {
    condition     = !strcontains(openstack_compute_instance_v2.user_vm[0].user_data, "$${username}")
    error_message = "Das Startskript enthaelt einen nicht ersetzten Platzhalter."
  }
  # Nova nimmt hoechstens 64 KB - gemessen an der base64-Form, die der
  # Provider uebertraegt.
  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : length(base64encode(vm.user_data)) < 65535])
    error_message = "user_data ist groesser als das Nova-Limit von 64 KB."
  }
  assert {
    condition     = length(jsondecode(local.kurs_json)) == 8
    error_message = "Das Kursmaterial muss vollstaendig in user_data stehen (8 Dateien unter files/windows-kurs)."
  }
}

run "zugangsdaten" {
  command = apply

  # Die Plattform setzt "<ip>:<port>" zusammen; ohne Klammern waere bei IPv6
  # nicht zu erkennen, wo die Adresse aufhoert.
  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.ip == "[2001:db8::42]"])
    error_message = "Die Zugangsadresse muss die IPv6 in eckigen Klammern sein."
  }
  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.port == 3389 && a.type == "password"])
    error_message = "Zugang ist RDP auf 3389 mit Passwort."
  }
  assert {
    condition     = contains(keys(output.user_accounts), "team-b-ben")
    error_message = "Schluessel der Zugangsdaten sind <team>-<lokalteil>."
  }
}

run "obergrenze" {
  command = plan

  variables {
    max_users = 2
  }

  expect_failures = [terraform_data.user_limit]
}

# Der Provider liefert access_ip_v6 mit Klammern; es darf trotzdem nur ein
# Paar entstehen.
run "ipv6_mit_klammern_vom_provider" {
  command = apply

  override_resource {
    target = openstack_compute_instance_v2.user_vm
    values = {
      access_ip_v6 = "[2001:db8::42]"
    }
  }

  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.ip == "[2001:db8::42]"])
    error_message = "Die IPv6 muss genau einmal eingeklammert sein."
  }
}

run "rdp_gruppe_mit_eindeutigem_namen" {
  command = apply

  override_resource {
    target = random_string.secgroup_suffix
    values = {
      result = "x7k2qa"
    }
  }

  assert {
    condition     = openstack_networking_secgroup_v2.rdp.name == "windows-user-rdp-x7k2qa"
    error_message = "Der Name der RDP-Gruppe braucht den Zufallsanhang, sonst kollidieren zwei Deployments im selben Projekt."
  }
}

run "ipv6_ist_standard" {
  command = apply

  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.rdp) == ["IPv6"]
    error_message = "Ohne Auswahl gilt ipv6: eine RDP-Regel fuer IPv6."
  }
  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : vm.network[0].uuid == "9b579624-d844-4df3-b38d-89978b31d37d"])
    error_message = "ipv6 haengt die VMs ins IPv6-Netz."
  }
  assert {
    condition     = length(openstack_compute_interface_attach_v2.v4) == 0
    error_message = "ipv6 braucht keine zweite Karte."
  }
}

run "zugang_ueber_ipv4" {
  command = apply

  variables {
    ip_mode         = "ipv4"
    network_v4_uuid = "00000000-0000-0000-0000-0000000000v4"
  }

  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : vm.network[0].uuid == "00000000-0000-0000-0000-0000000000v4"])
    error_message = "ipv4 muss die VMs ins IPv4-Netz haengen."
  }
  assert {
    condition     = openstack_networking_secgroup_rule_v2.rdp["IPv4"].remote_ip_prefix == "141.72.0.0/16"
    error_message = "RDP ueber IPv4 bleibt auf Campus und VPN beschraenkt."
  }
  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.ip == "10.200.0.42"])
    error_message = "Die Zugangsdaten muessen die feste IPv4 nennen, ohne Klammern."
  }
}

run "dual_haengt_ipv4_als_zweite_karte_an" {
  command = apply

  variables {
    ip_mode         = "dual"
    network_v4_uuid = "00000000-0000-0000-0000-0000000000v4"
  }

  assert {
    condition     = length(openstack_compute_interface_attach_v2.v4) == 3
    error_message = "dual braucht je VM eine Karte im IPv4-Netz."
  }
  assert {
    condition     = toset(keys(openstack_networking_secgroup_rule_v2.rdp)) == toset(["IPv4", "IPv6"])
    error_message = "dual braucht RDP-Regeln fuer beide Familien."
  }
  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.ip == "141.72.10.7"])
    error_message = "Bei dual nennen die Zugangsdaten die IPv4 der zweiten Karte."
  }
}

run "ipv4_ohne_netz_wird_abgelehnt" {
  command = plan

  variables {
    ip_mode = "ipv4"
  }

  expect_failures = [openstack_compute_instance_v2.user_vm]
}
