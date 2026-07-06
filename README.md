# Azure Runbook + Inventory + ASR DR Test

예제 목적: **서울 리전(Korea Central)의 AP 서버 1식(Tomcat) + Azure Database for MySQL Flexible Server + 상단 ALB(Application Gateway)** 구성을 **일본 리전(Japan East)** 으로 DR 전환하는 테스트 구조입니다.

> Azure에는 AWS의 ALB와 같은 이름의 서비스는 없으므로, 이 예제에서는 상단 L7 ALB 역할을 **Azure Application Gateway**로 가정합니다.

## 1. 구성 개요

```text
User
  |
  v
Application Gateway / ALB 역할
  |
  v
AP VM: Tomcat
  |
  v
Azure Database for MySQL Flexible Server
```

DR 전환 시:

```text
Korea Central 장애
  |
  v
ASR Recovery Plan 실행
  |
  +-- AP VM을 Japan East에서 Failover
  |
  +-- Azure Automation Runbook 실행
  |     +-- inventory/dr-inventory.csv 읽기
  |     +-- VM 기동 확인
  |     +-- scripts/linux/start_tomcat.sh 실행
  |     +-- Tomcat URL Health Check
  |
  +-- Application Gateway Backend를 DR AP로 전환
  |
  +-- 사용자 Tomcat 화면 테스트
```

## 2. 리전 설계

| 구분 | Primary | DR |
|---|---|---|
| Region | Korea Central | Japan East |
| AP | VM + Tomcat | ASR Failover VM |
| DB | Azure Database for MySQL Flexible Server | Geo-restore 또는 별도 DR MySQL |
| ALB | Application Gateway | DR Application Gateway 또는 Backend 전환 |
| Automation | Azure Automation Runbook | 동일 또는 DR Automation Account |
| Inventory | Storage/Git/CSV | 동일 CSV에 Environment=DR 사용 |

## 3. 폴더 구조

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

## 4. 실행 흐름

1. Terraform 또는 Portal/CLI로 Primary 환경 생성
2. AP VM에 Tomcat 설치 및 `scripts/linux/*.sh` 배치
3. Azure Database for MySQL Flexible Server 생성
4. Tomcat 테스트 화면에서 MySQL 연결 확인
5. ASR로 AP VM을 Korea Central → Japan East 복제
6. ASR Recovery Plan 생성
7. Recovery Plan의 Post Action으로 `runbooks/Invoke-ASR-Inventory-DR.ps1` 연결
8. DR Test Failover 수행
9. Application Gateway Backend를 DR AP VM으로 전환
10. Tomcat 화면 접속 확인

## 5. 핵심 원칙

| 영역 | 역할 |
|---|---|
| ASR Recovery Plan | VM Failover 순서 제어 |
| Inventory CSV | 어떤 서버를 어떤 스크립트로 기동/점검할지 정의 |
| Azure Runbook | Inventory를 읽고 VM 내부 스크립트 실행 |
| Linux Script | Tomcat 실제 기동 및 Health Check |
| Application Gateway | 사용자 트래픽을 Primary/DR AP로 전달 |
| MySQL Flexible Server | 업무 데이터 저장 |

## 6. 주의 사항

- 이 저장소는 실습용 예제입니다. 운영 적용 전 NSG, Private Endpoint, Key Vault, Managed Identity RBAC, 인증서, DNS 전환, MySQL DR 정책을 반드시 보강해야 합니다.
- MySQL Flexible Server는 VM처럼 ASR로 복제하지 않습니다. DB는 geo-redundant backup 기반 geo-restore, read replica, 백업/복구 정책 등 별도 DR 전략이 필요합니다.
- Runbook에서 VM 내부 명령을 실행하려면 VM Agent가 정상이어야 하며, Automation Account Managed Identity에 VM 권한이 필요합니다.
