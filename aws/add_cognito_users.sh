#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Usage (bulk):   ./add_cognito_users.sh -p <user-pool-id> -g <group-name> -r <aws-region> -f <emails-file>
# Usage (single): ./add_cognito_users.sh -p <user-pool-id> -g <group-name> -r <aws-region> -u <email>
#
# -f and -u are mutually exclusive. -f takes a file with one email per line;
# blank lines and lines starting with # are ignored.
# ---------------------------------------------------------------------------

usage() {
  echo "Usage:"
  echo "  Bulk:   $0 -p <user-pool-id> -g <group-name> -r <aws-region> -f <emails-file>"
  echo "  Single: $0 -p <user-pool-id> -g <group-name> -r <aws-region> -u <email>"
  echo ""
  echo "  -p  Cognito User Pool ID          (e.g. eu-west-1_Abc123)"
  echo "  -g  Cognito Group name            (e.g. platform-admins)"
  echo "  -r  AWS Region                    (e.g. eu-west-1)"
  echo "  -f  Path to file with one email per line (mutually exclusive with -u)"
  echo "  -u  Single user email             (mutually exclusive with -f)"
  exit 1
}

USER_POOL_ID=""
GROUP_NAME=""
AWS_REGION=""
EMAILS_FILE=""
SINGLE_EMAIL=""

while getopts "p:g:r:f:u:" opt; do
  case $opt in
    p) USER_POOL_ID="$OPTARG" ;;
    g) GROUP_NAME="$OPTARG" ;;
    r) AWS_REGION="$OPTARG" ;;
    f) EMAILS_FILE="$OPTARG" ;;
    u) SINGLE_EMAIL="$OPTARG" ;;
    *) usage ;;
  esac
done

# Validate required args
[[ -z "$USER_POOL_ID" || -z "$GROUP_NAME" || -z "$AWS_REGION" ]] && usage

# -f and -u are mutually exclusive; exactly one must be provided
if [[ -n "$EMAILS_FILE" && -n "$SINGLE_EMAIL" ]]; then
  echo "ERROR: -f and -u are mutually exclusive — use one or the other."
  exit 1
fi
if [[ -z "$EMAILS_FILE" && -z "$SINGLE_EMAIL" ]]; then
  echo "ERROR: one of -f <emails-file> or -u <email> is required."
  usage
fi

export AWS_REGION

# Build the list of emails to process
if [[ -n "$SINGLE_EMAIL" ]]; then
  EMAIL_SOURCE="single user ($SINGLE_EMAIL)"
  # Feed the single email into a here-string so the loop below is unchanged
  EMAIL_INPUT="$SINGLE_EMAIL"
else
  if [[ ! -f "$EMAILS_FILE" ]]; then
    echo "ERROR: emails file not found: $EMAILS_FILE"
    exit 1
  fi
  EMAIL_SOURCE="file ($EMAILS_FILE)"
  EMAIL_INPUT=""   # unused in file mode; loop reads from $EMAILS_FILE directly
fi

SUCCESS=0
SKIPPED=0
FAILED=0

echo "=================================================="
echo "User Pool : $USER_POOL_ID"
echo "Group     : $GROUP_NAME"
echo "Region    : $AWS_REGION"
echo "Source    : $EMAIL_SOURCE"
echo "=================================================="

process_email() {
  local email="$1"

  echo ""
  echo ">>> Processing: $email"

  # --- Create user -----------------------------------------------------------
  if aws cognito-idp admin-create-user \
      --user-pool-id "$USER_POOL_ID" \
      --username "$email" \
      --user-attributes \
          Name=email,Value="$email" \
          Name=email_verified,Value=true \
      --desired-delivery-mediums EMAIL \
      --output json > /dev/null 2>&1; then
    echo "    [OK] User created"
  else
    ERROR_MSG=$(aws cognito-idp admin-create-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$email" \
        --user-attributes \
            Name=email,Value="$email" \
            Name=email_verified,Value=true \
        --desired-delivery-mediums EMAIL \
        --output json 2>&1 || true)

    if echo "$ERROR_MSG" | grep -q "UsernameExistsException"; then
      echo "    [SKIP] User already exists — skipping create, still adding to group"
      ((SKIPPED++)) || true
    else
      echo "    [FAIL] Could not create user: $ERROR_MSG"
      ((FAILED++)) || true
      return
    fi
  fi

  # --- Add user to group -----------------------------------------------------
  if aws cognito-idp admin-add-user-to-group \
      --user-pool-id "$USER_POOL_ID" \
      --username "$email" \
      --group-name "$GROUP_NAME" \
      --output json > /dev/null 2>&1; then
    echo "    [OK] Added to group '$GROUP_NAME'"
    ((SUCCESS++)) || true
  else
    ERROR_MSG=$(aws cognito-idp admin-add-user-to-group \
        --user-pool-id "$USER_POOL_ID" \
        --username "$email" \
        --group-name "$GROUP_NAME" \
        --output json 2>&1 || true)
    echo "    [FAIL] Could not add to group: $ERROR_MSG"
    ((FAILED++)) || true
  fi
}

if [[ -n "$SINGLE_EMAIL" ]]; then
  process_email "$SINGLE_EMAIL"
else
  while IFS= read -r email || [[ -n "$email" ]]; do
    # Strip whitespace; skip blank lines and comments
    email="$(echo "$email" | tr -d '[:space:]')"
    [[ -z "$email" || "$email" == \#* ]] && continue
    process_email "$email"
  done < "$EMAILS_FILE"
fi

echo ""
echo "=================================================="
echo "Done. Created/added: $SUCCESS | Already existed: $SKIPPED | Failed: $FAILED"
echo "=================================================="