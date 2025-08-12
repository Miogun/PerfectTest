# run.sh
#!/usr/bin/env sh
set -eu

# 사용: sh run.sh [DIR]
DIR="${1:-.}"
cd "$DIR"

log() { printf "%s\n" "$*"; }

# 0) Azure CLI
if ! command -v az >/dev/null 2>&1; then
  log "[*] az not found → install"
  if [ -x "./install_azure_cli.sh" ]; then
    bash ./install_azure_cli.sh
  else
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo -E"; else SUDO=""; fi
    curl -sL https://aka.ms/InstallAzureCLIDeb | $SUDO bash
  fi
fi

# 1) 로그인
if ! az account show >/dev/null 2>&1; then
  log "[*] az login 시작 (디바이스 코드 인증)"
  az login
fi

# 2) tfvars 생성 (구독/테넌트 자동 주입)
if [ -x "./setup.sh" ]; then
  bash ./setup.sh
else
  log "[X] setup.sh 없음"; exit 1
fi

# 3) Terraform
if ! command -v terraform >/dev/null 2>&1; then
  log "[*] terraform not found → install"
  if [ -x "./install_terraform.sh" ]; then
    bash ./install_terraform.sh
  else
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo -E"; else SUDO=""; fi
    $SUDO apt-get update -y
    $SUDO apt-get install -y --no-install-recommends gnupg software-properties-common wget ca-certificates lsb-release
    wget -qO- https://apt.releases.hashicorp.com/gpg | $SUDO gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    ARCH="$(dpkg --print-architecture)"
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    CODENAME="${UBUNTU_CODENAME:-$(lsb_release -cs)}"
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" | $SUDO tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    $SUDO apt-get update -y
    $SUDO apt-get install -y terraform
  fi
fi

# 4) 배포
terraform init
if [ "${AUTO_APPROVE:-true}" = "true" ]; then
  terraform apply -auto-approve
else
  terraform apply
fi

# 5) 출력
log "[OK] Terraform outputs:"
terraform output
