# host_files

Live-Konfigurationen, die nicht als Template gepflegt werden, sondern 1:1 vom Host
stammen. Befüllt mit `ansible-playbook fetch-host-files.yml --limit <host>`, Ablage unter
`host_files/<host>/<absoluter Pfad>`. Einträge in `host_files_fetch` können
Dateien oder ganze Ordner sein (Ordner werden rekursiv geholt). Dateien mit Passwörtern danach verschlüsseln:

```bash
ansible-vault encrypt host_files/sun/etc/redis_exporter/redis_exporter \
  host_files/sun/etc/valkey/valkey.conf host_files/sun/etc/valkey/users.acl
```

Ansible entschlüsselt sie beim Kopieren automatisch. Änderungen an diesen Dateien hier
machen und mit `site.yml` ausrollen, nicht mehr direkt auf dem Host.
