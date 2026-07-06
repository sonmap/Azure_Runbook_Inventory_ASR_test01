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

resource "azurerm_subnet" "primary_agw" {
  name                 = "snet-agw"
  resource_group_name  = azurerm_resource_group.primary.name
  virtual_network_name = azurerm_virtual_network.primary.name
  address_prefixes     = ["10.10.1.0/24"]
}

# DR VNet
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

resource "azurerm_subnet" "dr_agw" {
  name                 = "snet-agw"
  resource_group_name  = azurerm_resource_group.dr.name
  virtual_network_name = azurerm_virtual_network.dr.name
  address_prefixes     = ["10.20.1.0/24"]
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
  }
}

resource "azurerm_linux_virtual_machine" "ap" {
  name                = "vm-prd-ap-tomcat01"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  size                = "Standard_B2s"
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

# Application Gateway skeleton. 실제 운영에서는 HTTPS Listener, 인증서, WAF_v2, Probe 세부 설정 필요.
resource "azurerm_public_ip" "agw_pip" {
  name                = "pip-agw-prd-krc"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "agw" {
  name                = "agw-prd-app-krc"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "gw-ip-config"
    subnet_id = azurerm_subnet.primary_agw.id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "frontend-public"
    public_ip_address_id = azurerm_public_ip.agw_pip.id
  }

  backend_address_pool {
    name         = "prd-ap-pool"
    ip_addresses = ["10.10.10.10"]
  }

  backend_http_settings {
    name                  = "tomcat-http-8080"
    cookie_based_affinity = "Disabled"
    port                  = 8080
    protocol              = "Http"
    request_timeout       = 30
  }

  http_listener {
    name                           = "listener-http"
    frontend_ip_configuration_name = "frontend-public"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "rule-tomcat"
    rule_type                  = "Basic"
    http_listener_name         = "listener-http"
    backend_address_pool_name  = "prd-ap-pool"
    backend_http_settings_name = "tomcat-http-8080"
    priority                   = 100
  }
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
