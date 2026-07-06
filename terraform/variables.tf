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
  description = "Resource name prefix"
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
