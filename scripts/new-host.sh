#!/usr/bin/env bash
#
# new-host.sh - add a new host to the homelab Ansible inventory.
#
#   Adds <name> to inventory/hosts.yml (always debian_hosts plus the given
#   groups), creates inventory/host_vars/<name>/vars.yml with the network block
#   and vault.yml.example, then prints the onboarding prerequisites for a
#   Debian netinstall server.
#
#   Usage: scripts/new-host.sh [-n] [-d "description"] [-g group]... <name>
#     -g group        inventory group (repeatable), e.g. -g docker_hosts
#     -d description  one-line description for the host_vars header
#     -n              dry run: show what would change, write nothing
#     -l              list the available groups and exit
#
#   Works with the bash 3.2 shipped with macOS.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
ansible_dir="$repo_root/ansible"
inventory="$ansible_dir/inventory/hosts.yml"
host_vars_root="$ansible_dir/inventory/host_vars"
domain=home.rdl.sh
admin_user=mroedel

usage() {
  cat <<EOF
Usage: $0 [-n] [-d "description"] [-g group]... <name>
       $0 -l | -h

Adds <name> to the Ansible inventory (always debian_hosts plus the given
groups), creates inventory/host_vars/<name>/ and prints the onboarding
prerequisites for a Debian netinstall server.

Options:
  -g group        inventory group, repeatable (see -l)
  -d description  one-line description for the host_vars header
  -n              dry run: show the changes, write nothing
  -l              list the available groups
  -h              show this help

Examples:
  $0 -n -g docker_hosts -d "HP Mini, Tdarr" venus
  $0 -g docker_hosts -g traefik_hosts venus
EOF
  if [[ -f "$inventory" ]]; then
    printf '\nGroups: %s\n' "$(list_groups | tr '\n' ' ')"
  fi
  exit "${1:-0}"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Group names defined in hosts.yml (keys four spaces deep under all.children).
list_groups() {
  sed -n 's/^    \([a-z_][a-z0-9_]*\):[[:space:]]*$/\1/p' "$inventory"
}

has_group() {
  list_groups | grep -qx "$1"
}

in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

dry_run=false
description=""
groups=(debian_hosts)

while getopts ":g:d:nlh" opt; do
  case $opt in
    g) in_list "$OPTARG" "${groups[@]}" || groups+=("$OPTARG") ;;
    d) description=$OPTARG ;;
    n) dry_run=true ;;
    l) list_groups; exit 0 ;;
    h) usage 0 ;;
    :) die "option -$OPTARG needs a value" ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
# No or too many arguments: show the help.
[[ $# -eq 1 ]] || usage 1
name=$1

# --- Checks --------------------------------------------------------------------------
[[ -f "$inventory" ]] || die "inventory not found: $inventory"
[[ "$name" =~ ^[a-z][a-z0-9-]{0,62}$ ]] ||
  die "invalid host name '$name' (lowercase letters, digits, '-')"
if grep -qE "^[[:space:]]+$name:[[:space:]]*$" "$inventory"; then
  die "host '$name' is already in $inventory"
fi
[[ ! -e "$host_vars_root/$name" ]] || die "$host_vars_root/$name already exists"

for group in "${groups[@]}"; do
  has_group "$group" || die "unknown group '$group' (available: $(list_groups | tr '\n' ' '))"
done

# Role dependencies (see site.yml / README).
if in_list jellyfin_hosts "${groups[@]}"; then
  if ! in_list docker_hosts "${groups[@]}" || ! in_list traefik_hosts "${groups[@]}"; then
    die "jellyfin_hosts needs docker_hosts and traefik_hosts"
  fi
fi
if in_list traefik_hosts "${groups[@]}"; then
  in_list docker_hosts "${groups[@]}" || die "traefik_hosts needs docker_hosts"
fi

# --- Inventory -----------------------------------------------------------------------
# Append "        <name>:" after the existing hosts of every selected group.
add_to_inventory() {
  awk -v host="$name" -v groups="$(printf '%s ' "${groups[@]}")" '
    BEGIN { n = split(groups, list, " "); for (i = 1; i <= n; i++) wanted[list[i]] = 1 }
    function flush() { if (inhosts) { print "        " host ":"; done[group] = 1; inhosts = 0 } }
    inhosts && !/^        [a-z0-9-]+:[[:space:]]*$/ { flush() }
    /^    [a-z_][a-z0-9_]*:[[:space:]]*$/ {
      group = $1; sub(/:$/, "", group); pending = (group in wanted)
    }
    { print }
    pending && /^      hosts:[[:space:]]*$/ { inhosts = 1; pending = 0 }
    END {
      flush()
      for (g in wanted) if (!(g in done)) { print "group without hosts: " g > "/dev/stderr"; exit 1 }
    }
  ' "$inventory"
}

new_inventory=$(add_to_inventory) || die "could not update $inventory"

# --- host_vars -----------------------------------------------------------------------
vars_content() {
  cat <<EOF
---
# $name: ${description:-<hardware, purpose>}, Debian 13.
# Only what differs from group_vars and role defaults lives here.

# --- Network (base role) ----------------------------------------------------------
# Off until the address is fixed and checked. Then e.g.:
#   network_manage: true
#   network_ipv6_addresses: ["fd00:10:73:10::<id>/64"]
# MTU: 9000 only if switch port, NAS and UDM VLAN support jumbo frames.
network_manage: false
network_ipv4: dhcp                       # static: + network_ipv4_address / _gateway
# network_ipv4_address: ""                # e.g. 10.73.10.5/24
# network_ipv4_gateway: ""                # e.g. 10.73.10.1
network_ipv6_addresses: []
network_ipv6_accept_ra: true             # default route + RDNSS from the UDM
network_ipv6_slaac: false                # true: own GUA from the RA prefix (no NAT66 via UDM)
network_ipv6_token: ""                   # with slaac: fixed interface ID, e.g. "::5"
network_ipv6_privacy: false              # with slaac: temporary addresses for outgoing traffic
network_mtu: ""
network_dns: []                          # empty: leave /etc/resolv.conf alone
EOF
  if in_list docker_hosts "${groups[@]}"; then
    cat <<'EOF'
docker_mtu: ""                           # only for host MTU < 1500 (roles/docker/defaults)
EOF
  fi
}

vault_example_content() {
  cat <<EOF
---
# Secrets for $name only. Copy to vault.yml, fill in, then:
#   ansible-vault encrypt inventory/host_vars/$name/vault.yml
# Keep this file valid YAML even without entries.
{}
EOF
}

if $dry_run; then
  printf '== dry run: %s\n\n' "$name"
  printf -- '-- inventory/hosts.yml (diff)\n'
  diff -u "$inventory" <(printf '%s\n' "$new_inventory") || true
  printf '\n-- inventory/host_vars/%s/vars.yml\n' "$name"
  vars_content
  printf '\n-- inventory/host_vars/%s/vault.yml.example\n' "$name"
  vault_example_content
else
  printf '%s\n' "$new_inventory" >"$inventory"
  mkdir -p "$host_vars_root/$name"
  vars_content >"$host_vars_root/$name/vars.yml"
  vault_example_content >"$host_vars_root/$name/vault.yml.example"
  printf 'Added %s to: %s\n' "$name" "${groups[*]}"
  printf 'Created inventory/host_vars/%s/{vars.yml,vault.yml.example}\n' "$name"
  if command -v ansible-inventory >/dev/null 2>&1; then
    (cd "$ansible_dir" && ansible-inventory --host "$name" >/dev/null) ||
      die "ansible-inventory cannot parse the inventory, check $inventory"
    printf 'ansible-inventory: OK\n'
  fi
fi

# --- Onboarding prerequisites --------------------------------------------------------
fqdn="$name.$domain"
cat <<EOF

========================================================================
 Onboarding prerequisites for $fqdn (Debian 13 netinstall)
========================================================================

UniFi
  [ ] DHCP reservation for the MAC in the right VLAN.
  [ ] DNS record $fqdn (A, plus AAAA if the host gets a static ULA).
  [ ] Firewall: SSH from the admin networks; Prometheus (earth) -> :9100
      and any other exporter ports.

Debian installer (netinstall ISO, e.g. from the Ventoy stick)
  [ ] Hostname "$name", domain "$domain".
  [ ] Root password: leave EMPTY. Root stays locked, sudo gets installed
      and the first user ends up in the sudo group.
  [ ] First user: $admin_user.
  [ ] Software selection: only "SSH server" and "standard system
      utilities", no desktop environment.
  [ ] GPU hosts: decide on Secure Boot (off = no MOK enrolment).

First boot (console)
  [ ] Root password was set anyway?
        su -c 'apt install -y sudo && usermod -aG sudo $admin_user'
      then log out and back in.
  [ ] python3 present:  sudo apt install -y python3

Controller (this Mac)
  [ ] SSH works:        ssh $admin_user@$fqdn
  [ ] Key login before the first run (avoids sshpass for -k):
        ssh-copy-id $admin_user@$fqdn
      The admin role then takes the keys from github.com/etenzy.keys and
      disables password login.
  [ ] Host groups and host_vars reviewed: inventory/hosts.yml,
      inventory/host_vars/$name/vars.yml.
  [ ] Secrets needed? cp vault.yml.example vault.yml, fill in, then
        ansible-vault encrypt inventory/host_vars/$name/vault.yml
      (the pre-commit hook rejects unencrypted vault.yml files).
  [ ] Dry run, then first run (sudo password once via -K):
        cd ansible
        ansible-playbook site.yml --limit $name -K --check --diff
        ansible-playbook site.yml --limit $name -K
      (plus --ask-vault-pass unless vault_password_file is set)
  [ ] Prometheus: add the targets to ansible/prometheus/scrape-hosts.yml.
EOF
