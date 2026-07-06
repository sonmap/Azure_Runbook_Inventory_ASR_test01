# 실행 명령어: Traffic Manager + Run Command 방식

이 문서는 Application Gateway 없이 Traffic Manager를 사용하고, 사용자 PC에서 VM Private IP로 `scp`하지 않고 `az vm run-command`로 스크립트를 배포하는 절차입니다.

## 1. Git clone

```bash
cd ~
git clone https://github.com/sonmap/Azure_Runbook_Inventory_ASR_test01.git
cd Azure_Runbook_Inventory_ASR_test01
```

## 2. Terraform 변수 파일 준비

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
```

필수 수정:

```hcl
admin_ssh_public_key = "본인 SSH 공개키"
mysql_admin_password = "IQwaszx1234!"
allowed_admin_cidr   = "본인공인IP/32"
```

본인 공인 IP 확인:

```bash
curl -s ifconfig.me
```

예시:

```hcl
allowed_admin_cidr = "203.0.113.10/32"
```

## 3. Azure 로그인

```bash
az login
az account show
```

구독 선택이 필요하면:

```bash
az account set --subscription "<SUBSCRIPTION_ID>"
```

## 4. Terraform 실행

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

출력 확인:

```bash
terraform output
```

## 5. VM 상태 확인

```bash
az vm get-instance-view \
  -g rg-prd-app-krc \
  -n vm-prd-ap-tomcat01 \
  --query "instanceView.statuses[].displayStatus" \
  -o table
```

IP 확인:

```bash
az vm list-ip-addresses \
  -g rg-prd-app-krc \
  -n vm-prd-ap-tomcat01 \
  -o table
```

## 6. Shell 파일 배포: scp 대신 Run Command

```bash
az vm run-command invoke \
  -g rg-prd-app-krc \
  -n vm-prd-ap-tomcat01 \
  --command-id RunShellScript \
  --scripts "
sudo mkdir -p /opt/runbook
sudo curl -L -o /opt/runbook/start_tomcat.sh https://raw.githubusercontent.com/sonmap/Azure_Runbook_Inventory_ASR_test01/main/scripts/linux/start_tomcat.sh
sudo curl -L -o /opt/runbook/check_tomcat.sh https://raw.githubusercontent.com/sonmap/Azure_Runbook_Inventory_ASR_test01/main/scripts/linux/check_tomcat.sh
sudo chmod +x /opt/runbook/*.sh
ls -l /opt/runbook
"
```

## 7. JSP 테스트 화면 배포

```bash
az vm run-command invoke \
  -g rg-prd-app-krc \
  -n vm-prd-ap-tomcat01 \
  --command-id RunShellScript \
  --scripts "
sudo mkdir -p /var/lib/tomcat10/webapps/tomcat-test
sudo curl -L -o /var/lib/tomcat10/webapps/tomcat-test/index.jsp https://raw.githubusercontent.com/sonmap/Azure_Runbook_Inventory_ASR_test01/main/app/tomcat-test/index.jsp
sudo systemctl restart tomcat10 || sudo systemctl restart tomcat
sudo systemctl status tomcat10 --no-pager || sudo systemctl status tomcat --no-pager
curl -I http://127.0.0.1:8080/tomcat-test/index.jsp
"
```

## 8. Public IP 또는 Traffic Manager로 테스트

Public IP:

```bash
PUBLIC_IP=$(terraform output -raw primary_vm_public_ip)
curl -I http://${PUBLIC_IP}:8080/tomcat-test/index.jsp
```

Traffic Manager:

```bash
TM_FQDN=$(terraform output -raw traffic_manager_fqdn)
curl -I http://${TM_FQDN}:8080/tomcat-test/index.jsp
```

브라우저:

```text
http://<traffic_manager_fqdn>:8080/tomcat-test/index.jsp
```

## 9. Runbook 등록

```bash
cd ~/Azure_Runbook_Inventory_ASR_test01

az automation runbook create \
  --automation-account-name aa-asr-runbook-krc \
  --resource-group rg-asr-mgmt-krc \
  --name Invoke-ASR-Inventory-DR \
  --type PowerShell

az automation runbook replace-content \
  --automation-account-name aa-asr-runbook-krc \
  --resource-group rg-asr-mgmt-krc \
  --name Invoke-ASR-Inventory-DR \
  --content @runbooks/Invoke-ASR-Inventory-DR.ps1

az automation runbook publish \
  --automation-account-name aa-asr-runbook-krc \
  --resource-group rg-asr-mgmt-krc \
  --name Invoke-ASR-Inventory-DR
```

## 10. Runbook 수동 테스트

DR Inventory에는 placeholder가 있으므로 실제 DR Public IP/DNS와 Traffic Manager FQDN으로 수정 후 실행해야 합니다.

```bash
az automation runbook start \
  --automation-account-name aa-asr-runbook-krc \
  --resource-group rg-asr-mgmt-krc \
  --name Invoke-ASR-Inventory-DR \
  --parameters \
    InventoryUrl="https://raw.githubusercontent.com/sonmap/Azure_Runbook_Inventory_ASR_test01/main/inventory/dr-inventory.csv" \
    Environment="DR"
```

## 11. 삭제

```bash
cd ~/Azure_Runbook_Inventory_ASR_test01/terraform
terraform destroy
```

Terraform 외부에서 만든 자원이 있으면 리소스 그룹 삭제:

```bash
az group delete -n rg-prd-app-krc --yes --no-wait
az group delete -n rg-dr-app-jpe --yes --no-wait
az group delete -n rg-asr-mgmt-krc --yes --no-wait
```
