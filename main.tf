terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  zone = "ru-central1-a"
}

data "yandex_vpc_network" "default" {
  name = "default"
}
data "yandex_compute_image" "myimage" {
  family = "centos-stream-8"
}
data "local_file" "public_key" {
  filename = "${pathexpand("~/.ssh")}/${element(tolist(fileset(pathexpand("~/.ssh"), "id_*.pub")),0)}"
}
data "local_sensitive_file" "private_key" {
  filename = trimsuffix(data.local_file.public_key.filename, ".pub")
}

variable "cloud_user" {
  type = string
  description = "It was 'centos' before 2022-11, and it is 'cloud-user' since 2022-11"
}
variable "webserver" {
  type = string
}

resource "yandex_compute_instance" "vm-1" {
  name     = var.webserver
  hostname = var.webserver

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.myimage.id
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet-1.id
    nat       = true
  }

  metadata = {
    user-data = "${file("./cloud-config.yml")}"
    ssh-keys = "${var.cloud_user}:${data.local_file.public_key.content}"
  }

# A hack to give sshd time to start
  connection {
    type = "ssh"
    host = self.network_interface.0.nat_ip_address
    user = var.cloud_user
    private_key = data.local_sensitive_file.private_key.content
  } 
  provisioner "remote-exec" {
    inline = ["date"]
  }
}

resource "yandex_vpc_subnet" "subnet-1" {
  name           = "subnet1"
  zone           = "ru-central1-a"
  network_id     = data.yandex_vpc_network.default.network_id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

resource "local_file" "inventory" {
  filename = "./hosts"
  content  = <<-EOF
  [otus]
  ${yandex_compute_instance.vm-1.hostname} ansible_host=${yandex_compute_instance.vm-1.network_interface.0.nat_ip_address} ansible_ssh_common_args='-o StrictHostKeyChecking=no'
  EOF
  file_permission = "0644"
}

resource "local_file" "nginx_yml" {
  filename = "./nginx.yml"
  content = templatefile("nginx.yml.tmpl", {webserver=var.webserver, remote_user=var.cloud_user})
  file_permission = "0644"
}

resource "null_resource" "ansible" {
  depends_on = [local_file.inventory]

  provisioner "local-exec" {
    command = "ansible-playbook -i ${local_file.inventory.filename} ${local_file.nginx_yml.filename}"
  }
}

output "internal_ip_address_vm_1" {
  value = yandex_compute_instance.vm-1.network_interface.0.ip_address
}

output "external_ip_address_vm_1" {
  value = yandex_compute_instance.vm-1.network_interface.0.nat_ip_address
}
