#!/usr/bin/env bash
# Shared helpers for install.sh / uninstall.sh. Sourced, not executed.
# shellcheck disable=SC2034  # variables are set for the calling script

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
TF_DIR="$REPO_DIR/terraform"
TFVARS="$TF_DIR/terraform.tfvars"
BACKEND="$TF_DIR/backend.hcl"
SSH_KEY="$HOME/.ssh/syslog_admin"

if [ -t 1 ]; then
  C_B=$'\e[1m'; C_BLUE=$'\e[1;34m'; C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_GRN=$'\e[32m'; C_0=$'\e[0m'
else
  C_B=""; C_BLUE=""; C_RED=""; C_YEL=""; C_GRN=""; C_0=""
fi

# Keep the caller's real stdin on fd 3: menus read their items from a pipe,
# so answers must come from here.
exec 3<&0

hdr()  { printf '\n%s== %s ==%s\n' "$C_BLUE" "$*" "$C_0"; }
info() { printf '%s\n' "$*"; }
ok()   { printf '%s✔ %s%s\n' "$C_GRN" "$*" "$C_0"; }
warn() { printf '%s! %s%s\n' "$C_YEL" "$*" "$C_0" >&2; }
die()  { printf '%sERROR: %s%s\n' "$C_RED" "$*" "$C_0" >&2; exit 1; }

# ask VAR "Prompt" [default]
ask() {
  local __var=$1 __prompt=$2 __def=${3:-} __ans
  if [ -n "$__def" ]; then
    read -r -u 3 -p "$__prompt [$__def]: " __ans || die "Input ended while asking: $__prompt"
    __ans=${__ans:-$__def}
  else
    read -r -u 3 -p "$__prompt: " __ans || die "Input ended while asking: $__prompt"
  fi
  printf -v "$__var" '%s' "$__ans"
}

# ask_required VAR "Prompt" [default]
ask_required() {
  local __var=$1
  while :; do
    ask "$@"
    [ -n "${!__var}" ] && return 0
    warn "A value is required."
  done
}

# ask_yn VAR "Question" y|n  -> sets VAR to true/false
ask_yn() {
  local __var=$1 __prompt=$2 __def=${3:-n} __ans
  while :; do
    read -r -u 3 -p "$__prompt [$( [ "$__def" = y ] && echo Y/n || echo y/N )]: " __ans || die "Input ended while asking: $__prompt"
    __ans=${__ans:-$__def}
    case "$__ans" in
      [Yy]*) printf -v "$__var" true; return 0 ;;
      [Nn]*) printf -v "$__var" false; return 0 ;;
    esac
  done
}

# ask_int VAR "Prompt" default min max
ask_int() {
  local __var=$1 __prompt=$2 __def=$3 __min=$4 __max=$5
  while :; do
    ask "$__var" "$__prompt" "$__def"
    if [[ "${!__var}" =~ ^[0-9]+$ ]] && [ "${!__var}" -ge "$__min" ] && [ "${!__var}" -le "$__max" ]; then
      return 0
    fi
    warn "Enter a whole number between $__min and $__max."
  done
}

# pick VAR "Prompt" optional(true|false) < lines   (TAB-separated; first column is shown first)
# Sets VAR to the chosen line, or "" when optional and skipped.
pick() {
  local __var=$1 __prompt=$2 __optional=$3 __lines=() __line __i __ans
  while IFS= read -r __line || [ -n "$__line" ]; do
    [ -n "$__line" ] && __lines+=("$__line")
  done
  if [ "${#__lines[@]}" -eq 0 ]; then
    if [ "$__optional" = true ]; then printf -v "$__var" ''; return 0; fi
    die "Nothing found for: $__prompt"
  fi
  info "$C_B$__prompt$C_0"
  for __i in "${!__lines[@]}"; do
    printf '  %2d) %s\n' "$((__i + 1))" "$(printf '%s' "${__lines[$__i]}" | tr '\t' ' ' | sed 's/  */  /g')"
  done
  [ "$__optional" = true ] && printf '   0) none / skip\n'
  while :; do
    read -r -u 3 -p "Choose [1-${#__lines[@]}]: " __ans || die "Input ended while choosing: $__prompt"
    if [ "$__optional" = true ] && [ "$__ans" = 0 ]; then printf -v "$__var" ''; return 0; fi
    if [[ "$__ans" =~ ^[0-9]+$ ]] && [ "$__ans" -ge 1 ] && [ "$__ans" -le "${#__lines[@]}" ]; then
      printf -v "$__var" '%s' "${__lines[$((__ans - 1))]}"
      return 0
    fi
  done
}

col() { printf '%s' "$1" | cut -f"$2"; }

# ---- IP helpers (python3 ipaddress) ---------------------------------------
# norm_cidr "10.1.2.3/16" -> "10.1.0.0/16"; fails for invalid, IPv6 or /0
norm_cidr() {
  python3 -c '
import ipaddress, sys
n = ipaddress.ip_network(sys.argv[1].strip(), strict=False)
if n.version != 4 or n.prefixlen == 0:
    sys.exit(1)
print(n)' "$1" 2>/dev/null
}

# ip_usable_in IP SUBNET -> 0 if IP is a usable Azure address in SUBNET
# (Azure reserves the first four addresses and the last one).
ip_usable_in() {
  python3 -c '
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1].strip())
n = ipaddress.ip_network(sys.argv[2], strict=False)
off = int(ip) - int(n.network_address)
sys.exit(0 if ip in n and 4 <= off <= n.num_addresses - 2 else 1)' "$1" "$2" 2>/dev/null
}

# ask_cidr_list VAR "Prompt" default required(true|false)
# Comma-separated IPv4 CIDRs (bare IPs become /32). Normalised and de-duplicated.
ask_cidr_list() {
  local __var=$1 __prompt=$2 __def=$3 __req=$4 __raw __item __n __out __bad
  while :; do
    ask __raw "$__prompt (comma-separated)" "$__def"
    __out=""; __bad=""
    IFS=',' read -r -a __items <<< "$__raw"
    for __item in ${__items[@]+"${__items[@]}"}; do
      __item=$(printf '%s' "$__item" | tr -d '[:space:]')
      [ -z "$__item" ] && continue
      [[ "$__item" == */* ]] || __item="$__item/32"
      if __n=$(norm_cidr "$__item"); then
        [ "$__n" = "$__item" ] || [ "$__item" = "${__n%/32}/32" ] || warn "$__item is not a network boundary - using $__n"
        [[ ",$__out," == *",$__n,"* ]] || __out="${__out:+$__out,}$__n"
      else
        __bad="${__bad:+$__bad, }$__item"
      fi
    done
    if [ -n "$__bad" ]; then warn "Invalid or not allowed (IPv4 only, no 0.0.0.0/0): $__bad"; continue; fi
    if [ "$__req" = true ] && [ -z "$__out" ]; then warn "At least one CIDR is required."; continue; fi
    printf -v "$__var" '%s' "$__out"
    [ -n "$__out" ] && info "  using: $__out"
    return 0
  done
}

# ask_ip_in_subnet VAR "Prompt" SUBNET_PREFIX "taken,ips"   (blank = dynamic)
ask_ip_in_subnet() {
  local __var=$1 __prompt=$2 __subnet=$3 __taken=${4:-} __ip
  while :; do
    ask __ip "$__prompt (blank = dynamic)" ""
    __ip=$(printf '%s' "$__ip" | tr -d '[:space:]')
    if [ -z "$__ip" ]; then printf -v "$__var" ''; return 0; fi
    if ! ip_usable_in "$__ip" "$__subnet"; then
      warn "$__ip is not a usable address in $__subnet (Azure reserves the first 4 and the last)."; continue
    fi
    if [[ ",$__taken," == *",$__ip,"* ]]; then warn "$__ip is already used above."; continue; fi
    printf -v "$__var" '%s' "$__ip"; return 0
  done
}

# "a,b" -> ["a", "b"]
hcl_list() {
  local IFS=',' __x __out=""
  for __x in $1; do __out+="\"$__x\", "; done
  printf '[%s]' "${__out%, }"
}

# HCL string or null
hcl_str() { if [ -n "$1" ]; then printf '"%s"' "$1"; else printf 'null'; fi; }

require_tools() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "'$t' is not installed. Run this from Azure Cloud Shell (bash)."; done
}

require_login() {
  az account show >/dev/null 2>&1 || die "Not signed in to Azure. Cloud Shell signs you in automatically; elsewhere run 'az login'."
}

tf() { terraform -chdir="$TF_DIR" "$@"; }
