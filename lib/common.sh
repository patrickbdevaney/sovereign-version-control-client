# Shared helpers for the forge-* scripts. Sourced, not executed.
# shellcheck shell=bash

set -euo pipefail

# --- output -----------------------------------------------------------------

if [ -t 1 ]; then
    _c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'
    _c_dim=$'\033[2m';  _c_bld=$'\033[1m';  _c_off=$'\033[0m'
else
    _c_red=''; _c_grn=''; _c_ylw=''; _c_dim=''; _c_bld=''; _c_off=''
fi

info() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$_c_bld" "$_c_off" "$*"; }
ok()   { printf '%s  ok%s  %s\n' "$_c_grn" "$_c_off" "$*"; }
warn() { printf '%swarn%s  %s\n' "$_c_ylw" "$_c_off" "$*" >&2; }
dim()  { printf '%s%s%s\n' "$_c_dim" "$*" "$_c_off"; }
die()  { printf '%sfail%s  %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

# --- config -----------------------------------------------------------------

# Search order: $FORGE_CONF, ./forge.conf, ~/.config/forge/forge.conf
forge_config_path() {
    local candidate
    for candidate in \
        "${FORGE_CONF:-}" \
        "$PWD/forge.conf" \
        "$HOME/.config/forge/forge.conf"
    do
        [ -n "$candidate" ] && [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

load_config() {
    local conf
    conf="$(forge_config_path)" || die "no forge.conf found.
Copy forge.conf.example to ~/.config/forge/forge.conf and fill it in."

    # shellcheck disable=SC1090
    source "$conf"
    FORGE_CONF_USED="$conf"

    : "${FORGE_HOST:?FORGE_HOST is not set in $conf}"
    : "${FORGE_USER:?FORGE_USER is not set in $conf}"
    FORGE_SSH_PORT="${FORGE_SSH_PORT:-2222}"
    FORGE_ALIAS="${FORGE_ALIAS:-forge}"
    FORGE_KEY="${FORGE_KEY:-$HOME/.ssh/id_ed25519_forge}"
    FORGE_LAN_HOST="${FORGE_LAN_HOST:-}"
    FORGE_TOKEN_FILE="${FORGE_TOKEN_FILE:-$HOME/.config/forge/token}"
    FORGE_DEFAULT_VISIBILITY="${FORGE_DEFAULT_VISIBILITY:-private}"

    FORGE_API="https://${FORGE_HOST}/api/v1"
}

# --- api --------------------------------------------------------------------

# Credentials are passed to curl through a mode-600 config file rather than
# argv, so they never appear in `ps` output or shell history.
_auth_file=""

_cleanup_auth() {
    [ -n "$_auth_file" ] && [ -f "$_auth_file" ] && rm -f "$_auth_file"
    _auth_file=""
}
trap _cleanup_auth EXIT INT TERM

# Builds the curl config file holding the credential. Prefers a token file;
# falls back to prompting for a password on the terminal.
init_auth() {
    [ -n "$_auth_file" ] && return 0

    _auth_file="$(mktemp "${TMPDIR:-/tmp}/forge-auth.XXXXXX")"
    chmod 600 "$_auth_file"

    local token_path="${FORGE_TOKEN_FILE/#\~/$HOME}"
    if [ -f "$token_path" ]; then
        local perms
        perms="$(stat -c '%a' "$token_path" 2>/dev/null || stat -f '%Lp' "$token_path")"
        [ "$perms" = "600" ] || warn "$token_path is mode $perms; should be 600"

        local token
        token="$(tr -d '[:space:]' < "$token_path")"
        [ -n "$token" ] || die "token file $token_path is empty"
        printf 'header = "Authorization: token %s"\n' "$token" > "$_auth_file"
        FORGE_AUTH_KIND="token"
    else
        [ -t 0 ] || die "no token at $token_path and no terminal to prompt on.
Create a token at https://${FORGE_HOST}/user/settings/applications
(scopes: write:user, write:repository) and save it there, mode 600."

        local pass
        printf 'Forgejo password for %s@%s: ' "$FORGE_USER" "$FORGE_HOST" >&2
        read -rs pass; printf '\n' >&2
        [ -n "$pass" ] || die "empty password"
        printf 'user = "%s:%s"\n' "$FORGE_USER" "$pass" > "$_auth_file"
        unset pass
        FORGE_AUTH_KIND="password"
    fi
}

# api <METHOD> <path> [json-body-file]
#
# Prints the HTTP status on the first line, then the response body. Callers are
# expected to be capturing this in $(...), which runs in a subshell — so the
# status cannot be handed back in a variable. It has to travel in the output.
# Use resp_code / resp_body to take it apart.
api() {
    local method="$1" path="$2" body="${3:-}"
    init_auth

    local args=( -sS --config "$_auth_file"
                 -X "$method"
                 -w '\n%{http_code}'
                 -H 'Accept: application/json' )
    if [ -n "$body" ]; then
        args+=( -H 'Content-Type: application/json' --data "@$body" )
    fi

    local raw
    if ! raw="$(curl "${args[@]}" "${FORGE_API}${path}")"; then
        printf '000\n'
        return 0
    fi

    printf '%s\n%s' "${raw##*$'\n'}" "${raw%$'\n'*}"
}

# resp_code <captured-api-output>
resp_code() { printf '%s' "${1%%$'\n'*}"; }

# resp_body <captured-api-output>
resp_body() {
    case "$1" in
        *$'\n'*) printf '%s' "${1#*$'\n'}" ;;
        *)       printf '' ;;
    esac
}

# Reads a top-level string field out of a JSON blob without needing jq.
json_field() {
    local field="$1"
    python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1]) if isinstance(d, dict) else None
print("" if v is None else v)
' "$field" 2>/dev/null || true
}

# --- misc -------------------------------------------------------------------

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

expand_tilde() { printf '%s\n' "${1/#\~/$HOME}"; }

ssh_url() { printf '%s:%s/%s.git\n' "$FORGE_ALIAS" "$FORGE_USER" "$1"; }

web_url() { printf 'https://%s/%s/%s\n' "$FORGE_HOST" "$FORGE_USER" "$1"; }
