# Managed by Ansible (roles/admin/files/homelab.fish)
fish_add_path -g /usr/local/sbin /usr/sbin /sbin

if status is-interactive
    set -g fish_greeting
    set -gx EDITOR vi

    abbr -a dc   docker compose
    abbr -a dcl  docker compose logs -f --tail 100
    abbr -a dps  'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
    abbr -a jf   journalctl -f -u
    abbr -a gpu  watch -n1 nvidia-smi
    abbr -a stacks cd /opt/stacks
end
