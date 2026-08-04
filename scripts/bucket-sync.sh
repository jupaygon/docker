#!/bin/bash

# =============================================================================
# bucket-sync.sh — copy objects between two S3-compatible buckets.
#
# The sibling of db-sync.sh, for the other half of a migration: relational data
# travels as a dump, uploaded files travel as objects. Not a daily tool — this
# runs the handful of times a project changes provider, or when one environment
# needs a copy of another's files.
#
# The copy happens BOX TO BOX. rclone runs on the destination box and pulls from
# the source bucket, so nothing crosses a home connection or lands on this
# laptop's disk. What this script does is decide, ask, and drive it over SSH.
#
# Nothing is ever deleted: `rclone copy`, not `sync`. A migration that removes
# objects at the destination because someone swapped the arguments is not a
# migration, it is an outage.
#
# Applications usually store a relative object path in the database — no bucket,
# no endpoint — so the prefix is what ties a dump to its objects. Source and
# destination prefixes are asked for separately, because the move worth having is
# not only prod -> prod: the same way a prod dump is loaded into staging, prod's
# objects are copied under staging's prefix and the paths in that dump resolve.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  echo "Copy .env.dist to .env and configure BUCKET_SYNC_SITES"
  exit 1
fi

source "$ENV_FILE"

if [ -z "${BUCKET_SYNC_SITES:-}" ]; then
  echo "ERROR: BUCKET_SYNC_SITES must be set in .env"
  exit 1
fi

# One entry per place the objects can live:
#   name:server:endpoint:bucket:region
SITE_NAMES=()
SITE_SERVERS=()
SITE_ENDPOINTS=()
SITE_BUCKETS=()
SITE_REGIONS=()

IFS=',' read -ra SITE_ENTRIES <<< "$BUCKET_SYNC_SITES"
for entry in "${SITE_ENTRIES[@]}"; do
  # The endpoint carries "https://", so a plain split on ':' would break it.
  name="${entry%%:*}"; rest="${entry#*:}"
  server="${rest%%:*}"; rest="${rest#*:}"
  region="${rest##*:}"; rest="${rest%:*}"
  bucket="${rest##*:}"; endpoint="${rest%:*}"

  if [ -z "$name" ] || [ -z "$server" ] || [ -z "$endpoint" ] || [ -z "$bucket" ] || [ -z "$region" ]; then
    echo "ERROR: invalid BUCKET_SYNC_SITES entry: $entry"
    echo "Expected: name:server:endpoint:bucket:region"
    exit 1
  fi

  SITE_NAMES+=("$name")
  SITE_SERVERS+=("$server")
  SITE_ENDPOINTS+=("$endpoint")
  SITE_BUCKETS+=("$bucket")
  SITE_REGIONS+=("$region")
done

if [ "${#SITE_NAMES[@]}" -lt 2 ]; then
  echo "ERROR: BUCKET_SYNC_SITES needs at least two sites to move anything between"
  exit 1
fi

RCLONE_IMAGE="${BUCKET_SYNC_RCLONE_IMAGE:-rclone/rclone:latest}"
BOX_ENV_FILE="${BUCKET_SYNC_BOX_ENV:-/etc/bucket-sync.env}"

# =============================================================================
# Functions
# =============================================================================

ask_site() {
  # $1 = prompt, $2 = index to exclude (or -1). Sets SELECTED_IDX.
  local prompt="$1" exclude="$2" i

  echo ""
  echo "$prompt"
  echo ""
  for i in "${!SITE_NAMES[@]}"; do
    [ "$i" = "$exclude" ] && continue
    echo "  $((i + 1))) ${SITE_NAMES[$i]}  (${SITE_BUCKETS[$i]} @ ${SITE_SERVERS[$i]})"
  done
  echo ""

  while true; do
    read -rp "Choose: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#SITE_NAMES[@]}" ] \
       && [ "$((choice - 1))" != "$exclude" ]; then
      SELECTED_IDX=$((choice - 1))
      echo "  -> ${SITE_NAMES[$SELECTED_IDX]}"
      return
    fi
    echo "  Invalid option. Try again."
  done
}

ask_prefix() {
  local question="$1"
  local candidates=()
  IFS=',' read -ra candidates <<< "${BUCKET_SYNC_PREFIXES:-prod,staging}"

  echo ""
  echo "$question"
  echo ""
  local i
  for i in "${!candidates[@]}"; do
    echo "  $((i + 1))) ${candidates[$i]}"
  done
  echo ""

  while true; do
    read -rp "Choose [1-${#candidates[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates[@]}" ]; then
      SELECTED_PREFIX="${candidates[$((choice - 1))]}"
      # A prefix is a folder name in a bucket. Anything else is a typo in .env, and
      # it is better to say so here than to watch rclone copy into a path nobody
      # meant.
      if [[ ! "$SELECTED_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "ERROR: invalid prefix '$SELECTED_PREFIX' in BUCKET_SYNC_PREFIXES"
        echo "Expected letters, digits, dot, underscore or hyphen"
        exit 1
      fi
      echo "  -> $SELECTED_PREFIX"
      return
    fi
    echo "  Invalid option. Try again."
  done
}

ask_action() {
  echo ""
  echo "What do you want to do?"
  echo ""
  echo "  1) check  — count objects and bytes on both sides, copy nothing"
  echo "  2) copy   — copy what is missing at the destination (resumable, deletes nothing)"
  echo ""

  while true; do
    read -rp "Choose [1-2]: " choice
    case "$choice" in
      1) SELECTED_ACTION="check"; echo "  -> check"; return ;;
      2) SELECTED_ACTION="copy";  echo "  -> copy";  return ;;
      *) echo "  Invalid option. Try again." ;;
    esac
  done
}

# Credentials per site, from .env: BUCKET_SYNC_KEY_<NAME> / _SECRET_<NAME>, with
# the site name upper-cased. Same place the GitHub token already lives, and the
# same reason: this file is gitignored and typing keys on every run of a tool that
# copies 100k objects is not caution, it is friction.
site_credentials() {
  local name upper
  name="$1"
  upper="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"

  local key_var="BUCKET_SYNC_KEY_${upper}"
  local secret_var="BUCKET_SYNC_SECRET_${upper}"

  CRED_KEY="${!key_var:-}"
  CRED_SECRET="${!secret_var:-}"
}

ask_source_credentials() {
  site_credentials "${SITE_NAMES[$SRC_IDX]}"
  SRC_KEY="$CRED_KEY"
  SRC_SECRET="$CRED_SECRET"

  # Only prompt for what .env did not provide, so a site can be configured or not
  # without changing how this is used.
  if [ -z "$SRC_KEY" ]; then
    echo ""
    read -rp "Access key for ${SITE_NAMES[$SRC_IDX]}: " SRC_KEY
  fi
  if [ -z "$SRC_SECRET" ]; then
    read -rsp "Secret key for ${SITE_NAMES[$SRC_IDX]}: " SRC_SECRET
    echo ""
  fi

  if [ -z "$SRC_KEY" ] || [ -z "$SRC_SECRET" ]; then
    echo "ERROR: no credentials for ${SITE_NAMES[$SRC_IDX]}"
    echo "Set BUCKET_SYNC_KEY_$(printf '%s' "${SITE_NAMES[$SRC_IDX]}" | tr '[:lower:]-' '[:upper:]_')" \
         "and BUCKET_SYNC_SECRET_… in .env"
    exit 1
  fi
}

# The destination's own credentials are usually already on the destination box,
# written there by whatever provisions it. Reading them there beats typing them,
# and beats keeping a second copy anywhere else.
read_destination_credentials() {
  local server="${SITE_SERVERS[$DST_IDX]}"
  local out

  # -n, because ssh reads stdin by default and would swallow whatever is queued
  # there — the answers to the prompts that come after it.
  out="$(ssh -n "$server" "sudo -n cat '$BOX_ENV_FILE' 2>/dev/null || cat '$BOX_ENV_FILE'" 2>/dev/null)"
  DST_KEY="$(printf '%s\n' "$out" | sed -n 's/^AWS_ACCESS_KEY_ID=//p' | tail -1)"
  DST_SECRET="$(printf '%s\n' "$out" | sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' | tail -1)"

  if [ -z "$DST_KEY" ] || [ -z "$DST_SECRET" ]; then
    # A box running on an instance profile publishes no keys: there the role
    # provides them, and rclone can use it — but only for the destination it
    # lives in.
    echo "  -> no keys in $BOX_ENV_FILE on $server; assuming an instance role"
    DST_USE_ROLE=1
  else
    DST_USE_ROLE=0
  fi
}

# rclone's config travels in through stdin and is written with mode 600 on the
# destination box, then removed. Credentials must not end up in the remote
# process list, which is exactly where `ssh host "env KEY=... rclone"` would put
# them for anyone running ps.
#
# server_side_encryption on the SOURCE is not a request to encrypt anything — the
# source is only ever read here. It is how you tell rclone that the ETags coming
# back from that bucket are not MD5 sums.
#
# Without it every single object fails with `BadDigest: The Content-MD5 you
# specified did not match what we received`. rclone takes the source ETag as the
# object's MD5 when it looks like one (32 hex characters), and sends it as the
# Content-MD5 header of the PutObject at the destination. A bucket encrypted with
# SSE-KMS breaks that assumption: KMS-encrypted objects have an ETag that is not
# the MD5 of their data, so the header is a hash of nothing and the destination
# rejects the upload.
#
# Declaring it makes rclone drop the ETag instead of trusting it, and with no
# source hash there is no Content-MD5 to get wrong. What that costs is per-object
# checksum verification, which was never real here anyway — it was comparing
# against a value that is not a checksum. `check` still counts objects and bytes
# on both sides, and the transfer itself runs over TLS with retries.
build_remote_config() {
  printf '[src]\ntype = s3\nprovider = Other\nserver_side_encryption = aws:kms\nendpoint = %s\nregion = %s\naccess_key_id = %s\nsecret_access_key = %s\n\n' \
    "${SITE_ENDPOINTS[$SRC_IDX]}" "${SITE_REGIONS[$SRC_IDX]}" "$SRC_KEY" "$SRC_SECRET"

  if [ "$DST_USE_ROLE" = "1" ]; then
    printf '[dst]\ntype = s3\nprovider = AWS\nenv_auth = true\nendpoint = %s\nregion = %s\n' \
      "${SITE_ENDPOINTS[$DST_IDX]}" "${SITE_REGIONS[$DST_IDX]}"
  else
    printf '[dst]\ntype = s3\nprovider = Other\nendpoint = %s\nregion = %s\naccess_key_id = %s\nsecret_access_key = %s\n' \
      "${SITE_ENDPOINTS[$DST_IDX]}" "${SITE_REGIONS[$DST_IDX]}" "$DST_KEY" "$DST_SECRET"
  fi
}

# Quote a value for reuse as shell input, POSIX style: wrap in single quotes and
# escape any single quote inside. Not printf %q, which emits bashisms the remote
# shell may not be.
shq() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# One rclone invocation in its own container. Mounted read-only at the same path
# the remote shell chose, so the config never has a name this script decides.
docker_rclone() {
  printf 'docker run --rm -i -v "$CONF":"$CONF":ro %s' "$1"
}

run_on_destination() {
  local server="${SITE_SERVERS[$DST_IDX]}"
  local src_path="src:${SITE_BUCKETS[$SRC_IDX]}/${SRC_PREFIX}"
  local dst_path="dst:${SITE_BUCKETS[$DST_IDX]}/${DST_PREFIX}"
  local rclone_args

  # Everything crossing into the remote command is quoted here. The values come
  # from .env and from a numbered menu, so there is no attacker today — but the
  # command is assembled as a string, and a bucket or prefix carrying a quote would
  # otherwise break it in ways that are hard to read and easy to misdiagnose.
  local q_src q_dst q_img
  q_src="$(shq "$src_path")"
  q_dst="$(shq "$dst_path")"
  q_img="$(shq "$RCLONE_IMAGE")"

  # Two sizes rather than `rclone check`: a full checksum pass costs a long time on
  # a big bucket, and what you want before and after a move is the count and the
  # bytes on each side.
  #
  # Each rclone run is its own `docker run`, and that is the fix for a real bug:
  # chaining them with `&&` inside the arguments put the second one in the REMOTE
  # SHELL, which has no rclone. The first count printed and then "rclone: command
  # not found".
  local remote_body
  case "$SELECTED_ACTION" in
    check)
      remote_body="echo '--- source ---'
      $(docker_rclone "$q_img") size $q_src --config \"\$CONF\"
      echo '--- destination ---'
      $(docker_rclone "$q_img") size $q_dst --config \"\$CONF\""
      ;;
    copy)
      remote_body="$(docker_rclone "$q_img") copy $q_src $q_dst --config \"\$CONF\" \
        --transfers 16 --checkers 32 --fast-list --stats 30s --stats-one-line"
      ;;
  esac

  echo ""
  echo "  running rclone $SELECTED_ACTION on $server"
  echo "  $src_path  ->  $dst_path"
  echo ""

  # The config arrives on stdin and is written to a temporary file of the remote
  # shell's choosing — mktemp rather than a fixed /tmp/rc.conf, so two runs cannot
  # collide and no predictable name is left behind. umask 077 before creating it,
  # and a trap that removes it on exit, INT and TERM, including a Ctrl-C halfway
  # through a six-hour copy.
  build_remote_config | ssh "$server" "
    set -e
    umask 077
    CONF=\$(mktemp)
    trap 'rm -f \"\$CONF\"' EXIT INT TERM
    cat > \"\$CONF\"
    $remote_body
  "
}

# =============================================================================
# Main
# =============================================================================

echo "============================================================"
echo " Bucket sync — copies objects between S3-compatible buckets"
echo "============================================================"

ask_site "Copy FROM which site?" -1
SRC_IDX="$SELECTED_IDX"

ask_site "Copy TO which site?" "$SRC_IDX"
DST_IDX="$SELECTED_IDX"

ask_prefix "Which prefix at the source?"
SRC_PREFIX="$SELECTED_PREFIX"

ask_prefix "Which prefix at the destination?"
DST_PREFIX="$SELECTED_PREFIX"

ask_action
ask_source_credentials
read_destination_credentials

echo ""
echo "  from : ${SITE_NAMES[$SRC_IDX]}  ${SITE_BUCKETS[$SRC_IDX]}/${SRC_PREFIX}"
echo "  to   : ${SITE_NAMES[$DST_IDX]}  ${SITE_BUCKETS[$DST_IDX]}/${DST_PREFIX}"
echo "  where: rclone runs on ${SITE_SERVERS[$DST_IDX]}, nothing passes through this machine"
if [ "$SRC_PREFIX" != "$DST_PREFIX" ]; then
  echo "  note : crossing environments — the objects land under '$DST_PREFIX', which is"
  echo "         what a dump taken from '$SRC_PREFIX' expects to find there"
fi
echo ""

if [ "$SELECTED_ACTION" = "copy" ]; then
  read -rp "Copy now? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

run_on_destination
rc=$?

echo ""
if [ "$rc" -ne 0 ]; then
  echo "FAILED (exit $rc). Nothing was deleted; run it again to resume where it stopped."
  exit "$rc"
fi

echo "Done."
if [ "$SELECTED_ACTION" = "copy" ]; then
  echo "Run 'check' now to compare both sides, and run 'copy' once more with the site"
  echo "stopped to pick up whatever came in while this was running."
fi
