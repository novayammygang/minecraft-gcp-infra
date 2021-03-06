# We require a project to be provided upfront
# Create a project at https://cloud.google.com/
# Make note of the project ID
# We need a storage bucket created upfront too to store the terraform state
terraform {
  backend "gcs" {
    prefix = "minecraft/state"
    bucket = "cyse-minecraft-tf"
  }
}

# You need to fill these locals out with the project, region and zone
# Then to boot it up, run:-
#   gcloud auth application-default login
#   terraform init
#   terraform apply
locals {
  # The Google Cloud Project ID that will host and pay for your Minecraft server
  project = "aqueous-ray-347417"
  region  = "us-east4"
  zone    = "us-east4-c"

  enable_switch_access_group = 0
  minecraft_switch_access_group = ""
  url_to_docker_file = "https://raw.githubusercontent.com/novayammygang/minecraft-gcp-infra/main/Dockerfiles/RAD/Dockerfile"
}


provider "google" {
  project = local.project
  region  = local.region
}

# Create service account to run service with no permissions
resource "google_service_account" "minecraft" {
  account_id   = "minecraft"
  display_name = "minecraft"
}

# Permenant Minecraft disk, stays around when VM is off
resource "google_compute_disk" "minecraft" {
  name  = "minecraft"
  type  = "pd-standard"
  size = 35
  zone  = local.zone
  image = "cos-cloud/cos-stable"
}

# Permenant IP address, stays around when VM is off
resource "google_compute_address" "minecraft" {
  name   = "minecraft-ip"
  region = local.region
}

# VM to run Minecraft, we use preemptable which will shutdown within 24 hours
resource "google_compute_instance" "minecraft" {
  name         = "minecraft"
  machine_type = "e2-highcpu-8"
  zone         = local.zone
  tags         = ["minecraft"]

  # Run itzg/minecraft-server docker image on startup
  # The instructions of https://hub.docker.com/r/itzg/minecraft-server/ are applicable
  # For instance, Ssh into the instance and you can run
  #  docker logs mc
  #  docker exec -i mc rcon-cli
  # Once in rcon-cli you can "op <player_id>" to make someone an operator (admin)
  # Use 'sudo journalctl -u google-startup-scripts.service' to retrieve the startup script output
  metadata_startup_script = "sudo su;cd /home/;curl ${local.url_to_docker_file} -o Dockerfile;docker build -t kumarak2/rad-mc-server .;docker run -tid -p 25565:25565 -v /var/minecraft:/data --name mc kumarak2/rad-mc-server:latest || docker start -ia mc"
  allow_stopping_for_update = true
  metadata = {
    enable-oslogin = "TRUE"
  }
      
  boot_disk {
    auto_delete = false # Keep disk after shutdown (game data)
    source      = google_compute_disk.minecraft.self_link
  }

  network_interface {
    network = google_compute_network.minecraft.name
    access_config {
      nat_ip = google_compute_address.minecraft.address
    }
  }

  service_account {
    email  = google_service_account.minecraft.email
    scopes = ["userinfo-email"]
  }

  scheduling {
    preemptible       = false # Closes within 24 hours (sometimes sooner)
    automatic_restart = false
  }
}

# Create a private network so the minecraft instance cannot access
# any other resources.
resource "google_compute_network" "minecraft" {
  name = "minecraft"
}

# Open the firewall for Minecraft traffic
resource "google_compute_firewall" "minecraft" {
  name    = "minecraft"
  network = google_compute_network.minecraft.name
  # Minecraft client port
  allow {
    protocol = "tcp"
    ports    = ["25565"]
  }
  # ICMP (ping)
  allow {
    protocol = "icmp"
  }
  # SSH (for RCON-CLI access)
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["minecraft"]
}

resource "google_project_iam_custom_role" "minecraftSwitcher" {
  role_id     = "MinecraftSwitcher"
  title       = "Minecraft Switcher"
  description = "Can turn a VM on and off"
  permissions = ["compute.instances.start", "compute.instances.stop", "compute.instances.get"]
}

resource "google_project_iam_custom_role" "instanceLister" {
  role_id     = "InstanceLister"
  title       = "Instance Lister"
  description = "Can list VMs in project"
  permissions = ["compute.instances.list"]
}

resource "google_compute_instance_iam_member" "switcher" {
  count = local.enable_switch_access_group
  project = local.project
  zone = local.zone
  instance_name = google_compute_instance.minecraft.name
  role = google_project_iam_custom_role.minecraftSwitcher.id
  member = "group:${local.minecraft_switch_access_group}"
}

resource "google_project_iam_member" "projectBrowsers" {
  count = local.enable_switch_access_group
  project = local.project
  role    = "roles/browser"
  member  = "group:${local.minecraft_switch_access_group}"
}

resource "google_project_iam_member" "computeViewer" {
  count = local.enable_switch_access_group
  project = local.project
  role    = google_project_iam_custom_role.instanceLister.id
  member  = "group:${local.minecraft_switch_access_group}"
}
