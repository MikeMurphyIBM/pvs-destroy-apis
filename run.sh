#!/bin/sh

echo "=== EMPTY IBM i Destruction Script ==="

# -------------------------
# 1. Environment Variables
# -------------------------

# Authentication Key (Provided via Code Engine secret)
API_KEY="${IBMCLOUD_API_KEY}"

# Full PowerVS CRN (MUST be used in the request header)
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"

# PowerVS Identifiers (Copied from Provisioning Script)
REGION="us-south"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"

# Target LPAR Name (Must match the name used during provisioning)
LPAR_NAME="empty-ibmi-lpar" 

# API Version used for requests
API_VERSION="2024-02-28"

PVS_API_BASE="https://${REGION}.power-iaas.cloud.ibm.com/pcloud"

# -------------------------
# 2. IAM Token (Authentication)
# -------------------------

echo "--- Requesting IAM access token ---"

# Use the API Key to generate a bearer token [4]
IAM_TOKEN=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${API_KEY}" \
  | jq -r '.access_token')

if [ "$IAM_TOKEN" = "null" ] || [ -z "$IAM_TOKEN" ]; then
  echo " ERROR retrieving IAM token"
  exit 1
fi

echo "--- Token acquired ---"

# -------------------------
# 3. Dynamic Lookup: Get PVS Instance ID by LPAR Name
# -------------------------

# API endpoint to list all instances in the workspace
LIST_URL="${PVS_API_BASE}/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "--- Searching for LPAR ID using name: ${LPAR_NAME} ---"


# debug line to verify the CRN value
echo "DEBUG: PVS_CRN value being used in curl: ${PVS_CRN}"

# Send GET request to list all instances, capturing response body AND HTTP code
RESPONSE=$(curl -s -X GET "${LIST_URL}" \
  -w "%{http_code}" \
  -H "Authorization: Bearer ${IAM_TOKEN}"\
  -H "CRN: ${PVS_CRN}")

# Separate the HTTP code (last 3 characters) from the response body
HTTP_CODE=${RESPONSE: -3}
INSTANCE_LIST=${RESPONSE: 0: ${#RESPONSE}-3}

# --- DEBUGGING STEP: Inspect the raw API response ---
echo "--- Raw PowerVS Instance List Response ---"
echo "HTTP Status Code: ${HTTP_CODE}"
echo "Response Body:"
echo "$INSTANCE_LIST" | jq .
echo "----------------------------------------------"

# Check 1: Check for critical HTTP failures (e.g., 403)
if [ "$HTTP_CODE" != "200" ]; then
    echo "CRITICAL ERROR: PowerVS API lookup failed with HTTP Status ${HTTP_CODE}."
    echo "This indicates an issue with API configuration, permissions, or connectivity."
    # Exit 1 signals definitive job failure to Code Engine (CE)
    exit 1
fi


# Check 2: Attempt to filter the list (This step only runs if HTTP_CODE was 200)
PVM_INSTANCE_ID=$(echo "$INSTANCE_LIST" | \
  jq -r '.pvmInstances[] | select(.serverName == "'"${LPAR_NAME}"'") | .pvmInstanceID')
  
# Check 3: Determine the outcome (LPAR Found or Already Gone)
if [ -z "$PVM_INSTANCE_ID" ] || [ "$PVM_INSTANCE_ID" = "null" ]; then
    echo "LPAR ${LPAR_NAME} not found or already deleted. Exiting safely."
    # Exit 0 here is crucial: it confirms the desired end state (LPAR absence) was reached.
    exit 0
else
    echo "--- Found Instance ID: ${PVM_INSTANCE_ID} ---"
    # The script continues execution to Section 4 (Deletion)
fi

# -------------------------
# 4. API Call: Delete LPAR
# -------------------------

DELETE_URL="${PVS_API_BASE}/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances/${PVM_INSTANCE_ID}"

echo "--- Submitting DELETE request for LPAR ID: ${PVM_INSTANCE_ID} ---"

# Use DELETE method targeting the specific instance ID (ibmcloud pi instance-delete equivalent)
RESPONSE=$(curl -s -X DELETE "${DELETE_URL}?version=${API_VERSION}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "CRN: ${PVS_CRN}")

# -------------------------
# 5. Success Check (for deletion)
# -------------------------

# A successful API DELETE request often returns an empty body or HTTP 204 (No Content).
if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "null" ]; then
  echo " SUCCESS: IBM i LPAR ${PVM_INSTANCE_ID} deletion request accepted."
  exit 0
else
  # If a non-empty, error response (JSON) is received
  echo "--- API Response during Deletion ---"
  echo "$RESPONSE" | jq .
  
  if echo "$RESPONSE" | jq -e '.status' >/dev/null 2>&1; then
    echo " ERROR processing deletion request."
    exit 1
  else
    echo " SUCCESS: IBM i LPAR deletion submitted (Non-JSON response received, check log)."
    exit 0 # Assume deletion submission succeeded if no structured error is present
  fi
fi
