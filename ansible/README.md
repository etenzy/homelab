# Ansible fürs Homelab

Stand: 2026-11-01. Ein Ansible-Setup für alle Hosts unter `home.rdl.sh`. Welche Rollen ein
Host bekommt, steht allein im Inventory über seine Gruppen. Aktuell verwaltet:

- **mars** (HP EliteDesk 800 G3 SFF, RTX A400): Docker, Traefik, Jellyfin
- **sun** (PC Engines apu3, Debian 13.7): Blocky, chrony/NTS, PostgreSQL 17, Valkey, alles nativ ohne Docker

earth ist als Kommentar vorbereitet.

Code, Kommentare und Task-Namen sind auf Englisch, diese Doku auf Deutsch.

## Aufbau

```
ansible/
├── ansible.cfg, requirements.yml, .ansible-lint
├── site.yml                        # ein Playbook, ein Play pro Gruppe
├── fetch-host-files.yml            # holt Live-Configs eines Hosts nach host_files/
├── inventory/
│   ├── hosts.yml                   # Hosts und Gruppen
│   ├── group_vars/
│   │   ├── all/vars.yml            # homelab-weit: Domain, Admin, NTP, Netze, NAS, Prometheus
│   │   ├── all/vault.yml           # homelab-weite Secrets (ACME, Cloudflare, NAS, Dashboard)
│   │   └── docker_hosts/vars.yml   # Docker-Netz traefik, feste Traefik-IPs
│   └── host_vars/<host>/           # nur was der Host von allem anderen unterscheidet
├── host_files/<host>/              # Configs, die 1:1 vom Host stammen (Blocky, PostgreSQL, Valkey)
├── roles/<rolle>/defaults/         # Versionen und technische Standardwerte je Rolle
└── prometheus/                     # Snippets für Prometheus auf earth (kein Ansible)
```

Variablen-Reihenfolge (später gewinnt): Rollen-Defaults → `group_vars/all` →
`group_vars/<gruppe>` → `host_vars/<host>`. Versionen stehen in den Rollen-Defaults und gelten
damit für alle Hosts. Ein einzelner Host kann sie in seinen `host_vars` übersteuern.

`ansible_host` (`<name>.home.rdl.sh`) und `ansible_user` (`mroedel`) werden in
`group_vars/all` abgeleitet. Ein neuer Host braucht deshalb meist nur seinen Namen in den
passenden Gruppen. `nvidia_enabled` ist automatisch `true`, wenn der Host in `gpu_hosts` ist.

## Gruppen und Rollen

| Gruppe | Rollen | Inhalt | Hosts |
|---|---|---|---|
| `debian_hosts` | `base` | prüft auf Debian 13, Hostname, Zeitzone, APT-Quellen (deb822 mit `contrib non-free non-free-firmware`), Pakete, unattended-upgrades (nur Security, kein Auto-Reboot), `systemd-timesyncd` mit `time.home.rdl.sh` (nicht auf `chrony_servers`) | mars |
| | `admin` | User `mroedel` mit **fish** als Login-Shell, SSH-Keys von `github.com/etenzy.keys`, **sudoers** (`/etc/sudoers.d/10-mroedel`, mit `visudo` geprüft), sshd-Härtung (kein root, kein Passwort, `AllowUsers`) | |
| `gpu_hosts` | `nvidia` | Open Kernel Modules, GSP-Firmware, persistenced, Secure-Boot/MOK-Prüfung, Reboot, NVIDIA Container Toolkit 1.20.1 | mars |
| `docker_hosts` | `docker` | Docker CE aus dem offiziellen Repo, `daemon.json` (userland-proxy aus, nvidia-Runtime auf GPU-Hosts, Log-Rotation), Dual-Stack-Netz `traefik` | mars |
| | `monitoring` | node_exporter (:9100, mit systemd-Collector), auf GPU-Hosts zusätzlich nvidia_gpu_exporter (:9835) | |
| `traefik_hosts` | `traefik` | Traefik mit einem Zertifikat pro Hostname, Block-Router, `redirect-to-https@file`, Dashboard unter `traefik-<host>.home.rdl.sh`, Metrics-Entrypoint :8082 | mars |
| `jellyfin_hosts` | `jellyfin` | NAS-Freigaben als Docker-Volumes (NFS/CIFS), Jellyfin mit NVENC, jellyfin-exporter (:9594). Setzt `docker_hosts` und `traefik_hosts` voraus | mars |
| `debian_hosts` ohne `docker_hosts` | `node_exporter` | node_exporter als Binary mit systemd (:9100), systemd-Collector, Textfile-Collector unter `/var/lib/prometheus/node-exporter` | sun |
| `chrony_servers` | `chrony_server` | NTP-Server mit NTS-Quellen (PTB), `authselectmode require`, `minsources 2`, Orphan-Modus; chrony_exporter (:9123) | sun |
| `postgresql_hosts` | `postgresql` | PostgreSQL 17 aus Debian (PGDG optional per `postgresql_pgdg`, Meta-Pakete dann gepinnt), `postgresql.conf` aus `host_files`, dazu `listen.conf` und `pg_stat_statements.conf` in `conf.d`; Datenbanken, Benutzer, Rechte und `pg_hba.conf` aus `postgresql_databases`/`postgresql_users`, Passwörter aus dem Vault; postgres_exporter (:9187) | sun |
| `blocky_hosts` | `blocky` | Blocky als Binary, Config aus `host_files` (vor dem Kopieren mit `blocky validate` geprüft), Wartungs-Timer für Partitionen und Domain-Purge (Domains aus dem Vault) | sun |
| `valkey_hosts` | `valkey` | Valkey aus dem Debian-Paket, `valkey.conf` bleibt Paket-Default plus Include `conf.d/homelab.conf` (bind aus den Host-IPs, `valkey_settings`), ACL aus `host_files`, redis_exporter (:9121) | sun |

Alle Binaries auf sun (blocky, node_exporter, chrony_exporter, postgres_exporter,
redis_exporter) installiert die Hilfsrolle `update_binary`: Sie legt die Bibliothek
`update-binary.sh`, den Wrapper `update-<name>` sowie Unit und Timer an und installiert das
Binary nur, wenn es noch fehlt. Aktualisiert wird danach weiter wöchentlich über den Timer
(Prüfsumme, Health-Check, Rollback). Ansible pinnt diese Versionen bewusst nicht, damit es
nicht gegen den Updater arbeitet. Neu ist `update-node_exporter`, nach dem Muster von
`update-chrony_exporter`.
## Neuen Host aufnehmen

Am einfachsten mit `scripts/new-host.sh` aus dem Repo-Root:

```bash
scripts/new-host.sh -l                                   # verfügbare Gruppen
scripts/new-host.sh -n -g docker_hosts -d "…" <name>     # Probelauf
scripts/new-host.sh -g docker_hosts -d "…" <name>
```

Das Script trägt den Host in `debian_hosts` und die angegebenen Gruppen ein, legt
`host_vars/<name>/vars.yml` (Netzwerk-Block) und `vault.yml.example` an und gibt am Ende die
Voraussetzungen für das Onboarding (Debian-Netinstall) als Checkliste aus. Von Hand:

1. Debian 13 installieren (ohne Desktop, mit SSH-Server, User `mroedel`), DHCP-Reservierung
   und DNS-Eintrag `<name>.home.rdl.sh` in UniFi anlegen.
2. Den Namen in `inventory/hosts.yml` in die passenden Gruppen eintragen.
3. Nur falls nötig: `inventory/host_vars/<name>/vars.yml` (und `vault.yml`) anlegen.
4. Erster Lauf: `ansible-playbook site.yml --limit <name> -k -K --ask-vault-pass`.
5. Scrape-Targets in `prometheus/scrape-hosts.yml` ergänzen.

## sun übernehmen

sun wurde von Hand eingerichtet. Damit der erste Lauf nichts kaputt macht:

1. **Debian-Version:** sun läuft auf Debian 13.7 (trixie, geprüft am 2026-11-01), passt
   also zur Rolle `base`. `valkey-server` kommt dort aus trixie/main. Prüfen, ob Valkey
   heute auch so installiert ist, sonst `valkey_package` in `host_vars/sun` anpassen.
2. **Login prüfen.** Die Rolle `admin` setzt `AllowUsers mroedel`, `PermitRootLogin no` und
   kein Passwort-Login. Vorher sicherstellen, dass du dich als `mroedel` mit Key anmelden
   kannst, sonst sperrst du dich aus.
3. **Live-Configs holen:**
   ```bash
   ansible-playbook fetch-host-files.yml --limit sun --ask-vault-pass
   ```
   Das legt `host_files/sun/etc/blocky/config.yml`, die Ordner `allowlists/` und `denylists/`, `postgresql.conf`, `pg_hba.conf`,
   die Valkey-Configs und die redis_exporter-Env ab (fehlende Dateien werden übersprungen).
   `purge-domains.sql` wird nicht mehr geholt: Die Rolle erzeugt die Datei aus
   `vault_blocky_purge_patterns` in `host_vars/sun/vault.yml` (LIKE-Muster, Zeitfenster
   `blocky_purge_window`, Standard 4 Stunden). Die Muster aus der alten Datei einmal dorthin
   übertragen (`cat /usr/local/lib/blocky/purge-domains.sql` auf sun).
   Dateien mit Passwörtern danach verschlüsseln (siehe `host_files/README.md`). Pfade, die auf
   sun anders heißen (z. B. die Valkey-ACL), in `host_vars/sun/vars.yml` unter
   `host_files_fetch` und `valkey_aclfile` korrigieren. Die geholte `valkey.conf` ist nur
   Referenz: Eigene Änderungen daraus nach `valkey_settings` übernehmen und die Datei auf sun
   am besten wieder auf den Paket-Default zurücksetzen. Die Rolle hängt nur
   `include /etc/valkey/conf.d/*.conf` an, das Include gewinnt bei doppelten Einstellungen.
4. **`postgresql.conf` prüfen:** Die Datei muss `include_dir = 'conf.d'` behalten (Debian-
   Standard, die Rolle prüft das). `listen_addresses` und `shared_preload_libraries` setzen
   die Snippets in `conf.d`, die nach `postgresql.conf` gelesen werden und gewinnen. Stehen
   die beiden dort auch, dort entfernen oder angleichen, damit es nur eine Quelle gibt.
5. **`pg_hba.conf` abgleichen:** Die Datei wird jetzt aus `postgresql_users` (Feld `hba`) und
   `postgresql_hba_extra` in `host_vars/sun/vars.yml` erzeugt. Die geholte Live-Datei unter
   `host_files/sun/etc/postgresql/17/main/pg_hba.conf` ist nur noch Referenz: Jede Zeile dort,
   die du behalten willst, muss in den Vars stehen, sonst fehlt sie nach dem Lauf (vor allem:
   Wie verbindet sich Blocky selbst? Angenommen ist Socket + peer als Benutzer `blocky`).
   Passwörter kommen nach `vault_postgresql_passwords` in `host_vars/sun/vault.yml`.
6. **Probelauf mit Diff:**
   ```bash
   ansible-playbook site.yml --limit sun --check --diff --ask-vault-pass
   ```
   Im Check-Modus scheitern die Schritte, die erst ein Binary installieren, sowie die
   PostgreSQL-Abfragen. Wichtig ist der Diff der Units und Configs: Er sollte nur
   `# Ansible managed`-Kopfzeilen und bewusste Änderungen zeigen.
   Die PostgreSQL-Tasks laufen per `sudo -u postgres`. Erlaubt die bisherige sudoers-Regel
   auf sun nur root ohne Passwort (z. B. `mroedel ALL=NOPASSWD: ALL` ohne `(ALL:ALL)`),
   den Probelauf mit `-K` starten. Die Rolle `admin` setzt später `(ALL:ALL) NOPASSWD`.
7. **Echter Lauf**, am besten Rolle für Rolle:
   ```bash
   ansible-playbook site.yml --limit sun --tags base,admin --ask-vault-pass
   ansible-playbook site.yml --limit sun --tags node_exporter,chrony --ask-vault-pass
   ansible-playbook site.yml --limit sun --tags postgresql --ask-vault-pass
   ansible-playbook site.yml --limit sun --tags blocky,valkey --ask-vault-pass
   ```
   PostgreSQL wird nie automatisch neu gestartet. Ändert sich `postgresql.conf`,
   `listen.conf` oder `pg_stat_statements.conf`, meldet Ansible das nur. Neustart dann von Hand oder mit
   `-e postgresql_allow_restart=true`.
8. **UDM-Firewall:** earth (VLAN 10) → 10.1.0.2:9100/tcp für den node_exporter erlauben,
   falls die bestehende Regel für 9121/9123/9187 den Port nicht abdeckt.

Ab dann Änderungen an diesen Dateien in `host_files/sun/` bzw. in den Rollen machen und mit
`site.yml` ausrollen, nicht mehr direkt auf sun.

## Versionen (geprüft am 2026-10-31)

| Komponente | Version | Quelle |
|---|---|---|
| ansible-core / ansible | 2.21.5 / 14.5.0 | PyPI |
| community.docker / community.general / ansible.posix / community.postgresql | 5.4.0 / 13.5.0 / 2.2.2 / 4.2.0 | ansible 14.5.0 |
| Docker CE / Compose-Plugin | 29.9.2 / 5.6.1 | download.docker.com (trixie) |
| Traefik | v3.7.17 (v3.8.0 ist noch RC) | Docker Hub |
| Jellyfin | 12.4 (2026-10-26) | Docker Hub |
| rebelcore/jellyfin-exporter | v1.6.0 (2026-10-26) | Docker Hub |
| node_exporter | v1.12.1 (2026-07-14) | Docker Hub `prom/node-exporter` |
| nvidia_gpu_exporter | 1.16.0 (2026-10-25) | Docker Hub |
| NVIDIA Container Toolkit | 1.20.1 | Stand 2026-10-26, nicht erneut prüfbar |
| fish | 4.0.2 | Debian trixie/main |
| PostgreSQL | 17 (Debian trixie) | wie auf sun im Einsatz (17.11-0+deb13u1) |
| Binaries auf sun | jeweils neuestes Release | über die `update-*`-Timer, nicht gepinnt |

Image-Tags sind gepinnt. Zum Aktualisieren den Tag in `roles/<rolle>/defaults/main.yml`
hochsetzen und die Rolle erneut laufen lassen. Docker CE kommt über apt und ist nicht gepinnt.

## Voraussetzungen

1. **Host:** Debian 13 wie oben. Wurde bei der Installation ein root-Passwort gesetzt, fehlt
   `sudo`. Dann einmal an der Konsole:
   ```bash
   su -c 'apt install -y sudo python3 && usermod -aG sudo mroedel'
   ```
2. **Controller (MacBook):**
   ```bash
   pip install ansible            # 14.5.0, enthält die Collections
   ansible-galaxy collection install -r requirements.yml
   cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
   cp inventory/host_vars/mars/vault.yml.example inventory/host_vars/mars/vault.yml
   cp inventory/host_vars/sun/vault.yml.example inventory/host_vars/sun/vault.yml   # optional
   $EDITOR inventory/group_vars/all/vault.yml inventory/host_vars/*/vault.yml
   ansible-vault encrypt inventory/group_vars/all/vault.yml inventory/host_vars/*/vault.yml
   ```
   Beide Vaults mit demselben Passwort verschlüsseln, dann reicht ein `--ask-vault-pass`
   (oder `vault_password_file` in `ansible.cfg`).

## Ausführen

```bash
ansible-playbook site.yml --ask-vault-pass                        # alle Hosts
ansible-playbook site.yml --limit mars --ask-vault-pass           # ein Host
ansible-playbook site.yml --tags traefik --ask-vault-pass         # eine Rolle auf allen ihren Hosts
ansible-playbook site.yml --tags blocky_partitions --ask-vault-pass # nur die log_entries-Partitionierung
ansible-playbook site.yml --check --diff --ask-vault-pass         # Probelauf
ansible-playbook site.yml --limit mars -k -K --ask-vault-pass     # erster Lauf, noch mit Passwort
```

**Secure Boot:** Ist Secure Boot an (HP liefert so aus), stoppt die Rolle `nvidia` nach der
Treiberinstallation und gibt die zwei Befehle aus (`mokutil --import`, Reboot, im MOK-Manager
bestätigen). Danach das Playbook erneut starten. Mit Secure Boot aus läuft alles in einem
Durchgang mit einem Reboot.

**fish:** Ansible führt seine Module über `/bin/sh -c '…'` aus, fish als Login-Shell stört
deshalb nicht. root behält bash.

## mars: Umzug von Jellyfin von earth

Vorher BIOS aktualisieren (siehe `hp-g3/bios-update.md`) und in UniFi die DNS-Einträge
`mars.home.rdl.sh` und `traefik-mars.home.rdl.sh` auf mars zeigen lassen.
`jellyfin.home.rdl.sh` wird erst beim Umschalten geändert.

1. In `host_vars/mars/vars.yml`, Abschnitt `media_mounts`, mit `dest` die Container-Pfade aus
   der earth-Compose-Datei übernehmen (z. B. `dest: /data/movies`). Sonst findet die kopierte
   Konfiguration ihre Bibliotheken nicht.
2. Jellyfin auf earth stoppen und die Konfiguration kopieren:
   ```bash
   # auf earth
   docker compose stop jellyfin
   sudo rsync -aHAX --info=progress2 <earth-config>/ mroedel@mars.home.rdl.sh:/tmp/jf-config/
   # auf mars
   sudo rsync -a /tmp/jf-config/ /opt/stacks/jellyfin/config/
   sudo chown -R 1100:1100 /opt/stacks/jellyfin/config
   docker compose -f /opt/stacks/jellyfin/compose.yml up -d
   ```
   Die Known Proxies `172.16.10.2` und `fd00:10:73:10dc::2` passen unverändert, weil Traefik
   auf jedem Docker-Host dieselben Adressen hat (`group_vars/docker_hosts`).
3. Dashboard → Wiedergabe → Transkodierung: Pfad `/transcode`, dann **NVIDIA NVENC** mit den
   Einstellungen aus `earth/rtx-a400/README.md`, Abschnitt 4.
4. DNS-Eintrag `jellyfin.home.rdl.sh` auf mars umstellen.
5. **Seerr** bleibt auf earth und erreicht `http://jellyfin:8096` nicht mehr. In Seerr die
   Jellyfin-URL auf `https://jellyfin.home.rdl.sh` ändern.
6. Auf earth die Container jellyfin und jellyfin-exporter sowie den Traefik-Router `jellyfin`
   entfernen. Das CIFS-Passwort, das dort im Klartext stand, rotieren.

## Prometheus (auf earth)

- `prometheus/scrape-hosts.yml`: Jobs `node` (mars, sun), `nvidia-gpu` und `jellyfin` je Host.
  chrony, redis und postgres auf sun behalten ihre bestehenden Jobs. Der
  bestehende `traefik`-Job auf earth bekommt pro Traefik-Host ein weiteres Target, damit die
  vorhandenen `traefik:`-Recording-Rules und Alerts mitgelten.
- `prometheus/host-alerts.yml`: generisch für alle Hosts (Target down, Platte, RAM,
  systemd-Units, Temperatur) plus `JellyfinNasMountMissing` für mars. Damit node_exporter die
  NAS-Volumes unter `/var/lib/docker/volumes/nas-*` sieht, ist dessen Mount-Ausschlussliste
  angepasst; Docker-interne Mounts bleiben ausgeschlossen.
- Für die GPU gilt weiter `earth/rtx-a400/prometheus/nvidia-alerts.yml`. Grafana-Dashboards:
  1860 (Node Exporter Full), 14574/25547 (GPU) und das Traefik-Dashboard aus
  `earth/traefik-metrics/grafana/`.

```bash
promtool check rules host-alerts.yml   # hier nur als YAML geprüft, nicht mit promtool
curl -s http://mars.home.rdl.sh:9100/metrics | grep -c '^node_systemd_unit_state'
```

## Checks (mars)

```bash
nvidia-smi                                              # im Leerlauf P8
docker exec jellyfin nvidia-smi -L                      # GPU im Container
curl -sI https://jellyfin.home.rdl.sh/web/ | head -1    # 200 / 302
curl -sI http://jellyfin.home.rdl.sh/ | grep -i location  # https://...
curl -s -o /dev/null -w '%{http_code}\n' https://jellyfin.home.rdl.sh/metrics   # Block-Router
curl -s http://mars.home.rdl.sh:8082/ping               # OK
docker logs traefik 2>&1 | grep -o '"ClientHost":"[^"]*"' | tail   # echte Client-IPs
```

## Geprüft

`ansible-playbook --syntax-check` und `ansible-lint` (Profil production, ohne Befunde) mit
ansible-core 2.21.5 / ansible 14.5.0, `shellcheck` für die Update-Skripte. Die Templates für
mars und sun wurden gerendert und durchgesehen. Gegen die echten Hosts ist das Setup noch
nicht gelaufen.

## Entscheidungen und Annahmen

- **Netzwerk über systemd-networkd (base, opt-in):** Mit `network_manage: true` konfiguriert
  `base` das Haupt-Interface (per MAC gematcht) über `/etc/systemd/network/10-<if>.network`:
  IPv4 `dhcp`/`static`, RA an/aus, SLAAC an/aus, fester Interface-Token (`::5`, gilt dann auch
  für das dynamische GUA-Präfix), Privacy-Adressen, zusätzliche statische ULAs, MTU. Beim ersten
  Mal wird `/etc/network/interfaces` auf Loopback reduziert (mit Backup) und das Interface in
  einem abgekoppelten Schritt an networkd übergeben, Ansible verbindet sich danach neu. Spätere
  Änderungen: `networkctl reload` + `reconfigure`. `network_dns` schreibt eine statische
  `/etc/resolv.conf` (ohne systemd-resolved). Vorher unbedingt `--check --diff` und eine
  Konsole bereithalten.
- **MTU und Docker:** `docker_mtu` setzt `mtu` und `default-network-opts` in `daemon.json`, ist
  aber nur nötig, wenn das Host-MTU **unter** 1500 liegt. Bei Jumbo-Frames auf dem Host leer
  lassen: Container sprechen ohnehin mit 1500er-Clients, und die NAS-Volumes mountet der
  Host-Kernel, die profitieren also direkt vom Host-MTU.
- **Adressen aus den Facts statt fest eingetragen:** `host_ipv4` (Default-Route-Interface) und
  `host_ipv6` (statische ULA auf demselben Interface, erkannt an kurzer Interface-ID wie `::2`;
  SLAAC- und Privacy-Adressen werden übergangen) ergeben `host_addresses`. Daraus kommen
  `listen_addresses` (PostgreSQL, plus `localhost`), `bindaddress` (chrony) und `bind`
  (Valkey, plus Loopback, Host-Adressen optional mit `-`). Exporter lauschen weiter auf
  `:port`, Blocky standardmäßig auf allen Adressen. Bei
  falscher Erkennung `host_ipv4`/`host_ipv6` in `host_vars` setzen. Damit Dienste beim Booten
  nicht an der noch laufenden IPv6-DAD scheitern, setzt `base` `ip_nonlocal_bind`.
- **PostgreSQL komplett über Vars:** Datenbanken (`postgresql_databases`), Benutzer mit
  Attributen, Rechten, Settings und ihren `pg_hba.conf`-Zeilen (`postgresql_users`, Feld
  `hba`: `local`/`hostssl`, Datenbanken, Adressen, Methode `peer`/`scram-sha-256`). Passwörter
  nur im Vault (`vault_postgresql_passwords`, Name → Passwort); wer keinen Eintrag hat, behält
  sein Passwort. `pg_hba.conf` wird vor dem Reload über `pg_hba_file_rules` geprüft, bei Fehlern
  stellt die Rolle die alte Datei wieder her. `state: absent` löscht Benutzer erst, nachdem ihre
  hba-Zeilen weg sind. Nicht aufgeführte Benutzer und Datenbanken bleiben unangetastet.
- **Ordner in `host_files_fetch`:** Einträge dürfen auch Verzeichnisse sein, sie werden
  rekursiv geholt. Die Blocky-Rolle gleicht `blocky_list_dirs` (allow-/denylists) mit dem Host
  ab: Neue und geänderte Dateien werden kopiert, Dateien, die in `host_files` fehlen, auf dem
  Host gelöscht. Danach lädt `blocky lists refresh` die Listen neu, ohne Neustart (Neustart nur
  als Rückfall, wenn die API nicht antwortet).
- **Purge-Muster im Vault statt als Hostfile:** `purge-domains.sql` wird aus
  `vault_blocky_purge_patterns` erzeugt (LIKE-Muster auf `question_name`, nur Einträge der
  letzten `blocky_purge_window`, Datei `0640` root:blocky). Ohne Muster wird die Datei
  entfernt und der Purge-Timer abgeschaltet.
- **Gemeinsame Variablen ohne Rollen-Präfix** (`admin_user`, `home_domain`, `nvidia_enabled`,
  `media_mounts` …): Sie werden bewusst von mehreren Rollen genutzt. Die Lint-Regel
  `var-naming[no-role-prefix]` ist dafür in `.ansible-lint` abgeschaltet.
- **Kein Wildcard-Zertifikat:** Der websecure-Entrypoint setzt nur den `certResolver`. Jeder
  Router bekommt dadurch ein eigenes Zertifikat für die Namen in seiner `Host()`-Regel (DNS-
  Challenge), ohne eigenes `tls`-Label. Jeder Traefik-Host hat sein eigenes `acme.json`.
- **Block-Router** nachgebaut nach der Beschreibung in `homelab-context.md` (`/metrics`,
  `/health`, `/actuator`, `/debug/pprof`, `/.env`, `/.git`). Mit der Datei auf earth abgleichen.
- **Metrics-Ports** 8082, 9100, 9594 und 9835 sind auf dem Host veröffentlicht, weil
  Prometheus auf earth läuft. Schutz über die UniFi-Zonen-Firewall, keine Host-Firewall.
- **Jellyfin läuft als UID 1100** (`jellyfin`), nicht als root. Die CIFS-Mounts gehören dieser
  UID. Bei NFS müssen die Dateien auf der Synology für diese UID oder für alle lesbar sein.
  Bei Rechtefehlern entweder `jellyfin_uid` auf die UID von earth setzen oder im
  Synology-NFS-Export Squash auf „Alle Benutzer auf Admin abbilden“ stellen.
- **NAS-Freigaben als Docker-Volumes** (`nas-<name>`, local-Treiber mit NFS/CIFS), nicht als
  Host-Mounts. Docker hängt sie beim Start von Jellyfin ein. Ist das NAS nicht erreichbar,
  startet Jellyfin nicht, statt mit leeren Bibliotheken zu laufen. Die CIFS-Zugangsdaten
  stehen in der `.env` (Modus 0600) und nicht in der Compose-Datei; das Passwort darf kein
  Komma enthalten.
- **Eigener NAS-User je Server und Container** für CIFS, z. B. `mars-jellyfin`, nur mit
  Leserechten auf die nötigen Freigaben. Die Zugangsdaten stehen im Vault des Hosts
  (`host_vars/<host>/vault.yml`) als `vault_<container>_cifs_user` / `_password`, nicht
  global. So lässt sich ein Zugang einzeln sperren oder rotieren. Standard ist `ro`; soll Jellyfin NFO-Dateien schreiben,
  `media_readonly: false` setzen.
- **Volume-Optionen sind fest**, sobald ein Volume existiert. Nach Änderungen an
  `media_mounts`, `nfs_opts` oder dem CIFS-Passwort erst `docker compose down` und
  `docker volume rm nas-<name>`, dann die Rolle erneut laufen lassen.
- **Hängt eine Freigabe** (z. B. nach einem NAS-Neustart), hilft
  `docker compose -f /opt/stacks/jellyfin/compose.yml down && … up -d`. NFS ist `soft`
  gemountet, damit Zugriffe nach Timeout mit Fehler abbrechen statt ewig zu hängen.
- **NFSv4.1:** Ob earth v3 oder v4 nutzt, ist nicht dokumentiert. Schlägt der Mount fehl,
  `nfs_opts` auf `nfsvers=3,…` stellen.
- **`nvidia-ctk runtime configure`** wird nicht genutzt. Die Runtime steht direkt in der von
  Ansible verwalteten `daemon.json`, sonst würde jeder Lauf überschreiben, was `nvidia-ctk`
  geschrieben hat.
- **Netzwerkkonfiguration** der Hosts (statische IP, VLAN) macht Ansible nicht. Eine
  DHCP-Reservierung in UniFi reicht und ist risikoärmer.
- **jellyfin-exporter**-Flags stammen aus `homelab-context.md`. `--jellyfin.address` und
  `--jellyfin.token` mit der Compose-Datei auf earth abgleichen.
- **node_exporter** läuft auf `docker_hosts` als Container, auf allen anderen Hosts als Binary
  (Rolle `node_exporter`). Das Textfile-Verzeichnis ist das des Debian-Pakets, damit
  `update-doh-iplists` dort ohne Anpassung schreibt.
- **sun: Configs aus `host_files` statt Templates** für Blocky, `postgresql.conf` und die Valkey-ACL.
  Deren Inhalt ist nur auf sun vorhanden und zu umfangreich, um ihn blind als Template
  nachzubauen. Units, chrony und die PostgreSQL-Snippets sind dagegen Templates, weil ihr
  Inhalt in `homelab-context.md` vollständig dokumentiert ist.
- **Zeit: timesyncd auf Clients, chrony nur auf NTP-Servern.** `base` installiert auf allen
  Hosts außer `chrony_servers` `systemd-timesyncd` mit `NTP=time.home.rdl.sh` (Drop-in
  `timesyncd.conf.d/homelab.conf`, Fallback: Debian-Pool). Die Pakete schließen sich gegenseitig
  aus, ein vorhandenes chrony wird dabei ersetzt. sun bekommt chrony nur über `chrony_server`.
- **Partitionierung von `log_entries`** steckt in `roles/blocky/tasks/partitions.yml` (Tag
  `blocky_partitions`): Funktion `maintain_log_entries_partitions` samt Timer, autovacuum-Werte
  auf allen Partitionen und auf frischen Hosts die partitionierte Tabelle. Eine bestehende
  Tabelle fasst Ansible nie an; die Umstellung einer unpartitionierten Tabelle bleibt manuell.
- **PostgreSQL-Passwörter** sind optional im Vault. Ohne Vault-Eintrag behalten die Rollen ihr
  bestehendes Passwort.

## Bewusst weggelassen

- Docker-Daemon-Metriken und cAdvisor: Die Exporter und `HostTargetDown` decken die
  relevanten Ausfälle ab.
- Docker-Socket-Proxy für Traefik: Der Socket ist read-only gemountet, `no-new-privileges` ist
  gesetzt.
- Host-Firewall (nftables), Loki/Promtail, Tdarr, Backup der Jellyfin-Konfiguration: eigene
  Themen, später als weitere Rollen ergänzbar.
- `update-doh-iplists` (DoH-Sperrlisten) auf sun: noch nicht eingespielt, kann als eigene
  Rolle folgen, sobald du es nutzen willst.
- Backup von PostgreSQL und Valkey auf sun.
