#!/usr/bin/env bash
set -euo pipefail

CUSTOM_PARAM="${1:-}"
LOG_FILE="/var/log/runbook-start-tomcat.log"

exec >> "${LOG_FILE}" 2>&1

echo "===== start_tomcat.sh $(date '+%F %T') ====="
echo "CUSTOM_PARAM=${CUSTOM_PARAM}"

# CustomParam 예: APP_NAME=tomcat-test;MYSQL_HOST=my-dr-mysql.mysql.database.azure.com;MYSQL_DB=appdb
get_param() {
  local key="$1"
  echo "${CUSTOM_PARAM}" | tr ';' '\n' | awk -F= -v k="$key" '$1==k {print $2}' | tail -1
}

APP_NAME="$(get_param APP_NAME)"
MYSQL_HOST="$(get_param MYSQL_HOST)"
MYSQL_DB="$(get_param MYSQL_DB)"

APP_NAME="${APP_NAME:-tomcat-test}"

# 1. OS 기본 상태 확인
echo "[1] OS check"
hostname
ip addr | grep -E 'inet ' || true

# 2. MySQL DNS/Port 확인. 비밀번호 인증 테스트는 Key Vault/환경변수 연계 권장.
if [[ -n "${MYSQL_HOST}" ]]; then
  echo "[2] MySQL endpoint check: ${MYSQL_HOST}:3306"
  timeout 5 bash -c "</dev/tcp/${MYSQL_HOST}/3306" \
    && echo "MySQL port open" \
    || echo "WARN: MySQL port check failed. Continue for Tomcat startup."
fi

# 3. Tomcat 기동
echo "[3] Start Tomcat"
if systemctl list-unit-files | grep -q '^tomcat'; then
  sudo systemctl daemon-reload || true
  sudo systemctl enable tomcat || true
  sudo systemctl restart tomcat
  sudo systemctl status tomcat --no-pager || true
elif [[ -x /opt/tomcat/bin/startup.sh ]]; then
  sudo -u tomcat /opt/tomcat/bin/shutdown.sh || true
  sleep 5
  sudo -u tomcat /opt/tomcat/bin/startup.sh
else
  echo "ERROR: tomcat service or /opt/tomcat/bin/startup.sh not found"
  exit 1
fi

# 4. 로컬 Health Check
echo "[4] Local health check"
for i in {1..20}; do
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/${APP_NAME}/index.jsp" || true)
  echo "try=$i http_code=${HTTP_CODE}"

  if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" ]]; then
    echo "Tomcat health check OK"
    exit 0
  fi

  sleep 15
done

echo "ERROR: Tomcat health check failed"
exit 1
