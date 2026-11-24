#!/bin/bash

# 1. Strict error handling (uncomment 'set -x' below if debug trace is needed)
set -eo pipefail
# set -x

JENKINS_PORT=$(kubectl get svc jenkins-service -n jenkins -o jsonpath="{.spec.ports[0].nodePort}")
JENKINS_URL="http://localhost:${JENKINS_PORT}"
USER="admin"
# Removed '-it' flag so it works safely inside Ansible/non-TTY shells
PASSWORD=$(kubectl exec --namespace jenkins svc/jenkins -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password)
TOKEN_NAME="ShellToken"
COOKIE_JAR=$(mktemp /tmp/jenkins_cookies.XXXXXX)
NEW_JOB_NAME="NGINX-DEMO"
JOB_XML_PATH="/home/kubeuser/nginx.xml"

# Ensure cookie file is always removed on script exit (even on error)
trap 'rm -f "$COOKIE_JAR"' EXIT

echo "------------------------------------------"
echo "1. WAIT FOR JENKINS API TO BE RESPONSIVE"
echo "Checking Jenkins availability at ${JENKINS_URL}..."
until curl -sf -u "${USER}:${PASSWORD}" "${JENKINS_URL}/api/json" > /dev/null; do
    echo "Jenkins API not ready yet, retrying in 5s..."
    sleep 5
done
echo "Success: Jenkins API is online."

echo -e "\n------------------------------------------"
echo "2. GET CRUMB AND SAVE SESSION COOKIES"
CRUMB=$(curl -fsSL -u "${USER}:${PASSWORD}" \
             --cookie-jar "${COOKIE_JAR}" \
             "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")

echo -e "\n------------------------------------------"
echo "3. GENERATE NEW API TOKEN"
API_TOKEN=$(curl -fsSL -u "${USER}:${PASSWORD}" \
                 -H "${CRUMB}" \
                 --cookie "${COOKIE_JAR}" \
                 -X POST \
                 --data "newTokenName=${TOKEN_NAME}" \
                 "${JENKINS_URL}/me/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken" \
                 | jq -r '.data.tokenValue')

if [ -z "${API_TOKEN}" ] || [ "${API_TOKEN}" == "null" ]; then
    echo "ERROR: Failed to generate Jenkins API Token." >&2
    exit 1
fi
echo "Success: API token generated."

echo -e "\n------------------------------------------"
echo "4. CREATE OR UPDATE JOB '${NEW_JOB_NAME}'"
if [ ! -f "${JOB_XML_PATH}" ]; then
    echo "ERROR: Job configuration file not found at ${JOB_XML_PATH}" >&2
    exit 1
fi

# Check if job already exists to make the script idempotent
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "${USER}:${API_TOKEN}" "${JENKINS_URL}/job/${NEW_JOB_NAME}/api/json")

if [ "${HTTP_STATUS}" -eq 200 ]; then
    echo "Job '${NEW_JOB_NAME}' already exists. Updating configuration..."
    curl -fsSL -X POST -u "${USER}:${API_TOKEN}" \
         -H "Content-Type: application/xml" \
         --data-binary @"${JOB_XML_PATH}" \
         "${JENKINS_URL}/job/${NEW_JOB_NAME}/config.xml"
else
    echo "Creating new job '${NEW_JOB_NAME}'..."
    curl -fsSL -X POST -u "${USER}:${API_TOKEN}" \
         -H "Content-Type: application/xml" \
         --data-binary @"${JOB_XML_PATH}" \
         "${JENKINS_URL}/createItem?name=${NEW_JOB_NAME}"
fi

echo -e "\n------------------------------------------"
echo "5. TRIGGER JOB BUILD"
curl -fsSL -X POST -u "${USER}:${API_TOKEN}" \
     "${JENKINS_URL}/job/${NEW_JOB_NAME}/build"
echo "Build triggered successfully."

echo -e "\n------------------------------------------"
echo "6. WAIT FOR BUILD COMPLETION"
sleep 180

RESULT=$(curl -sf -u "${USER}:${API_TOKEN}" "${JENKINS_URL}/job/${NEW_JOB_NAME}/lastBuild/api/json" | jq -r '.result // "STILL_RUNNING"')

echo "Build status: ${RESULT}"
[ "${RESULT}" == "SUCCESS" ] || exit 1

echo -e "\n=========================================="
echo "Jenkins job '${NEW_JOB_NAME}' completed successfully!"
echo "=========================================="
