#!/usr/bin/env bash
# Turn Telegram messages into labelled issues, so a data bug can be reported
# from a phone at a table and picked up by the routine that fixes it.
#
# **Stateless on purpose.** Telegram holds the queue: `getUpdates` returns
# everything unconfirmed, and calling it again with `offset=<last+1>` is what
# confirms delivery. So this script keeps no cursor, commits nothing, and a
# run that fails to file an issue simply leaves the message queued for the
# next run rather than losing it. Unconfirmed updates live 24 hours, which is
# 288 runs at this schedule.
#
# Needs TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_CHAT_ID and GH_TOKEN.

set -euo pipefail

# Quiet until it is set up. The workflow is committed before the bot exists,
# and a job that fails every five minutes trains its owner to ignore the one
# time it means something.
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_ALLOWED_CHAT_ID:-}" ]; then
  echo "TELEGRAM_BOT_TOKEN or TELEGRAM_ALLOWED_CHAT_ID is not set; see docs/DATA-BUGS.md"
  exit 0
fi

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
REPO="${GITHUB_REPOSITORY:-Manus-Systematum/Structor_core}"

updates="$(curl -sS --max-time 30 "${API}/getUpdates?timeout=0&allowed_updates=%5B%22message%22%5D")"
if [ "$(jq -r '.ok' <<<"$updates")" != "true" ]; then
  echo "Telegram refused the request: $(jq -c '.description // .' <<<"$updates")" >&2
  exit 1
fi

count="$(jq '.result | length' <<<"$updates")"
if [ "$count" -eq 0 ]; then
  echo "nothing queued"
  exit 0
fi

# The label has to exist before an issue can carry it, and saying so here means
# a fresh clone of this repository needs no setup step nobody remembers.
gh label create data-bug --repo "$REPO" --color B60205 \
  --description "Reported from Telegram; the fixing routine picks these up" \
  2>/dev/null || true

filed=0
while read -r update; do
  chat="$(jq -r '.message.chat.id // empty' <<<"$update")"
  text="$(jq -r '.message.text // empty' <<<"$update")"
  from="$(jq -r '.message.from.username // .message.from.first_name // "unknown"' <<<"$update")"
  sent="$(jq -r '.message.date // 0' <<<"$update")"

  # Anyone can message a bot whose name they know. Only the chat named in the
  # secret can file work for the routine to do.
  if [ "$chat" != "$TELEGRAM_ALLOWED_CHAT_ID" ]; then
    echo "ignored a message from chat $chat" >&2
    continue
  fi
  [ -n "$text" ] || continue

  # The first line names the issue, the whole message is the body. A bug
  # reported in one sentence should not have to be titled separately.
  title="$(head -1 <<<"$text" | cut -c1-72)"
  body="$(mktemp)"
  {
    printf '%s\n\n' "$text"
    printf -- '---\n'
    printf 'Reported through Telegram by %s at %s UTC.\n' \
      "$from" "$(date -u -d "@$sent" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$sent")"
  } > "$body"

  url="$(gh issue create --repo "$REPO" --title "$title" \
        --body-file "$body" --label data-bug)"
  rm -f "$body"
  filed=$((filed + 1))
  echo "filed $url"

  curl -sS --max-time 30 -o /dev/null "${API}/sendMessage" \
    --data-urlencode "chat_id=${chat}" \
    --data-urlencode "text=Filed: ${url}"
done < <(jq -c '.result[]' <<<"$updates")

# Confirm only after the issues exist: an update stays queued until the work
# it describes is somewhere durable.
last="$(jq '[.result[].update_id] | max' <<<"$updates")"
curl -sS --max-time 30 -o /dev/null "${API}/getUpdates?offset=$((last + 1))&timeout=0"
echo "confirmed through update $last; filed $filed"
