#!/usr/bin/env bash
# verify-deploy.sh — confirm the latest docs commit is live on docs.giveready.org
#
# Picks one distinctive added line from the most recent commit's diff,
# curls the corresponding live URL with a cache-busting query string,
# and reports PASS/FAIL. Polls every 30s up to 5 min before giving up.
#
# Usage:  ./scripts/verify-deploy.sh
# Run from the giveready-docs repo root (or any subdir — it cd's via git).
#
# Why this exists: Mintlify auto-builds from GitHub pushes are flaky for this
# project. The dashboard activity log shows only "Manual Update" entries, no
# webhook-triggered builds. Until the GitHub integration is reconnected, every
# push needs a verify pass — this script is that verify pass, scriptable.

set -euo pipefail

DOCS_HOST="${DOCS_HOST:-https://docs.giveready.org}"
TIMEOUT_S="${TIMEOUT_S:-300}"   # 5 min
POLL_S="${POLL_S:-30}"

# Move to repo root so relative paths and git commands work.
cd "$(git rev-parse --show-toplevel)"

LATEST_SHA=$(git rev-parse --short HEAD)
LATEST_FILES=$(git diff-tree --no-commit-id --name-only -r HEAD | grep '\.mdx$' || true)

if [ -z "$LATEST_FILES" ]; then
  echo "No .mdx files changed in HEAD ($LATEST_SHA). Nothing to verify."
  exit 0
fi

# Pick the first changed mdx file and extract a distinctive prose substring.
# Strategy: take added lines, strip markdown formatting (links, inline code,
# bold/italic), drop the leading list-marker if any, then take the first 60
# chars of plain prose. Why 60: long enough to be unlikely to collide with old
# content, short enough to survive Mintlify's JSX rendering which often splits
# long sentences across multiple text nodes.
FIRST_FILE=$(echo "$LATEST_FILES" | head -1)
FINGERPRINT=$(git show HEAD -- "$FIRST_FILE" | grep -E '^\+[^+]' | sed 's/^+//' | \
  grep -vE '^[[:space:]]*$|^[[:space:]]*#|^[[:space:]]*[`*-]|^---' | \
  sed -E 's/\[([^]]+)\]\([^)]+\)/\1/g; s/`([^`]*)`/\1/g; s/\*\*//g; s/\*//g; s/[[:space:]]+/ /g' | \
  awk 'length > 30 {
    s = $0;
    sub(/^[[:space:]]*[0-9]+\.[[:space:]]*/, "", s);
    sub(/^[[:space:]]+/, "", s);
    print substr(s, 1, 60);
    exit
  }')

if [ -z "$FINGERPRINT" ]; then
  echo "Could not extract a distinctive line from $FIRST_FILE diff. Cannot verify."
  echo "Inspect manually: git show HEAD -- $FIRST_FILE"
  exit 1
fi

# Convert mdx file path to URL path: strip .mdx, drop leading ./
URL_PATH=$(echo "$FIRST_FILE" | sed 's/\.mdx$//' | sed 's|^\./||')
URL="${DOCS_HOST}/${URL_PATH}"

echo "Verifying live build of:  $URL"
echo "Looking for fingerprint:  '$FINGERPRINT'"
echo "Source:                   commit $LATEST_SHA, file $FIRST_FILE"
echo ""

start=$(date +%s)
while true; do
  # Strip HTML tags and collapse whitespace before grepping, so inline elements
  # like <code>curl</code> don't break a contiguous prose match.
  # Use a here-string to feed grep, NOT a pipe — under set -o pipefail, a
  # successful grep -q closes stdin early which SIGPIPEs the upstream command
  # (exit 141), making the pipeline look failed even when grep actually
  # matched. Here-string avoids the pipe entirely.
  body=$(curl -sL "${URL}?_=$(date +%s)" | sed -E 's/<[^>]+>/ /g; s/[[:space:]]+/ /g')
  if grep -qF "$FINGERPRINT" <<< "$body"; then
    elapsed=$(( $(date +%s) - start ))
    echo "PASS — content live on docs.giveready.org after ${elapsed}s."
    exit 0
  fi
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -ge "$TIMEOUT_S" ]; then
    echo "FAIL — content not live after ${elapsed}s."
    echo ""
    echo "Mintlify auto-build did not fire. Manual fix:"
    echo "  1. Open https://dashboard.mintlify.com"
    echo "  2. Find the GiveReady project"
    echo "  3. Click 'Manual Update'"
    echo "  4. Re-run this script once the activity log shows Successful."
    echo ""
    echo "Long-term fix: reconnect the GitHub integration in Mintlify so"
    echo "pushes auto-build (settings -> GitHub -> reauthorise gswardman/docs)."
    exit 1
  fi
  echo "  ... not live yet, waiting ${POLL_S}s (elapsed: ${elapsed}s)"
  sleep "$POLL_S"
done
