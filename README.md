# Azure Runbook + Inventory + ASR + Traffic Manager DR Test

예제 목적: **서울 리전(Korea Central)의 AP 서버 1식(Tomcat) + Azure Database for MySQL Flexible Server** 구성을 **일본 리전(Japan East)** 으로 DR 전환하는 테스트 구조입니다.

Application Gateway는 실습 구독의 `Deny Expensive Network Resources` 정책으로 차단될 수 있으므로, 이 예제는 상단 진입점을 **Azure Traffic Manager**로 변경했습니다.

## 1. 구성 개요

```text
User PC
  |
  v
Traffic Manager DNS
  |
  +-- Priority 1: Korea Central Tomcat Public IP
  |
  +-- Priority 2: Japan East Tomcat Public IP or DNS after ASR failover

Tomcat AP VM
  |
  v
Azure Database for MySQL Flexible Server
```

Traffic Manager는 L7 프록시가 아니라 **DNS 기반 글로벌 라우팅 서비스**입니다. 즉, Application Gateway처럼 HTTP Path Routing이나 Backend Pool L7 라우팅을 하지 않고, 장애 시 DNS 응답을 Primary에서 DR endpoint로 전환합니다.

## 2. DR 전환 흐름

```text
Korea Central 장애
  |
  v
ASR Recovery Plan 실행
  |
  +-- AP VM을 Japan East로 Failover
  |
  +-- Azure Automation Runbook 실행
  |     +-- inventory/dr-inventory.csv 읽기
  |     +-- VM 기동 확인
  |     +-- scripts/linux/start_tomcat.sh 실행
  |     +-- Tomcat URL Health Check
  |
  +-- Traffic Manager DR endpoint 활성화
  |
  +-- 사용자 Tomcat 화면 테스트
```

## 3. 리전 설계

| 구분 | Primary | DR |
|---|---|---|
| Region | Korea Central | Japan East |
| AP | VM + Tomcat + Public IP | ASR Failover VM + Public IP/DNS |
| DB | Azure Database for MySQL Flexible Server | Geo-restore 또는 별도 DR MySQL |
| Global Routing | Traffic Manager Priority 1 | Traffic Manager Priority 2 |
| Automation | Azure Automation Runbook | 동일 또는 DR Automation Account |
| Inventory | Storage/Git/CSV | 동일 CSV에 Environment=DR 사용 |

## 4. 폴더 구조

```text
.
├── inventory/
│   └── dr-inventory.csv
├── runbooks/
│   └── Invoke-ASR-Inventory-DR.ps1
├── scripts/
│   ├── asr/
│   │   └── create_asr_lab_example.sh
│   └── linux/
│       ├── start_tomcat.sh
│       └── check_tomcat.sh
├── app/
│   └── tomcat-test/index.jsp
├── sql/
│   └── init.sql
└── terraform/
    ├── main.tf
    ├── variables.tf
    └── terraform.tfvars.example
```

## 5. 사용자 PC에서 VM으로 shell 복사 방식 변경

Private IP만 있는 VM에는 사용자 PC에서 직접 `scp azureuser@10.x.x.x`가 불가능합니다.

기존 방식:

```bash
scp scripts/linux/start_tomcat.sh azureuser@10.10.10.10:/tmp/
```

변경 방식:

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
"
```

JSP 배포도 동일하게 Run Command를 사용합니다.

```bash
az vm run-command invoke \
  -g rg-prd-app-krc \
  -n vm-prd-ap-tomcat01 \
  --command-id RunShellScript \
  --scripts "
sudo mkdir -p /var/lib/tomcat10/webapps/tomcat-test
sudo curl -L -o /var/lib/tomcat10/webapps/tomcat-test/index.jsp https://raw.githubusercontent.com/sonmap/Azure_Runbook_Inventory_ASR_test01/main/app/tomcat-test/index.jsp
sudo systemctl restart tomcat10
curl -I http://127.0.0.1:8080/tomcat-test/index.jsp
"
```

## 6. Terraform 실행

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
terraform init
terraform plan
terraform apply
```

`terraform output`으로 접속 정보를 확인합니다.

```bash
terraform output
```

예상 출력:

```text
primary_vm_public_ip = "x.x.x.x"
primary_vm_fqdn      = "asrtest01-prd-ap-krc.koreacentral.cloudapp.azure.com"
traffic_manager_fqdn = "tm-asrtest01-tomcat-dr.trafficmanager.net"
```

## 7. Traffic Manager 테스트

```bash
curl -I http://$(terraform output -raw traffic_manager_fqdn):8080/tomcat-test/index.jsp
```

또는 브라우저에서:

```text
http://<traffic_manager_fqdn>:8080/tomcat-test/index.jsp
```

## 8. 핵심 원칙

| 영역 | 역할 |
|---|---|
| ASR Recovery Plan | VM Failover 순서 제어 |
| Inventory CSV | 어떤 서버를 어떤 스크립트로 기동/점검할지 정의 |
| Azure Runbook | Inventory를 읽고 VM 내부 스크립트 실행 |
| Linux Script | Tomcat 실제 기동 및 Health Check |
| Traffic Manager | Primary/DR DNS 기반 전환 |
| MySQL Flexible Server | 업무 데이터 저장 |

## 9. 주의 사항

- 이 저장소는 실습용 예제입니다. 운영 적용 전 NSG, Private Endpoint, Key Vault, Managed Identity RBAC, 인증서, DNS 전환, MySQL DR 정책을 반드시 보강해야 합니다.
- MySQL Flexible Server는 VM처럼 ASR로 복제하지 않습니다. DB는 geo-redundant backup 기반 geo-restore, read replica, 백업/복구 정책 등 별도 DR 전략이 필요합니다.
- Runbook에서 VM 내부 명령을 실행하려면 VM Agent가 정상이어야 하며, Automation Account Managed Identity에 VM 권한이 필요합니다.
- Traffic Manager는 DNS 기반이므로 TTL, 클라이언트 DNS 캐시, 장애 감지 주기에 따라 전환 시간이 달라질 수 있습니다.
