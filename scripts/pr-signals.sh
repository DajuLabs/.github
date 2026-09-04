#!/usr/bin/env bash
# pr-signals.sh — detect PR impact signals (env vars, db migrations,
# multi-service deploy, queues, CI/deploy changes) from the diff, cross-check
# against the "Impact checklist" in the PR body, comment on the PR, and
# optionally post a digest of all open PRs to a Microsoft Teams channel.
#
# Requires: gh CLI authenticated (`gh auth status`), jq, curl (for digest).
#
# Usage:
#   pr-signals.sh scan     --repo <org>/<repo> --pr <number> [--comment]
#   pr-signals.sh alert    --repo <org>/<repo> --pr <number> --teams-webhook <url>
#   pr-signals.sh scan-all --org <org> [--comment]
#   pr-signals.sh digest   --org <org> --teams-webhook <url>
#   pr-signals.sh --help
#
# Every PR is always reported together with its author (GitHub login) —
# in the scan comment, in scan-all's table, and in the Teams digest.

set -euo pipefail

# All PRs must target this base branch — see SKILL.md "Pull requests".
EXPECTED_BASE="development"

# ---------------------------------------------------------------------------
# Signal patterns — keep in sync with references/signals.md
# ---------------------------------------------------------------------------
# Each signal maps to: emoji | label | grep -E pattern applied to `gh pr diff`
SIGNAL_KEYS=(env db multideploy queue ci)

signal_emoji() {
  case "$1" in
    env) echo "🔑" ;;
    db) echo "🗄️" ;;
    multideploy) echo "🚀" ;;
    queue) echo "🐇" ;;
    ci) echo "⚙️" ;;
  esac
}

signal_label() {
  case "$1" in
    env) echo "New/changed environment variables" ;;
    db) echo "New table / migration / schema change" ;;
    multideploy) echo "Requires deploy in more than one service" ;;
    queue) echo "RabbitMQ queue/exchange added or changed" ;;
    ci) echo "CI/CD or deploy workflow changed" ;;
  esac
}

signal_pattern() {
  case "$1" in
    env) echo '^\+\+\+ .*\.env|^\+[A-Z0-9_]+=.*' ;;
    db) echo '^\+\+\+ .*(migrations?/|schema\.prisma|\.sql$)' ;;
    multideploy) echo '^\+\+\+ .*(docker-compose.*\.ya?ml|k8s/|deployment.*\.ya?ml)' ;;
    queue) echo '^\+.*\b(exchange|queue|bindQueue|assertQueue|assertExchange)\b' ;;
    ci) echo '^\+\+\+ .*\.github/workflows/' ;;
  esac
}

usage() {
  sed -n '2,17p' "$0"
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Post a Teams Adaptive Card. `lines` is a newline-separated string; the
# first line renders bold/larger as a header, the rest as plain text blocks.
# Microsoft Teams' "Post card in a chat or channel" action (Power Automate
# webhook flow) expects the POSTed body to BE a full Adaptive Card object,
# not a plain {"text": "..."} payload.
# ---------------------------------------------------------------------------
post_teams_card() {
  local webhook="$1" lines="$2"
  local card
  card="$(printf '%s\n' "$lines" | jq -R -s -c 'split("\n") | map(select(length > 0))' |
    jq -c '{
      type: "AdaptiveCard",
      "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
      version: "1.4",
      body: (
        [ { type: "TextBlock", text: .[0], weight: "bolder", size: "medium", wrap: true } ] +
        ( .[1:] | map({ type: "TextBlock", text: ., wrap: true, spacing: "small" }) )
      )
    }')"
  curl -sf -H "Content-Type: application/json" -d "$card" "$webhook" >/dev/null
}

# ---------------------------------------------------------------------------
# Detect signals present in a PR's diff. Prints matching signal keys, one per line.
# ---------------------------------------------------------------------------
detect_signals() {
  local repo="$1" pr="$2"
  local diff
  diff="$(gh pr diff "$pr" --repo "$repo" 2>/dev/null || true)"

  local key
  for key in "${SIGNAL_KEYS[@]}"; do
    if grep -qEi "$(signal_pattern "$key")" <<< "$diff"; then
      echo "$key"
    fi
  done

  # A PR touching Dockerfile/compose/deploy config in more than one
  # top-level service directory also counts as multideploy, even if it
  # didn't match the compose/k8s filename pattern above.
  local touched_services
  touched_services="$(grep -E '^\+\+\+ b/' <<< "$diff" | sed -E 's#^\+\+\+ b/([^/]+)/.*#\1#' | sort -u | wc -l)"
  if [ "$touched_services" -gt 1 ]; then
    echo "multideploy"
  fi
}

# ---------------------------------------------------------------------------
# Extract which signals are checked ([x]) in the PR body via the
# <!-- signal:xxx --> markers.
# ---------------------------------------------------------------------------
declared_signals() {
  local body="$1"
  local key
  for key in "${SIGNAL_KEYS[@]}"; do
    if grep -qiE "^\s*-\s*\[x\].*<!--\s*signal:${key}\s*-->" <<< "$body"; then
      echo "$key"
    fi
  done
}

build_comment() {
  local author="$1"; shift
  local base="$1"; shift
  local detected="$1"; shift
  local declared="$1"; shift

  echo "### 🔎 PR impact signals"
  echo
  echo "**Author:** @${author}"
  if [ "$base" != "$EXPECTED_BASE" ]; then
    echo
    echo "🚨 **Base branch is \`${base}\`, expected \`${EXPECTED_BASE}\`.** Retarget this PR before merging."
  fi
  echo
  echo "| Signal | Detected in diff | Checked in description |"
  echo "| --- | --- | --- |"
  local key
  for key in "${SIGNAL_KEYS[@]}"; do
    local d="—" c="—"
    grep -qx "$key" <<< "$detected" && d="$(signal_emoji "$key") yes"
    grep -qx "$key" <<< "$declared" && c="$(signal_emoji "$key") yes"
    echo "| $(signal_label "$key") | $d | $c |"
  done

  echo
  local mismatch=0
  for key in "${SIGNAL_KEYS[@]}"; do
    if grep -qx "$key" <<< "$detected" && ! grep -qx "$key" <<< "$declared"; then
      echo "⚠️ Diff touches **$(signal_label "$key")** but the box isn't checked — please update the description or confirm it's a false positive."
      mismatch=1
    fi
  done
  [ "$mismatch" -eq 0 ] && echo "✅ Detected signals match the declared checklist."
}

cmd_scan() {
  local repo="" pr="" do_comment=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --pr) pr="$2"; shift 2 ;;
      --comment) do_comment=1; shift ;;
      *) echo "Unknown flag: $1" >&2; usage ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$pr" ] || { echo "scan requires --repo and --pr" >&2; usage; }

  local pr_json author body base
  pr_json="$(gh pr view "$pr" --repo "$repo" --json author,body,baseRefName)"
  author="$(echo "$pr_json" | jq -r '.author.login')"
  body="$(echo "$pr_json" | jq -r '.body // ""')"
  base="$(echo "$pr_json" | jq -r '.baseRefName')"

  local detected declared comment
  detected="$(detect_signals "$repo" "$pr")"
  declared="$(declared_signals "$body")"
  comment="$(build_comment "$author" "$base" "$detected" "$declared")"

  echo "$comment"
  if [ "$do_comment" -eq 1 ]; then
    gh pr comment "$pr" --repo "$repo" --body "$comment"
  fi
}

cmd_scan_all() {
  local org="" do_comment=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --org) org="$2"; shift 2 ;;
      --comment) do_comment=1; shift ;;
      *) echo "Unknown flag: $1" >&2; usage ;;
    esac
  done
  [ -n "$org" ] || { echo "scan-all requires --org" >&2; usage; }

  printf '%-45s %-8s %-18s %-12s %s\n' "REPO" "PR" "AUTHOR" "BASE" "SIGNALS"
  gh search prs --owner "$org" --state open --json repository,number,author \
    --jq '.[] | [.repository.nameWithOwner, .number, .author.login] | @tsv' |
  while IFS=$'\t' read -r repo pr author; do
    local detected base base_flag
    detected="$(detect_signals "$repo" "$pr" | tr '\n' ',' | sed 's/,$//')"
    base="$(gh pr view "$pr" --repo "$repo" --json baseRefName -q '.baseRefName' 2>/dev/null || echo "?")"
    base_flag="$base"
    [ "$base" != "$EXPECTED_BASE" ] && base_flag="⚠️ $base"
    printf '%-45s %-8s %-18s %-12s %s\n' "$repo" "#$pr" "@$author" "$base_flag" "${detected:-none}"
    if [ "$do_comment" -eq 1 ]; then
      cmd_scan --repo "$repo" --pr "$pr" --comment >/dev/null
    fi
  done
}

cmd_digest() {
  local org="" webhook=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --org) org="$2"; shift 2 ;;
      --teams-webhook) webhook="$2"; shift 2 ;;
      *) echo "Unknown flag: $1" >&2; usage ;;
    esac
  done
  [ -n "$org" ] && [ -n "$webhook" ] || { echo "digest requires --org and --teams-webhook" >&2; usage; }

  local rows
  rows="$(gh search prs --owner "$org" --state open --json repository,number,author,title,url \
    --jq '.[] | [.repository.nameWithOwner, .number, .author.login, .title, .url] | @tsv')"

  local body_lines=()
  body_lines+=("📋 Open PRs digest — ${org} (${EXPECTED_BASE} is the expected base)")
  while IFS=$'\t' read -r repo pr author title url; do
    [ -z "$repo" ] && continue
    local detected emojis="" base base_flag=""
    detected="$(detect_signals "$repo" "$pr")"
    local key
    for key in "${SIGNAL_KEYS[@]}"; do
      grep -qx "$key" <<< "$detected" && emojis="${emojis}$(signal_emoji "$key")"
    done
    base="$(gh pr view "$pr" --repo "$repo" --json baseRefName -q '.baseRefName' 2>/dev/null || echo "?")"
    [ "$base" != "$EXPECTED_BASE" ] && base_flag=" ⚠️base:${base}"
    body_lines+=("${repo}#${pr} by @${author} — ${title} ${emojis}${base_flag} (${url})")
  done <<< "$rows"

  post_teams_card "$webhook" "$(printf '%s\n' "${body_lines[@]}")"
  echo "Digest posted to Teams (${#body_lines[@]} lines, $(( ${#body_lines[@]} - 1 )) open PRs)."
}

# ---------------------------------------------------------------------------
# alert: immediate one-PR notification to Teams, meant to run right after
# `scan --comment` on every pull_request event (opened/synchronize/reopened).
# ---------------------------------------------------------------------------
cmd_alert() {
  local repo="" pr="" webhook=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --pr) pr="$2"; shift 2 ;;
      --teams-webhook) webhook="$2"; shift 2 ;;
      *) echo "Unknown flag: $1" >&2; usage ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$webhook" ] || { echo "alert requires --repo, --pr and --teams-webhook" >&2; usage; }

  local pr_json author body base title url
  pr_json="$(gh pr view "$pr" --repo "$repo" --json author,body,baseRefName,title,url)"
  author="$(echo "$pr_json" | jq -r '.author.login')"
  body="$(echo "$pr_json" | jq -r '.body // ""')"
  base="$(echo "$pr_json" | jq -r '.baseRefName')"
  title="$(echo "$pr_json" | jq -r '.title')"
  url="$(echo "$pr_json" | jq -r '.url')"

  local detected declared emojis=""
  detected="$(detect_signals "$repo" "$pr")"
  declared="$(declared_signals "$body")"
  local key
  for key in "${SIGNAL_KEYS[@]}"; do
    grep -qx "$key" <<< "$detected" && emojis="${emojis}$(signal_emoji "$key")"
  done

  local lines=()
  lines+=("🔔 New/updated PR — ${repo}#${pr}")
  lines+=("${title}")
  lines+=("by @${author} — base: ${base}$([ "$base" != "$EXPECTED_BASE" ] && echo " ⚠️ expected ${EXPECTED_BASE}")")
  lines+=("Signals detected: ${emojis:-none}")

  for key in "${SIGNAL_KEYS[@]}"; do
    if grep -qx "$key" <<< "$detected" && ! grep -qx "$key" <<< "$declared"; then
      lines+=("⚠️ $(signal_label "$key") — not checked in the description")
    fi
  done

  lines+=("${url}")

  post_teams_card "$webhook" "$(printf '%s\n' "${lines[@]}")"
  echo "Alert posted for ${repo}#${pr}."
}

main() {
  require_bin gh
  require_bin jq
  local sub="${1:-}"; shift || true
  case "$sub" in
    scan) cmd_scan "$@" ;;
    alert) require_bin curl; cmd_alert "$@" ;;
    scan-all) cmd_scan_all "$@" ;;
    digest) require_bin curl; cmd_digest "$@" ;;
    --help|-h|"") usage ;;
    *) echo "Unknown subcommand: $sub" >&2; usage ;;
  esac
}

main "$@"
