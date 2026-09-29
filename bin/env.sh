# Source me:  . bin/env.sh
# Reads credentials from ~/.config/obs-demo/env (created by 00_preflight.sh or manually).
ENV_FILE=${OBS_DEMO_ENV:-$HOME/.config/obs-demo/env}
if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE — see .env.example and create it (chmod 600)." >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
export AWS_ACCESS_KEY_ID="$OBS_S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$OBS_S3_SECRET_KEY"
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
export OBS_ENDPOINT="${OBS_S3_HTTP}"
DEMO_PREFIX="demo-"
