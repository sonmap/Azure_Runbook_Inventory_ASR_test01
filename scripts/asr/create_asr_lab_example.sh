#!/usr/bin/env bash
set -euo pipefail

# ASR 실습용 CLI 예제입니다.
# 실제 enable replication은 Vault/Fabric/Protection Container Mapping 생성 후 VM 리소스 ID 기준으로 수행해야 하며,
# 운영에서는 Portal로 최초 1회 구성 후 Recovery Plan + Runbook 연결을 권장합니다.

PRIMARY_LOCATION="koreacentral"
DR_LOCATION="japaneast"
RG_PRIMARY="rg-prd-app-krc"
RG_DR="rg-dr-app-jpe"
RG_ASR="rg-asr-mgmt-krc"
VAULT_NAME="rsv-asr-krc-jpe-001"
RECOVERY_PLAN_NAME="rp-tomcat-mysql-dr"
AUTOMATION_ACCOUNT="aa-asr-runbook-krc"
RUNBOOK_NAME="Invoke-ASR-Inventory-DR"

az group create -n "$RG_ASR" -l "$PRIMARY_LOCATION"
az group create -n "$RG_DR" -l "$DR_LOCATION"

# 1. Recovery Services Vault 생성
az backup vault create \
  --resource-group "$RG_ASR" \
  --name "$VAULT_NAME" \
  --location "$PRIMARY_LOCATION"

# 2. Automation Account 생성
az automation account create \
  --resource-group "$RG_ASR" \
  --name "$AUTOMATION_ACCOUNT" \
  --location "$PRIMARY_LOCATION" \
  --sku Basic

# 3. Runbook 등록 예시
az automation runbook create \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_ASR" \
  --name "$RUNBOOK_NAME" \
  --type PowerShell

az automation runbook replace-content \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_ASR" \
  --name "$RUNBOOK_NAME" \
  --content @runbooks/Invoke-ASR-Inventory-DR.ps1

az automation runbook publish \
  --automation-account-name "$AUTOMATION_ACCOUNT" \
  --resource-group "$RG_ASR" \
  --name "$RUNBOOK_NAME"

cat <<EOF

Next manual/portal steps:
1. Recovery Services Vault에서 Site Recovery 활성화
2. Source: Korea Central, Target: Japan East 설정
3. AP VM(vm-prd-ap-tomcat01)을 ASR 보호 대상으로 등록
4. Recovery Plan 생성: ${RECOVERY_PLAN_NAME}
5. Recovery Plan Post Action에 Automation Runbook 연결
6. Runbook parameter 예시:
   InventoryUrl=https://raw.githubusercontent.com/sonmap/Azure_Runbook_Inventory_ASR_test01/main/inventory/dr-inventory.csv
   Environment=DR
7. Test Failover 실행
8. Tomcat URL 확인

EOF
