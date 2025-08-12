#!/usr/bin/env bash
set -euo pipefail

mkdir -p .

# ---------- main.tf ----------
cat > main.tf <<'EOF'
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.prefix}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_network_security_group" "nsg" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "ssh_master" {
  name                        = "allow-ssh-master"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["22"]
  source_address_prefixes     = [var.allowed_ssh_cidr]
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_network_security_rule" "intra_vnet" {
  name                        = "allow-intra-vnet"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.vnet_cidr
  destination_address_prefix  = var.vnet_cidr
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_network_security_rule" "nodeports" {
  count                       = var.open_nodeports ? 1 : 0
  name                        = "allow-nodeports"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["30000-32767"]
  source_address_prefixes     = [var.allowed_ssh_cidr]
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_public_ip" "master" {
  name                = "${var.prefix}-master-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "master" {
  name                = "${var.prefix}-master-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.master.id
  }

  tags = var.tags
}

resource "azurerm_network_interface_security_group_association" "master" {
  network_interface_id      = azurerm_network_interface.master.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_network_interface" "workers" {
  count               = var.worker_count
  name                = "${var.prefix}-worker-${count.index + 1}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }

  tags = var.tags
}

resource "azurerm_network_interface_security_group_association" "workers" {
  count                     = var.worker_count
  network_interface_id      = azurerm_network_interface.workers[count.index].id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

locals {
  ubuntu_offer     = "0001-com-ubuntu-server-jammy"
  ubuntu_publisher = "Canonical"
  ubuntu_sku       = "22_04-lts-gen2"
  ubuntu_version   = "latest"
}

resource "azurerm_linux_virtual_machine" "master" {
  name                = "${var.prefix}-master"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.master.id
  ]
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = local.ubuntu_publisher
    offer     = local.ubuntu_offer
    sku       = local.ubuntu_sku
    version   = local.ubuntu_version
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_gb
  }

  computer_name = "master"
  custom_data   = base64encode(file("cloud-init-master.yaml"))
  tags          = var.tags
}

resource "azurerm_linux_virtual_machine" "workers" {
  count               = var.worker_count
  name                = "${var.prefix}-worker-${count.index + 1}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.workers[count.index].id
  ]
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = local.ubuntu_publisher
    offer     = local.ubuntu_offer
    sku       = local.ubuntu_sku
    version   = local.ubuntu_version
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_gb
  }

  computer_name = "worker-${count.index + 1}"
  custom_data   = base64encode(file("cloud-init-worker.yaml"))
  tags          = var.tags
}
EOF

# ---------- variables.tf ----------
cat > variables.tf <<'EOF'
variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "k8s"
}

variable "resource_group_name" {
  description = "Azure Resource Group name"
  type        = string
  default     = "k8s-lab-rg"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "koreacentral"
}

variable "vnet_cidr" {
  description = "VNet CIDR"
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR"
  type        = string
  default     = "10.10.1.0/24"
}

variable "vm_size" {
  description = "VM size"
  type        = string
  default     = "Standard_B2s"
}

variable "os_disk_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 64
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "admin_username" {
  description = "Admin username for VMs"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "Your SSH public key"
  type        = string
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to MASTER public IP (e.g., 1.2.3.4/32)"
  type        = string
}

variable "open_nodeports" {
  description = "Temporarily open NodePort range 30000-32767 to your CIDR"
  type        = bool
  default     = false
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default = {
    env   = "lab"
    stack = "k8s"
  }
}
EOF


# ---------- outputs.tf ----------
cat > outputs.tf <<'EOF'
output "master_public_ip" {
  value       = azurerm_public_ip.master.ip_address
  description = "Public IP of the master node"
}
output "master_private_ip" {
  value       = azurerm_network_interface.master.ip_configuration[0].private_ip_address
  description = "Private IP of the master node"
}
output "worker_private_ips" {
  value       = [for nic in azurerm_network_interface.workers : nic.ip_configuration[0].private_ip_address]
  description = "Private IPs of worker nodes"
}
EOF

# ---------- cloud-init-master.yaml ----------
cat > cloud-init-master.yaml <<'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - jq
  - htop
write_files:
  - path: /etc/modules-load.d/k8s.conf
    permissions: "0644"
    content: |
      br_netfilter
  - path: /etc/sysctl.d/k8s.conf
    permissions: "0644"
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.ipv4.ip_forward               = 1
      net.bridge.bridge-nf-call-ip6tables = 1
runcmd:
  - swapoff -a
  - sed -i.bak '/ swap / s/^/#/' /etc/fstab
  - sysctl --system
  - hostnamectl set-hostname master
  - echo "Cloud-init base completed on master" > /root/READY
EOF

# ---------- cloud-init-worker.yaml ----------
cat > cloud-init-worker.yaml <<'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - jq
  - htop
write_files:
  - path: /etc/modules-load.d/k8s.conf
    permissions: "0644"
    content: |
      br_netfilter
  - path: /etc/sysctl.d/k8s.conf
    permissions: "0644"
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.ipv4.ip_forward               = 1
      net.bridge.bridge-nf-call-ip6tables = 1
runcmd:
  - swapoff -a
  - sed -i.bak '/ swap / s/^/#/' /etc/fstab
  - sysctl --system
  - hostnamectl set-hostname worker
  - echo "Cloud-init base completed on worker" > /root/READY
EOF

# ---------- setup.sh ----------
cat > setup.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "[1/5] Ensure ~/.ssh exists"
mkdir -p ~/.ssh && chmod 700 ~/.ssh

if [[ ! -f ~/.ssh/id_ed25519 ]]; then
  echo "[2/5] Generate SSH key (ed25519, no passphrase)"
  ssh-keygen -t ed25519 -C "codespace@azure-lab" -f ~/.ssh/id_ed25519 -N ""
else
  echo "[2/5] SSH key already exists, skipping generation"
fi

PUB_KEY=$(cat ~/.ssh/id_ed25519.pub)

echo "[3/5] Detect your public IP (for tight SSH allowlist)"
MYIP=""
if command -v curl >/dev/null 2>&1; then
  set +e
  MYIP=$(curl -fsS https://ifconfig.io || curl -fsS https://api.ipify.org || true)
  set -e
fi
if [[ -n "${MYIP}" ]]; then
  ALLOW="${MYIP}/32"
  echo "  -> Detected ${ALLOW}"
else
  ALLOW="0.0.0.0/0"
  echo "  -> Could not detect IP. Using ${ALLOW}. Change later in terraform.tfvars."
fi

echo "[4/5] Getting Azure Subscription and Tenant IDs"
if ! command -v az >/dev/null 2>&1; then
  echo "[X] Azure CLI not found. Run: bash install_azure_cli.sh && az login"
  exit 1
fi
SUB_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
TENANT_ID="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
if [[ -z "$SUB_ID" || -z "$TENANT_ID" ]]; then
  echo "[!] Could not detect subscription/tenant. Run az login and retry."
  exit 1
fi

echo "[5/5] Writing terraform.tfvars"
cat > terraform.tfvars <<EOT
prefix               = "k8s"
resource_group_name  = "k8s-lab-rg"
location             = "koreacentral"
admin_username       = "azureuser"
ssh_public_key       = "${PUB_KEY}"
allowed_ssh_cidr     = "${ALLOW}"
vm_size              = "Standard_B2s"
os_disk_gb           = 64
worker_count         = 2
open_nodeports       = false
subscription_id      = "${SUB_ID}"
tenant_id            = "${TENANT_ID}"
EOT

echo "[DONE] terraform.tfvars written."
EOF

# ---------- install_terraform.sh ----------
cat > install_terraform.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if command -v terraform >/dev/null 2>&1; then
  echo "[OK] Terraform already installed: $(terraform -version | head -n1)"; exit 0; fi
SUDO=""; if [[ $EUID -ne 0 ]]; then if command -v sudo >/dev/null 2>&1; then SUDO="sudo -E"; else echo "[X] Need sudo"; exit 1; fi; fi
$SUDO apt-get update -y
$SUDO apt-get install -y --no-install-recommends gnupg software-properties-common wget ca-certificates lsb-release
wget -qO- https://apt.releases.hashicorp.com/gpg | $SUDO gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
ARCH="$($SUDO dpkg --print-architecture || dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo ${UBUNTU_CODENAME:-})"; if [[ -z "$CODENAME" ]]; then CODENAME="$(lsb_release -cs)"; fi
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" | $SUDO tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
$SUDO apt-get update -y
$SUDO apt-get install -y terraform
echo "[DONE] $(terraform -version | head -n1)"
EOF

# ---------- install_azure_cli.sh ----------
cat > install_azure_cli.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if command -v az >/dev/null 2>&1; then
  echo "[OK] Azure CLI already installed: $(az version | head -n1)"; exit 0; fi
SUDO=""; if [[ $EUID -ne 0 ]]; then if command -v sudo >/dev/null 2>&1; then SUDO="sudo -E"; else echo "[X] Need sudo"; exit 1; fi; fi
echo "[*] Installing Azure CLI"
curl -sL https://aka.ms/InstallAzureCLIDeb | $SUDO bash
echo "[DONE] az ready"
EOF

# ---------- README.md ----------
cat > README.md <<'EOF'
# Azure K8s (3 VMs) - Codespaces quickstart (subscription fixed)

```bashcat > variables.tf <<'EOF'
variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "k8s"
}

variable "resource_group_name" {
  description = "Azure Resource Group name"
  type        = string
  default     = "k8s-lab-rg"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "koreacentral"
}

variable "vnet_cidr" {
  description = "VNet CIDR"
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR"
  type        = string
  default     = "10.10.1.0/24"
}

variable "vm_size" {
  description = "VM size"
  type        = string
  default     = "Standard_B2s"
}

variable "os_disk_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 64
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "admin_username" {
  description = "Admin username for VMs"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "Your SSH public key"
  type        = string
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to MASTER public IP (e.g., 1.2.3.4/32)"
  type        = string
}

variable "open_nodeports" {
  description = "Temporarily open NodePort range 30000-32767 to your CIDR"
  type        = bool
  default     = false
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default = {
    env   = "lab"
    stack = "k8s"
  }
}

bash install_azure_cli.sh
az login   # 구독 선택
bash setup.sh
bash install_terraform.sh  # (필요시)
terraform init
terraform apply -auto-approve

EOF

chmod +x setup.sh install_terraform.sh install_azure_cli.sh
echo "[OK] Files generated."

