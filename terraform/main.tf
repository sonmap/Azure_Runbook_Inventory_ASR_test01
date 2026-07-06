terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  rg_primary = "rg-prd-app-krc"
  rg_dr      = "rg-dr-app-jpe"
  rg_mgmt    = "rg-asr-mgmt-krc"
}

resource "azurerm_resource_group" "primary" {
  name     = local.rg_primary
  location = var.location_primary
}

resource "azurerm_resource_group" "dr" {
  name     = local.rg_dr
  location = var.location_dr
}

resource "azurerm_resource_group" "mgmt" {
  name     = local.rg_mgmt
  location = var.location_primary
}

# Primary VNet
resource "azurerm_virtual_network" "primary" {
  name                = "vnet-prd-app-krc"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  address_space       = ["10.10.0.0/16"]
}

resource "azurerm_subnet" "primary_app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.primary.name
  virtual_network_name = azurerm_virtual_network.primary.name
  address_prefixes     = ["10.10.10.0/24"]
}

# DR VNet skeleton. AP VM은 ASR Failover 후 Japan East 쪽에 생성되는 것을 가정합니다.
resource "azurerm_virtual_network" "dr" {
  name                = "vnet-dr-app-jpe"
  location            = azurerm_resource_group.dr.location
  resource_group_name = azurerm_resource_group.dr.name
  address_space       = ["10.20.0.0/16"]
}

resource "azurerm_subnet" "dr_app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.dr.name
  virtual_network_name = azurerm_virtual_network.dr.name
  address_prefixes     = ["10.20.10.0/24"]
}

# Public IP for Primary AP VM. Traffic Manager Azure endpoint requires a public endpoint.
resource "azurerm_public_ip" "ap_pip" {
  name                = "pip-prd-ap-tomcat01"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.prefix}-prd-ap-krc"
}

# NSG for SSH and Tomcat test. 운영에서는 source_address_prefix를 본인 공인IP/32로 제한하세요.
resource "azurerm_network_security_group" "app" {
  name                = "nsg-prd-app-krc"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_admin_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Tomcat-8080"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = var.allowed_admin_cidr
    destination_address_prefix = "*"
  }
}

# Primary AP VM NIC
resource "azurerm_network_interface" "ap" {
  name                = "nic-prd-ap-tomcat01"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.primary_app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.10.10"
    public_ip_address_id          = azurerm_public_ip.ap_pip.id
  }
}

resource "azurerm_network_interface_security_group_association" "ap" {
  network_interface_id      = azurerm_network_interface.ap.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_linux_virtual_machine" "ap" {
  name                = "vm-prd-ap-tomcat01"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  size                = var.vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.ap.id
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
#!/bin/bash
apt-get update -y
apt-get install -y openjdk-17-jdk tomcat10 curl
systemctl enable tomcat10
systemctl start tomcat10
EOF
  )
}

# Azure Database for MySQL Flexible Server - Primary
resource "azurerm_mysql_flexible_server" "mysql" {
  name                   = "mysql-${var.prefix}-krc"
  resource_group_name    = azurerm_resource_group.primary.name
  location               = azurerm_resource_group.primary.location
  administrator_login    = var.mysql_admin_user
  administrator_password = var.mysql_admin_password
  sku_name               = "B_Standard_B1ms"
  version                = "8.0.21"
  backup_retention_days  = 7
  zone                   = "1"

  # 운영에서는 DR 정책에 맞춰 geo-redundant backup 또는 replica/restore 전략 검토 필요
  geo_redundant_backup_enabled = true
}

resource "azurerm_mysql_flexible_database" "appdb" {
  name                = "appdb"
  resource_group_name = azurerm_resource_group.primary.name
  server_name         = azurerm_mysql_flexible_server.mysql.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# Traffic Manager: Application Gateway 정책 차단 환경에서 사용할 DNS 기반 DR Failover 예제
resource "azurerm_traffic_manager_profile" "tm" {
  name                   = "tm-${var.prefix}-tomcat-dr"
  resource_group_name    = azurerm_resource_group.primary.name
  traffic_routing_method = "Priority"

  dns_config {
    relative_name = "tm-${var.prefix}-tomcat-dr"
    ttl           = 30
  }

  monitor_config {
    protocol = "HTTP"
    port     = 8080
    path     = "/tomcat-test/index.jsp"
  }
}

resource "azurerm_traffic_manager_azure_endpoint" "primary" {
  name               = "primary-korea-tomcat"
  profile_id         = azurerm_traffic_manager_profile.tm.id
  target_resource_id = azurerm_public_ip.ap_pip.id
  priority           = 1
}

# DR endpoint는 ASR Test Failover 후 생성된 Japan East Public IP 또는 DNS로 교체합니다.
# 초기에는 비활성화 상태로 생성합니다.
resource "azurerm_traffic_manager_external_endpoint" "dr" {
  name       = "dr-japan-tomcat"
  profile_id = azurerm_traffic_manager_profile.tm.id
  target     = var.dr_endpoint_fqdn
  priority   = 2
  enabled    = false
}

resource "azurerm_automation_account" "aa" {
  name                = "aa-asr-runbook-krc"
  location            = azurerm_resource_group.mgmt.location
  resource_group_name = azurerm_resource_group.mgmt.name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_recovery_services_vault" "asr" {
  name                = "rsv-asr-krc-jpe-001"
  location            = azurerm_resource_group.mgmt.location
  resource_group_name = azurerm_resource_group.mgmt.name
  sku                 = "Standard"
}

output "primary_vm_public_ip" {
  value = azurerm_public_ip.ap_pip.ip_address
}

output "primary_vm_fqdn" {
  value = azurerm_public_ip.ap_pip.fqdn
}

output "traffic_manager_fqdn" {
  value = azurerm_traffic_manager_profile.tm.fqdn
}
