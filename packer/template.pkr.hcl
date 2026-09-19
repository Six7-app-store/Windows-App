packer {
  required_plugins {
    openstack = {
      source  = "github.com/hashicorp/openstack"
      version = "~> 1"
    }
  }
}

locals {
  # Nur fuer die Dauer des Builds gueltig. Das Konto wird am Ende von
  # provision.ps1 wieder entfernt, das Passwort landet also nicht im
  # fertigen Image.
  #
  # Zusammensetzung statt reinem Zufall, weil Windows Komplexitaet
  # verlangt: Gross- und Kleinbuchstaben, Ziffer, Sonderzeichen. sha1()
  # allein liefert nur Hex-Kleinbuchstaben und Ziffern.
  build_password = "Bld!${substr(sha1(uuidv4()), 0, 14)}Aa1"
}

source "openstack" "image" {
  cloud             = "openstack"
  image_name        = var.image_name
  source_image_name = var.source_image_name
  flavor            = var.flavor
  networks          = var.networks
  security_groups   = var.security_groups

  # Windows spricht kein SSH. cloudbase-init richtet im Basis-Image einen
  # WinRM-Listener ueber HTTPS ein - das Konsolenlog einer Testinstanz
  # zeigt "Configuring WinRM listener for protocol: HTTPS".
  communicator   = "winrm"
  winrm_username = "packer"
  winrm_password = local.build_password
  winrm_use_ssl  = true
  # Das Zertifikat ist selbstsigniert und wird bei jedem Start neu erzeugt
  # ("Generating self signed certificate for WinRM HTTPS listener"). Es zu
  # pruefen ist nicht moeglich, und der Build laeuft im internen Netz.
  winrm_insecure = true
  winrm_port     = 5986
  # Der erste Windows-Start dauert deutlich laenger als bei Linux: das
  # 80-GB-Image wird aus dem Objektspeicher gelesen, danach laufen
  # Geraetekonfiguration und cloudbase-init. Der Standard von 30 Minuten
  # reicht nicht zuverlaessig.
  winrm_timeout = "45m"

  # Legt das Build-Konto an, bevor Packer sich verbindet. Das eingebaute
  # Administrator-Konto taugt dafuer nicht: Windows liefert es deaktiviert
  # aus, und cloudbase-init kann ihm keine Anmeldesitzung eroeffnen.
  user_data = templatefile("scripts/bootstrap.ps1.tpl", {
    build_password = local.build_password
  })

  image_min_disk   = 64
  image_visibility = "private"
}

build {
  sources = ["source.openstack.image"]

  provisioner "powershell" {
    script = "scripts/provision.ps1"
    # Das Provisioning-Skript laeuft lange (Chocolatey, Python, Node).
    elevated_user     = "packer"
    elevated_password = local.build_password
  }

  # Neustart nach der Softwareinstallation: Chocolatey-Pakete setzen PATH
  # und Dienste erst beim naechsten Start vollstaendig, und ein Teil der
  # Installer verlangt ihn ohnehin.
  provisioner "windows-restart" {
    restart_timeout = "20m"
  }

  # Muss der letzte Schritt sein: entfernt das Build-Konto und setzt
  # cloudbase-init zurueck, damit es auf den abgeleiteten VMs erneut laeuft.
  provisioner "powershell" {
    script            = "scripts/cleanup.ps1"
    elevated_user     = "packer"
    elevated_password = local.build_password
  }
}
