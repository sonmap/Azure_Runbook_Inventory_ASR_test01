#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${1:-tomcat-test}"
URL="http://127.0.0.1:8080/${APP_NAME}/index.jsp"

echo "Check Tomcat URL: ${URL}"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${URL}" || true)

echo "HTTP_CODE=${HTTP_CODE}"

if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" ]]; then
  exit 0
fi

exit 1
