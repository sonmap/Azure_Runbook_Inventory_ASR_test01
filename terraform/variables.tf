variable "location_primary" {
  description = "Primary Azure region"
  type        = string
  default     = "koreacentral"
}

variable "location_dr" {
  description = "DR Azure region"
  type        = string
  default     = "japaneast"
}

variable "prefix" {
  description = "Resource name prefix. Must be globally unique when used in DNS labels."
  type        = string
  default     = "asrtest01"
}

variable "admin_username" {
  description = "Linux VM admin username"
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "SSH public key"
  type        = string
}

variable "vm_size" {
  description = "Primary AP VM size. Change when a SKU is unavailable in Korea Central."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "allowed_admin_cidr" {
  description = "CIDR allowed to access SSH/Tomcat for lab testing. Use your public IP /32."
  type        = string
  default     = "0.0.0.0/0"
}

variable "dr_endpoint_fqdn" {
  description = "Japan DR endpoint FQDN or public DNS after ASR failover. Initial dummy value is disabled in Traffic Manager."
  type        = string
  default     = "dr-placeholder.example.com"
}

variable "mysql_admin_user" {
  description = "MySQL admin user"
  type        = string
  default     = "mysqladmin"
}

variable "mysql_admin_password" {
  description = "MySQL admin password. Use Key Vault in production."
  type        = string
  sensitive   = true
}
