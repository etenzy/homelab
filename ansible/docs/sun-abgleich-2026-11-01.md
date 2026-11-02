# Abgleich sun ↔ Ansible (2026-11-01)

Nur lesender Vergleich: `site.yml --limit sun --check --diff` von Michaels Mac plus SSH-Abgleich.
Auf sun wurde nichts geändert. Der Check brach bei `postgresql : Databases` ab (sudo, siehe unten),
der Rest wurde per SSH gegen die Rollen verglichen.

## Bereits im Ansible-Setup behoben

| Fund | Änderung |
|---|---|
| Blocky schreibt per TCP mit Passwort (`127.0.0.1:5432`, `sslmode=require`). Die generierte `pg_hba.conf` hätte das gesperrt, das Query-Log wäre ausgefallen. | Blocky verbindet jetzt per Socket + peer (`postgres:///blocky?host=/run/postgresql&user=blocky`), kein Passwort mehr in `config.yml` |
| Owner der DB `blocky` ist schon `blocky` | `owner: blocky` aktiviert |
| PGDG-Repo hätte PostgreSQL von Debian 17.11 auf PGDG umgestellt, das Meta-Paket `postgresql` könnte 18 nachziehen | `postgresql_pgdg: false` (Default): Debian-Paket bleibt. Mit `true` werden die Meta-Pakete gegen PGDG gepinnt |
| `update-postgres_exporter` hatte live `After=blocky.service` (DNS über Blocky) | auf Blocky-Hosts wieder gesetzt |
| `-e postgresql_allow_restart=false` kam als String an und ließ den Handler scheitern | Handler nutzen `| bool` |

## Offen, braucht deine Entscheidung

- **Valkey `default`-User ohne Passwort mit allen Rechten**, heute schon über 10.1.0.2 erreichbar.
  Mit dem neuen `bind` käme die ULA `fd00:10:1::2` dazu. Vorschlag: `default` deaktivieren oder
  Passwort setzen, bevor der Valkey-Teil läuft. Redis_exporter nutzt heute nur `REDIS_ADDR`, bräuchte
  dann User/Passwort.
- **Valkey-ACL inline in `valkey.conf`** (blocky, default). Kein `users.acl` vorhanden, deshalb setzt
  die Rolle kein `aclfile`. Kommt später eine `users.acl` nach host_files, startet Valkey nicht mehr
  (inline-User und aclfile schließen sich aus): dann die inline-User aus `valkey.conf` entfernen.
- **Unverschlüsselte Secrets auf dem Mac:** beide `vault.yml` (DB-Passwörter, Cloudflare-Token) und
  `host_files/sun/etc/valkey/valkey.conf` (ACL-Hash) liegen im Klartext:
  `ansible-vault encrypt inventory/group_vars/all/vault.yml inventory/host_vars/sun/vault.yml host_files/sun/etc/valkey/valkey.conf`
- **sudoers:** live `/etc/sudoers.d/mroedel` mit `mroedel ALL=NOPASSWD: ALL` (gilt nur für root). Die
  Rolle `admin` legt `10-mroedel` mit `(ALL:ALL)` an, die alte Datei bleibt doppelt liegen. Eine
  Regel `blockyusr` zeigt auf eine nicht existierende Gruppe (tot). Für einen vollständigen Check
  zuerst `--tags admin` echt laufen lassen.

## Was ein echter Lauf ändern würde

**base:** `debian.sources` (deb.debian.org per https, **trixie-security wird aktiviert**, live
auskommentiert), `sources.list` geleert (bisher ftp.de + deb-src), sysctl `ip_nonlocal_bind`, Pakete
jq/ncdu/tmux/unattended-upgrades + `20auto-upgrades`. Netz und timesyncd bleiben unberührt.

**admin:** Login-Shell bash → fish, GitHub-Key `…5IMP` dazu (vorhandene Keys bleiben, Kommentare
fallen weg), `sudoers.d/10-mroedel`, `sshd_config.d/10-hardening.conf` (neu effektiv nur
`AllowUsers mroedel`), sshd reload.

**node_exporter:** auf sun nicht installiert, wird komplett neu angelegt.

**chrony_server:** inhaltlich gleich, `authselectmode`/`minsources` wandern nach `server.conf`.
chrony und chrony_exporter werden neu gestartet.

**postgresql:** `conf.d/listen.conf` neu (gleicher Wert wie `postgresql.conf`), meldet einmalig
„Restart pending“ ohne echte Änderung. `postgresql.conf` identisch. Rollen existieren alle;
`postgres_exporter` `search_path` wird `pg_catalog, public`. In `pg_hba.conf` fallen weg:
`local all all peer`, `host all all 127.0.0.1/32` und `::1/128`, die 3 Replication-Zeilen.
Abgedeckt sind blocky (jetzt auch TCP), grafana, mroedel, postgres_exporter.

**blocky:** `config.yml` und alle 8 Listen identisch. `blocky.service` ändert Header und
`WorkingDirectory` (`/var/lib/blocky`, per `StateDirectory`), löst also **einen Restart aus (kurzer
DNS-Aussetzer)**. `/opt/blocky` wird nicht mehr verwendet; es gehört live UID 1001 und enthält nur
Altlasten (altes Binary, Tarball, alte config.yml). Das Home des Users (`/home/blocky`) setzt Ansible
nur beim Anlegen; zum Umstellen manuell:
`systemctl stop blocky && usermod -d /var/lib/blocky blocky && systemctl start blocky`,
danach `rm -rf /opt/blocky /home/blocky` (vorher Inhalt prüfen).
Rechte der Listen/Config werden 640/750. **Der Purge läuft live gerade nicht** (Permission denied auf
`/usr/local/lib/blocky/purge-domains.sql`, postgres:postgres); Ansible behebt das.

**valkey:** `valkey.conf` identisch. Neu `conf.d/` + Include-Zeile, `bind` neu mit IPv6-ULA,
Valkey-Restart. redis_exporter: Env-Rechte 640, Unit mit `After=valkey-server.service`, Restart.

## Empfohlene Reihenfolge

1. Secrets verschlüsseln, Valkey-`default`-User klären.
2. `--tags base,admin` echt (danach geht `sudo -u postgres` ohne Passwort).
3. Erneut `--check --diff`, dann Rolle für Rolle; Blocky und Valkey in einem ruhigen Moment (Restarts).
