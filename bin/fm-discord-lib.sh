#!/usr/bin/env bash
# fm-discord-lib.sh - shared configuration, secret handling, and message
# budgeting for the two-week Discord spike (docs/discord-spike.md).
#
# Sourced by bin/fm-discord-post.sh (outbound) and
# bin/fm-procevent-discord.sh (inbound). Not an entrypoint.
#
# SECRETS. The webhook URL and the bot token are bearer-equivalent: whoever
# holds the webhook URL can post as Fred, and whoever holds the token can read
# the channel. So this library:
#
#   - reads them from the home's gitignored config/ or from the environment,
#     never from a tracked file and never from a worker brief;
#   - loads them into a shell variable and never prints, logs, or echoes them;
#   - passes them to curl through a config file on stdin (`curl -K -`) rather
#     than argv, so they are not visible in `ps` to any other user on the box;
#   - refuses loudly, naming the config path to write, when one is absent.
#
#   config/discord-webhook     FM_DISCORD_WEBHOOK_URL   outbound. required by fm-discord-post.sh
#   config/discord-bot-token   FM_DISCORD_BOT_TOKEN     inbound.  required by fm-procevent-discord.sh
#   config/discord-channel     FM_DISCORD_CHANNEL_ID    inbound.  required by fm-procevent-discord.sh
#   config/discord-captain     FM_DISCORD_CAPTAIN_ID    inbound.  required by fm-procevent-discord.sh
#
# The environment wins over the file, which is also the Automic Vault path: a
# `bin/fm-av-run.sh FM_DISCORD_WEBHOOK_URL -- bin/fm-discord-post.sh ...` call puts
# the secret in that one process's environment and nothing else, exactly the
# point-of-use contract docs/configuration.md "Automic Vault secret injection"
# already owns. No second secret mechanism is introduced here.
#
# Every value is shape-validated before use, and the validation is a safety
# boundary rather than a nicety: an unvalidated webhook host would send the
# message (and the secret) to whatever host a mistyped config named, and an
# unvalidated token could carry a newline and forge a second HTTP header.

# Discord rejects any message over 2000 characters; this is its hard ceiling and
# not a preference. FM_DISCORD_MAX_CHARS lowers the working budget below it.
FM_DISCORD_HARD_CEILING=2000
FM_DISCORD_DEFAULT_BUDGET=1900

# Set by the resolver functions. Never print these.
FM_DISCORD_WEBHOOK=
FM_DISCORD_TOKEN=
FM_DISCORD_CHANNEL=
FM_DISCORD_CAPTAIN=
# Set by every resolver on refusal: an actionable message with no secret in it.
FM_DISCORD_ERROR=

# fm_discord_config_dir - the home's gitignored config directory.
fm_discord_config_dir() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_ROOT}/config}"
}

# fm_discord_read_setting <config-dir> <file-name>
# First non-comment, non-blank line, with surrounding whitespace stripped.
# Prints nothing when the file is absent or holds no value.
fm_discord_read_setting() {
  local dir=$1 name=$2 path line
  path="$dir/$name"
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in ''|'#'*) continue ;; esac
    printf '%s\n' "$line"
    return 0
  done < "$path"
}

# fm_discord_webhook_valid <url>
# Only Discord's own webhook endpoints. Refusing every other host is what keeps
# a mistyped or tampered config from posting the fleet's business - and the
# bearer secret itself - to somebody else's server.
fm_discord_webhook_valid() {
  local url=${1-}
  case "$url" in
    https://discord.com/api/webhooks/[0-9]*/?*) ;;
    https://discordapp.com/api/webhooks/[0-9]*/?*) ;;
    https://canary.discord.com/api/webhooks/[0-9]*/?*) ;;
    *) return 1 ;;
  esac
  # No whitespace, quote, or backslash: the URL is written into a curl config
  # file, where a quote or backslash would change how curl parses the line.
  case "$url" in
    *[[:space:]]*|*'"'*|*\\*) return 1 ;;
  esac
  [ "${#url}" -le 512 ]
}

# fm_discord_api_base_valid <base>
# The inbound reads carry the bot token in an Authorization header, so the host
# they are sent to is the same safety boundary the webhook host is: only
# Discord's own API, and only its bare versioned root, so no override can
# redirect the token elsewhere or append a path of its own.
fm_discord_api_base_valid() {
  local base=${1-} rest
  case "$base" in
    https://discord.com/api*)        rest=${base#https://discord.com/api} ;;
    https://discordapp.com/api*)     rest=${base#https://discordapp.com/api} ;;
    https://canary.discord.com/api*) rest=${base#https://canary.discord.com/api} ;;
    *) return 1 ;;
  esac
  local LC_ALL=C
  [[ "$rest" =~ ^(/v[0-9]{1,3})?$ ]]
}

# fm_discord_token_valid <token>
# Discord bot tokens are dot-separated base64url. The point of the check is that
# a value carrying a newline, space, or quote could forge an extra HTTP header
# once it is written into the Authorization line of a curl config file.
fm_discord_token_valid() {
  local token=${1-}
  local LC_ALL=C
  [ -n "$token" ] || return 1
  [ "${#token}" -le 256 ] || return 1
  [[ "$token" =~ ^[A-Za-z0-9._-]+$ ]]
}

# fm_discord_snowflake_valid <id> - a Discord channel or user id.
fm_discord_snowflake_valid() {
  local id=${1-}
  local LC_ALL=C
  [[ "$id" =~ ^[0-9]{5,25}$ ]]
}

# fm_discord_resolve <what>
# what: webhook | token | channel | captain
# Loads the value into its FM_DISCORD_* variable. Returns 1 with an actionable
# FM_DISCORD_ERROR - naming the path to write, never the value - when the
# setting is absent or malformed.
# shellcheck disable=SC2034  # the FM_DISCORD_* globals are read by the sourcing entrypoints.
fm_discord_resolve() {
  local what=$1 dir value envname file
  dir=$(fm_discord_config_dir)
  FM_DISCORD_ERROR=
  case "$what" in
    webhook) envname=FM_DISCORD_WEBHOOK_URL; file=discord-webhook ;;
    token)   envname=FM_DISCORD_BOT_TOKEN;   file=discord-bot-token ;;
    channel) envname=FM_DISCORD_CHANNEL_ID;  file=discord-channel ;;
    captain) envname=FM_DISCORD_CAPTAIN_ID;  file=discord-captain ;;
    *) FM_DISCORD_ERROR="unknown discord setting: $what"; return 1 ;;
  esac
  value=${!envname-}
  if [ -z "$value" ]; then
    value=$(fm_discord_read_setting "$dir" "$file")
  fi
  if [ -z "$value" ]; then
    FM_DISCORD_ERROR="discord $what is not configured: write it to $dir/$file (gitignored) or set $envname"
    return 1
  fi
  case "$what" in
    webhook)
      fm_discord_webhook_valid "$value" || {
        FM_DISCORD_ERROR="discord webhook in $dir/$file is not a https://discord.com/api/webhooks/... URL"
        return 1
      }
      FM_DISCORD_WEBHOOK=$value ;;
    token)
      fm_discord_token_valid "$value" || {
        FM_DISCORD_ERROR="discord bot token in $dir/$file is not a well-formed token"
        return 1
      }
      FM_DISCORD_TOKEN=$value ;;
    channel)
      fm_discord_snowflake_valid "$value" || {
        FM_DISCORD_ERROR="discord channel id in $dir/$file is not a snowflake"
        return 1
      }
      FM_DISCORD_CHANNEL=$value ;;
    captain)
      fm_discord_snowflake_valid "$value" || {
        FM_DISCORD_ERROR="discord captain id in $dir/$file is not a snowflake"
        return 1
      }
      FM_DISCORD_CAPTAIN=$value ;;
  esac
  return 0
}

# fm_discord_budget - the working per-message character budget.
# Clamped into [50, 2000] because Discord's ceiling is hard and a budget below
# a line of text cannot carry a receipt.
fm_discord_budget() {
  local raw=${FM_DISCORD_MAX_CHARS-}
  case "$raw" in ''|*[!0-9]*) raw=$FM_DISCORD_DEFAULT_BUDGET ;; esac
  while [ "${#raw}" -gt 1 ] && [ "${raw:0:1}" = 0 ]; do raw=${raw:1}; done
  [ "${#raw}" -le 4 ] || raw=$FM_DISCORD_HARD_CEILING
  [ "$raw" -ge 50 ] 2>/dev/null || raw=50
  [ "$raw" -le "$FM_DISCORD_HARD_CEILING" ] 2>/dev/null || raw=$FM_DISCORD_HARD_CEILING
  printf '%s\n' "$raw"
}

# fm_discord_truncate <text> <budget>
# Print <text> shortened to at most <budget> characters, marking that it was cut
# so a reader never mistakes a truncated line for the whole outcome. Returns 1
# and prints nothing when the budget cannot hold the marker and at least one
# character of text, because an unmarked stub is a wrong value with no error.
fm_discord_truncate() {
  local text=$1 budget=$2 marker=' [...]'
  [ "${#text}" -le "$budget" ] && { printf '%s' "$text"; return 0; }
  local keep=$(( budget - ${#marker} ))
  [ "$keep" -ge 1 ] || return 1
  printf '%s%s' "${text:0:keep}" "$marker"
}
