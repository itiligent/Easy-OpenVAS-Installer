# Optional Legacy Greenbone Package Cleanup

No script can account for all potential user customisations and variances, thefore use this information at your own risk. Always snapshot or backup your OpenVAS instance first! 

This procedure identifies older system-wide Python packages installed by the previous install model, verifies the migrated command links, removes confirmed legacy packages, and restores the links to the new Python virtual environments.



> **Important:** Run the cleanup only after migration and feed synchronisation have completed successfully. Older legacy packages are typically installed under `/usr/local`.

## 1. Identify Legacy Packages

Show installed Python package locations and declared dependencies:

```bash
sudo /usr/bin/python3 -I -m pip show \
    ospd-openvas greenbone-feed-sync gvm-tools \
    python-gvm pypsrp-cli ospd
```

## 2. Verify Migrated Command Links

Show which commands point into the new Python virtual environments:

```bash
ls -l /usr/local/bin/ospd-openvas \
      /usr/local/bin/greenbone*-sync \
      /usr/local/bin/gvm-{cli,script,pyshell} \
      /usr/local/bin/pypsrp-cli
```

## 3. Remove Confirmed Legacy Packages and Restore Links

Run this step only after migration and feed synchronisation have finished.

The script:

- Checks the migrated virtual environments and their launcher symlinks.
- Removes four legacy system-wide packages: `gvm-tools`, `python-gvm`, `ospd-openvas`, and `greenbone-feed-sync`.
- Restores the eight migrated command links, even if `pip uninstall` fails.
- Leaves shared Python dependencies installed.
- Rechecks the virtual environments after cleanup.

```bash
sudo bash <<'CLEANUP'
set -euo pipefail

declare -A launchers=(
    [ospd-openvas]=ospd-openvas
    [greenbone-feed-sync]=greenbone-feed-sync
    [greenbone-nvt-sync]=greenbone-feed-sync
    [greenbone-scapdata-sync]=greenbone-feed-sync
    [greenbone-certdata-sync]=greenbone-feed-sync
    [gvm-cli]=gvm-tools
    [gvm-script]=gvm-tools
    [gvm-pyshell]=gvm-tools
)

for command_name in "${!launchers[@]}"; do
    target="/opt/gvm/venvs/${launchers[$command_name]}/bin/$command_name"
    link="/usr/local/bin/$command_name"
    if [[ ! -L "$link" || "$(readlink "$link")" != "$target" || ! -x "$target" ]]; then
        printf 'Unexpected or broken launcher: %s\n' "$link" >&2
        exit 1
    fi
done

check_venvs() {
    local app
    for app in ospd-openvas greenbone-feed-sync gvm-tools pypsrp-cli; do
        "/opt/gvm/venvs/$app/bin/python" -I -m pip check
    done
}

restore_links() {
    local command_name
    for command_name in "${!launchers[@]}"; do
        ln -sfn "/opt/gvm/venvs/${launchers[$command_name]}/bin/$command_name" \
            "/usr/local/bin/$command_name"
    done
}

check_venvs
trap restore_links EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/usr/bin/python3 -I -m pip uninstall --break-system-packages --yes \
    gvm-tools python-gvm ospd-openvas greenbone-feed-sync

restore_links
trap - EXIT
check_venvs
printf '\nLegacy Python packages removed; migrated command links restored.\n'
CLEANUP
```

## 4. Verify Migrated Commands and Services

Check the migrated services and command-line tools are working:

```bash
for command_name in ospd-openvas greenbone-feed-sync gvm-cli pypsrp-cli; do
    if sudo -u gvm "/usr/local/bin/$command_name" --help >/dev/null; then
        echo "OK: $command_name"
    else
        echo "FAILED: $command_name" >&2
        exit 1
    fi
done
```
