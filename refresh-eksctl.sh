#!/usr/bin/env bash
# refresh-ekscreds.sh

# 1. Pick your profile
profile="${AWS_PROFILE:-default}"

# 2. Where is your SSO directory?
sso_region=$(aws configure get sso_region        --profile "$profile")

# 3. Where do your AWS services live?
aws_region=$(aws configure get region             --profile "$profile")
# Fallback if you haven’t set it:
aws_region=${aws_region:-us-west-2}

account=$(aws configure get sso_account_id       --profile "$profile")
role=$(aws configure get sso_role_name           --profile "$profile")

# 4. Grab the most recent SSO cache file
cache=$(ls -1t ~/.aws/sso/cache/*.json | head -n1)
token=$(jq -r .accessToken "$cache")

# 5. Exchange for AWS creds in the SSO realm
creds_json=$(
  aws sso get-role-credentials \
    --account-id   "$account" \
    --role-name    "$role" \
    --access-token "$token" \
    --region       "$sso_region"
)

# 6. Export them
export AWS_ACCESS_KEY_ID=$(jq -r .roleCredentials.accessKeyId     <<<"$creds_json")
export AWS_SECRET_ACCESS_KEY=$(jq -r .roleCredentials.secretAccessKey <<<"$creds_json")
export AWS_SESSION_TOKEN=$(jq -r .roleCredentials.sessionToken    <<<"$creds_json")

# 7. And set the AWS region for STS/EKS calls
export AWS_REGION="$aws_region"
export AWS_DEFAULT_REGION="$aws_region"

# 8. Now list clusters
eksctl get cluster --region "$aws_region"
