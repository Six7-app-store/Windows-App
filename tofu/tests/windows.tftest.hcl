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
