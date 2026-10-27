#!/bin/bash
# shellcheck disable=SC2024  # Redirects write invoking-user logs/backups, intentionally outside sudo.
##############################################################################
# Greenbone Vulnerability Manager appliance upgrade script
# Multi-distro support for Ubuntu, Debian & Raspbian
# David Harrop
# November 2026
#
# For older OpenVAS installations or those built with the installer versions from
# this repo before the November 2026 update.
#
# Preserves the database, gvm account, credentials, keys, feeds and certificates
# while upgrading components and dependencies to the new installation layout.
# Prepares the system for future updates using openvas-upgrade.sh.
#
# Database migration sequence:
# - Backs up the existing database, configuration, state and keys.
# - Deploys the selected binaries/libraries, then restores the database backup
#   into a separate gvmd_migration_* test database as a rehearsal.
# - Tests database migration, compares account identities and verifes that
#   credential encryption keys remained unchanged.
# - Deletes the successful test database, then migrates the live database.
# - If rehearsal fails, retains the test database and backups for inspection and
#   the live database remains unmigrated and GVM services remain stopped.
# - --skip-migration-rehearsal skips backups, the restored-copy test and its space
#   checks. Live migration and the final account/key checks still run. Only small
#   cron recovery files, account/key checks and file-metadata records are retained.
#
# --check           Check layout compatibility without changing the installation.
# --migrate-legacy  Perform the one-time migration and component upgrade.
# --skip-migration-rehearsal  Omit backups and the legacy migration rehearsal.
# Eg. ./openvas-migrate-legacy --skip-migration-rehearsal --migrate-legacy

##############################################################################
# EDIT BELOW SETTINGS: All custom settings & dependency mgmt is handled in
# this section. Blank module versions "" select GitHub's latest stable release.
# Environment overrides are also supported, eg: FORCE_GVMD_VERSION=26.42.0
##############################################################################

# FORCE MODULE VERSIONS or accept default to automatically download latest
FORCE_GVM_LIBS_VERSION="${FORCE_GVM_LIBS_VERSION:-}"
FORCE_GVMD_VERSION="${FORCE_GVMD_VERSION:-}"
FORCE_PG_GVM_VERSION="${FORCE_PG_GVM_VERSION:-}"
FORCE_GSA_VERSION="${FORCE_GSA_VERSION:-}"
FORCE_GSAD_VERSION="${FORCE_GSAD_VERSION:-}"
FORCE_OPENVAS_SMB_VERSION="${FORCE_OPENVAS_SMB_VERSION:-}"
FORCE_OPENVAS_SCANNER_VERSION="${FORCE_OPENVAS_SCANNER_VERSION:-}"
FORCE_OSPD_OPENVAS_VERSION="${FORCE_OSPD_OPENVAS_VERSION:-}"
# openvasd and scannerctl use the selected OPENVAS_SCANNER_VERSION source.
FORCE_FEED_SYNC_VERSION="${FORCE_FEED_SYNC_VERSION:-}"
FORCE_GVM_TOOLS_VERSION="${FORCE_GVM_TOOLS_VERSION:-}"
FORCE_PYTHON_GVM_VERSION="${FORCE_PYTHON_GVM_VERSION:-}"
FORCE_PYPSRP_CLI_VERSION="${FORCE_PYPSRP_CLI_VERSION:-}"
FORCE_FEED_RELEASE="${FORCE_FEED_RELEASE:-}" # Blank: use feed-sync defaults/configuration.

# Version fallback: These versions were tested and working at time of script release.
# Remove the above defaults that use latest versions and uncomment below
#FORCE_GVM_LIBS_VERSION="${FORCE_GVM_LIBS_VERSION:-23.15.0}"
#FORCE_GVMD_VERSION="${FORCE_GVMD_VERSION:-26.43.0}"
#FORCE_PG_GVM_VERSION="${FORCE_PG_GVM_VERSION:-22.6.19}"
#FORCE_GSA_VERSION="${FORCE_GSA_VERSION:-28.7.0}"
#FORCE_GSAD_VERSION="${FORCE_GSAD_VERSION:-27.7.0}"
#FORCE_OPENVAS_SMB_VERSION="${FORCE_OPENVAS_SMB_VERSION:-22.5.10}"
#FORCE_OPENVAS_SCANNER_VERSION="${FORCE_OPENVAS_SCANNER_VERSION:-23.52.8}"
#FORCE_OSPD_OPENVAS_VERSION="${FORCE_OSPD_OPENVAS_VERSION:-22.10.6}"
#FORCE_FEED_SYNC_VERSION="${FORCE_FEED_SYNC_VERSION:-25.5.0}"
#FORCE_GVM_TOOLS_VERSION="${FORCE_GVM_TOOLS_VERSION:-26.1.2}"
#FORCE_PYTHON_GVM_VERSION="${FORCE_PYTHON_GVM_VERSION:-27.10.1}"
#FORCE_PYPSRP_CLI_VERSION="${FORCE_PYPSRP_CLI_VERSION:-0.1.1}"
#FORCE_FEED_RELEASE="${FORCE_FEED_RELEASE:-}"

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
PYTHON_ENV_DIR="${PYTHON_ENV_DIR:-/opt/gvm/venvs}"
WORK_ROOT="${WORK_ROOT:-$HOME/openvas-upgrade}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-$HOME/openvas-build-logs}"
DB_NAME="${DB_NAME:-gvmd}"
DB_HOST="${DB_HOST:-/var/run/postgresql}"
DB_PORT="${DB_PORT:-5432}"
POSTGRESQL_MAJOR="${POSTGRESQL_MAJOR:-}"							# Blank: detect; a mismatch is rejected.
SYNC_FEEDS="${SYNC_FEEDS:-true}"       								# Synchronize feeds after migration.
SKIP_MIGRATION_REHEARSAL="${SKIP_MIGRATION_REHEARSAL:-false}"		# true skips ALL backups, the test copy and its space checks.
MIGRATION_TEST_SPACE_PERCENT="${MIGRATION_TEST_SPACE_PERCENT:-200}" # Rehearsal threshold: this percentage of the database size, plus 1 GiB.
KEEP_BUILD_FILES="${KEEP_BUILD_FILES:-false}" 						# Failed runs always retain their files.
BUILD_JOBS="${BUILD_JOBS:-2}"          								# Parallel CMake, Make, Rust and Python build jobs.
APT_AUTOREMOVE="${APT_AUTOREMOVE:-${AUTO_REMOVE_PACKAGES:-false}}" 	# Opt in to APT autoremove before service checks.
FEED_WAIT_SECONDS="${FEED_WAIT_SECONDS:-600}" 						# Wait for running feed sync after pausing cron; 0 fails immediately.
SERVICE_CHECK_SECONDS="${SERVICE_CHECK_SECONDS:-15}"				# Time to wait for service check service startup.
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-0.2}" 						# Seconds between updates; fractions such as 0.2 are supported.
FEED_SYNC_ATTEMPTS="${FEED_SYNC_ATTEMPTS:-3}" 						# Total attempts, including the first (1-99).
FEED_SYNC_RETRY_DELAY="${FEED_SYNC_RETRY_DELAY:-60}" 				# Seconds between attempts (0-3600).
POSTGRESQL=()

clear

# BEGIN SHARED FEED AND SERVICE HELPERS
sync_feeds_with_retries() {
    # Keep every attempt in one authenticated sudo session, with the parent spinner.
    sudo bash -e -s -- "$INSTALL_PREFIX/bin/greenbone-feed-sync" \
        "${FORCE_FEED_RELEASE:-}" "$FEED_SYNC_ATTEMPTS" "$FEED_SYNC_RETRY_DELAY" \
        "$BUILD_LOG" "$LYELLOW" "$LRED" "$NC" <<'FEED_RETRIES'
feed_command=("$1")
[[ -z "$2" ]] || feed_command+=(--feed-release "$2")
attempts="$3" retry_delay="$4" build_log="$5"
yellow="$6" red="$7" reset="$8"
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

for ((attempt = 1; attempt <= attempts; attempt++)); do
    # Repair existing files in place: replacing a lock file would break locking.
    # Repeat before every attempt, since feed-sync drops privileges to gvm.
    for lock in /var/lib/openvas/feed-update.lock /var/lib/gvm/feed-update.lock; do
        if [[ -L "$lock" || ( -e "$lock" && ! -f "$lock" ) ]]; then
            printf '%sInvalid feed lock file: %s%s\n' "$red" "$lock" "$reset" >&2
            exit 1
        fi
        if [[ -f "$lock" ]]; then
            chown gvm:gvm "$lock"
            chmod 0660 "$lock"
        fi
    done

    printf '%sFeed download attempt %s/%s. Details: %s%s\n' \
        "$yellow" "$attempt" "$attempts" "$build_log" "$reset"
    if "${feed_command[@]}" --fail-fast >>"$build_log" 2>&1; then
        break
    else
        status=$?
    fi
    case "$status" in 129|130|143) exit "$status" ;; esac
    if (( attempt == attempts )); then
        printf '%sFeed download failed after %s attempts (exit %s). Log: %s%s\n' \
            "$red" "$attempts" "$status" "$build_log" "$reset" >&2
        exit "$status"
    fi
    printf '%sFeed download failed (exit %s); retrying in %s seconds.%s\n' \
        "$yellow" "$status" "$retry_delay" "$reset"
    sleep "$retry_delay"
done
FEED_RETRIES
}

start_services() {
    run_task 'Restarting the existing OpenVAS Redis instance' sudo systemctl restart redis-server@openvas.service
    run_task 'Starting OpenVAS services' sudo systemctl start openvasd.service ospd-openvas.service gvmd.service gsad.service
    run_task "Waiting $SERVICE_CHECK_SECONDS seconds for service startup" sleep "$SERVICE_CHECK_SECONDS"
    local service
    if [[ "${1:-false}" == true ]]; then
        run_task 'Repairing first-start GSAD log ownership' sudo chown -R gvm:gvm /var/log/gvm
        run_task 'Restarting GSAD after log setup' sudo systemctl restart gsad.service
    fi
    for service in redis-server@openvas gsad gvmd ospd-openvas openvasd; do
        run_task "Checking $service.service" sudo systemctl is-active --quiet "$service.service"
    done
}
# END SHARED FEED AND SERVICE HELPERS

# BEGIN SHARED SAFETY HELPERS
# This region is intentionally identical in all three standalone scripts.
GREENBONE_SIGNING_FINGERPRINT=8AE4BE429B60A59B311C2E739823FAA60ED1E580

acquire_maintenance_lock() {
    local lock=/run/lock/easy-openvas-maintenance.lock
    sudo "$PYTHON_BIN" - "$lock" <<'MAINTENANCE_LOCK'
import os, stat, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1:
        raise SystemExit('Invalid OpenVAS maintenance lock file; review it before continuing.')
    os.fchmod(fd, 0o644)
finally:
    os.close(fd)
MAINTENANCE_LOCK
    [[ "$?" == 0 ]] || return 1
    exec 9<"$lock" || return
    if ! flock -n 9; then
        printf 'Another OpenVAS installer, migration or upgrade is already running.\n' >&2
        exec 9<&-
        return 1
    fi
    UPGRADE_LOCKED=true
}

import_signing_key() {
    local key="$1" fingerprints
    fingerprints=$(gpg --batch --with-colons --import-options show-only --import "$key" |
        awk -F: '$1 == "pub" { primary=1; next } primary && $1 == "fpr" { print $10; primary=0 }') || return
    [[ "$fingerprints" == "$GREENBONE_SIGNING_FINGERPRINT" ]] || {
        printf 'Unexpected Greenbone primary signing-key fingerprint: %s\n' "$fingerprints" >&2
        return 1
    }
    gpg --batch --import "$key" || return
    printf '%s:6:\n' "$GREENBONE_SIGNING_FINGERPRINT" | gpg --batch --import-ownertrust
}

verify_source_signature() {
    local status
    status=$(gpg --batch --status-fd=1 --verify "$1" "$2") || return
    # VALIDSIG identifies the signing subkey and (when present) its primary key.
    awk -v expected="$GREENBONE_SIGNING_FINGERPRINT" '
        $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
            primary = (NF >= 12 ? $12 : $3)
            if (primary == expected) valid=1
        }
        END { exit !valid }
    ' <<< "$status" || {
        printf 'Signature was not made by the expected Greenbone primary key.\n' >&2
        return 1
    }
}

install_python_app() {
    local name="$1" compiler build_path="$PATH" candidate previous stable status=0
    shift
    stable="$PYTHON_ENV_DIR/$name"
    sudo install -d -m 0755 "$PYTHON_ENV_DIR" || return
    candidate=$(sudo mktemp -d "$PYTHON_ENV_DIR/.$name-XXXXXXXX") || return
    # Keep this physical path: generated Python launchers embed it in shebangs.
    sudo chmod 0755 "$candidate" || return
    if [[ -x "$HOME/.cargo/bin/rustup" ]] && compiler=$("$HOME/.cargo/bin/rustup" which rustc 2>/dev/null); then
        build_path="$(dirname "$compiler"):$build_path"
    fi
    sudo "$PYTHON_BIN" -m venv "$candidate" || return
    sudo env PATH="$candidate/bin:$build_path" "$candidate/bin/python" -m pip install --upgrade pip || return
    sudo env PATH="$candidate/bin:$build_path" CARGO_BUILD_JOBS="$BUILD_JOBS" \
        CMAKE_BUILD_PARALLEL_LEVEL="$BUILD_JOBS" MAKEFLAGS="-j$BUILD_JOBS" \
        "$candidate/bin/python" -m pip install "$@" || return
    "$candidate/bin/python" -m pip check || return
    case "$name" in
        ospd-openvas) "$candidate/bin/ospd-openvas" --help >/dev/null || return ;;
        greenbone-feed-sync) "$candidate/bin/greenbone-feed-sync" --version || return ;;
        gvm-tools) "$candidate/bin/gvm-cli" --help >/dev/null || return ;;
        pypsrp-cli)
            "$candidate/bin/pypsrp-cli" --help >/dev/null || return
            if [[ " $* " == *' impacket '* ]]; then
                if [[ -x "$candidate/bin/impacket-wmiexec" ]]; then
                    "$candidate/bin/impacket-wmiexec" -h >/dev/null || return
                else
                    "$candidate/bin/wmiexec.py" -h >/dev/null || return
                fi
            fi ;;
        *) printf 'Unknown Python application: %s\n' "$name" >&2; return 1 ;;
    esac
    (umask 077; "$candidate/bin/python" -m pip list --format=freeze > "$BUILD_LOG_DIR/$BUILD_ID-$name-requirements.txt") || return
    # Preserve the working environment on build/check failure. Retain previous
    # environments for manual recovery, including the first directory layout.
    previous="$PYTHON_ENV_DIR/.$name-previous-$BUILD_ID"
    if sudo test -d "$stable" && ! sudo test -L "$stable"; then
        sudo test ! -e "$previous" || return 1
        sudo mv -T -- "$stable" "$previous" || return
    else
        previous=""
    fi
    sudo "$PYTHON_BIN" - "$candidate" "$stable" <<'SWITCH_VENV' || status=$?
import os, stat, sys
source, target = sys.argv[1:]
if os.path.lexists(target) and not stat.S_ISLNK(os.lstat(target).st_mode):
    raise SystemExit('Refusing to replace a non-directory custom Python environment: ' + target)
temporary = target + '.new-' + str(os.getpid())
try:
    os.symlink(source, temporary)
    os.replace(temporary, target)
finally:
    if os.path.lexists(temporary): os.unlink(temporary)
SWITCH_VENV
    if (( status != 0 )); then
        if [[ -n "$previous" ]]; then sudo mv -T -- "$previous" "$stable" || return; fi
        return "$status"
    fi
    printf 'Selected Python environment: %s -> %s\n' "$stable" "$candidate"
}

needs_isolated_impacket() {
    # Test the environment itself, including a fallback whose public launcher is
    # currently broken. It must be included in the replacement environment.
    if [[ -x "$PYTHON_ENV_DIR/pypsrp-cli/bin/wmiexec.py" ||
          -x "$PYTHON_ENV_DIR/pypsrp-cli/bin/impacket-wmiexec" ]] ||
        { [[ -x "$PYTHON_ENV_DIR/pypsrp-cli/bin/python" ]] &&
          "$PYTHON_ENV_DIR/pypsrp-cli/bin/python" -c 'import importlib.metadata; importlib.metadata.version("impacket")' >/dev/null 2>&1; }; then
        return 0
    fi
    # Fresh-install preflight deliberately runs before account creation. There
    # is no service identity to test yet; plan for the isolated fallback.
    getent passwd gvm >/dev/null 2>&1 || return 0
    ! sudo -u gvm env PATH=/usr/local/bin:/usr/bin:/bin impacket-wmiexec -h >>"$BUILD_LOG" 2>&1
}

prepare_python_build_dependencies() {
    # pip --dry-run still executes source-build metadata hooks. Install the
    # native development prerequisites before those hooks, not at the later
    # Windows-helper/application build stage. Request only missing packages.
    local package package_status tool
    local -a missing_packages=()
    for package in "${PYTHON_BUILD_DEPS[@]}"; do
        if ! package_status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) ||
            [[ "$package_status" != 'install ok installed' ]]; then
            missing_packages+=("$package")
        fi
    done
    if (( ${#missing_packages[@]} > 0 )); then
        printf 'Installing missing Python build prerequisites: %s\n' "${missing_packages[*]}" >> "$BUILD_LOG"
        sudo env DEBIAN_FRONTEND=noninteractive apt-get --assume-yes \
            --no-remove --no-install-recommends -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold install "${missing_packages[@]}" >> "$BUILD_LOG" 2>&1 || return
    fi
    for tool in cc pkg-config krb5-config; do
        command -v "$tool" >/dev/null || {
            printf 'Python preflight build tool missing after dependency preparation: %s. Review %s.\n' "$tool" "$BUILD_LOG" >&2
            return 1
        }
    done
    krb5-config --libs gssapi >> "$BUILD_LOG" 2>&1 || return
    krb5-config --cflags gssapi >> "$BUILD_LOG" 2>&1 || return
}

check_selected_compatibility() {
    local preflight="$RUN_DIR/python-preflight" name
    # Conservative published feed compatibility policy, before any service stop.
    "$PYTHON_BIN" - "$GVMD_VERSION" "$FEED_SYNC_VERSION" "$FORCE_FEED_RELEASE" <<'FEED_COMPATIBILITY'
import sys
import re
manager = tuple(map(int, re.match(r'(\d+)\.(\d+)\.(\d+)', sys.argv[1]).groups()))
feed = tuple(map(int, re.match(r'(\d+)\.(\d+)\.(\d+)', sys.argv[2]).groups()))
release = sys.argv[3]
if feed >= (25, 0, 0):
    if (24, 0, 0) <= manager < (25, 0, 0):
        raise SystemExit('feed-sync >=25 with gvmd 24.x requires manual feed intervention; select gvmd >=25 before continuing.')
    if manager < (24, 0, 0) and release != '22.04':
        raise SystemExit('gvmd <24 with feed-sync >=25 requires FORCE_FEED_RELEASE=22.04.')
print('Published GVMD/feed compatibility checks passed.')
FEED_COMPATIBILITY
    [[ "$?" == 0 ]] || return 1
    "$PYTHON_BIN" -m venv "$preflight" || return
    "$preflight/bin/python" -m pip install --upgrade pip >>"$BUILD_LOG" 2>&1 || return
    local -a packages
    for name in ospd-openvas greenbone-feed-sync gvm-tools pypsrp-cli; do
        case "$name" in
            ospd-openvas) packages=("$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION") ;;
            greenbone-feed-sync) packages=("$SOURCE_DIR/greenbone-feed-sync-$FEED_SYNC_VERSION") ;;
            gvm-tools) packages=("$SOURCE_DIR/python-gvm-$PYTHON_GVM_VERSION" "$SOURCE_DIR/gvm-tools-$GVM_TOOLS_VERSION") ;;
            pypsrp-cli) packages=("$SOURCE_DIR/pypsrp-cli-$PYPSRP_CLI_VERSION")
                if needs_isolated_impacket; then packages+=(impacket); fi ;;
        esac
        # Per-application environments may have different dependency constraints.
        # pip also validates Requires-Python from the selected source metadata.
        "$preflight/bin/python" -m pip install --dry-run --ignore-installed \
            --report "$RUN_DIR/$name-preflight.json" "${packages[@]}" >>"$BUILD_LOG" 2>&1 || {
            printf 'Selected %s Python/dependency requirements cannot be resolved. Review %s.\n' "$name" "$BUILD_LOG" >&2
            return 1
        }
        printf 'Python/dependency preflight passed: %s\n' "$name"
    done
}
check_dependency_plan() {
    # Simulation catches missing/conflicting distro packages without installing
    # anything or allowing package post-install hooks to restart daemons.
    sudo env DEBIAN_FRONTEND=noninteractive apt-get --simulate --no-remove --no-install-recommends install \
        "${COMMON_DEPS[@]}" "${MAIL_DEPS[@]}" "${GVMLIBS_DEPS[@]}" \
        "${GVMD_DEPS1[@]}" "${GVMD_DEPS2[@]}" "${PGGVM_DEPS[@]}" \
        "${GSAD_DEPS[@]}" "${OPENVASSMB_DEPS[@]}" "${OPENVASSCAN_DEPS[@]}" \
        "${OSPD_DEPS[@]}" "${FEED_DEPS[@]}" "${GVMTOOLS_DEPS[@]}" \
        "${REDIS_DEPS[@]}" "${OPENVASD_DEPS[@]}" "${PYPSRP_DEPS[@]}" "${PYTHON_BUILD_DEPS[@]}"
}

check_source_requirements() {
    "$PYTHON_BIN" - "$SOURCE_DIR" "$GVM_LIBS_VERSION" "$OPENVAS_SMB_VERSION" \
        "$OPENVAS_SCANNER_VERSION" <<'SOURCE_REQUIREMENTS'
from pathlib import Path
import re, subprocess, sys
source = Path(sys.argv[1])
def version(value):
    match = re.match(r'(\d+(?:\.\d+)*)', value)
    if not match: raise SystemExit('Cannot compare component version: ' + value)
    parts = tuple(map(int, match[1].split('.')))
    return parts + (0,) * (4 - len(parts))
libraries, smb = version(sys.argv[2]), version(sys.argv[3])
cmake = subprocess.run(['cmake','--version'],check=True,text=True,capture_output=True).stdout
installed = version(re.search(r'version\s+(\S+)', cmake)[1])
for component in source.iterdir():
    if not component.is_dir(): continue
    for path in component.rglob('CMakeLists.txt'):
        if any(part in ('vendor', 'node_modules', '.git') for part in path.parts): continue
        # Comments are not active requirements. This is a conservative check of
        # declared library minimums, including optional libraries from gvm-libs.
        text = '\n'.join(row.split('#',1)[0] for row in path.read_text(errors='replace').splitlines())
        for minimum in re.findall(r'(?i)cmake_minimum_required\s*\(\s*VERSION\s+([0-9.]+)',text):
            if installed < version(minimum):
                raise SystemExit(f'{path}: CMake >= {minimum} is required; installed {cmake.splitlines()[0]}.')
        for name, operator, minimum in re.findall(r'\b(libgvm_[A-Za-z0-9_]+|openvas_wmiclient|openvas_wincmd)\s*(>=|>|=|<=|<)\s*([0-9]+(?:\.[0-9]+)*)',text):
            if name == 'libgvm_auth': continue  # Separate optional project, not gvm-libs.
            selected = libraries if name.startswith('libgvm_') else smb
            required = version(minimum)
            accepted = {'>=':selected>=required, '>':selected>required, '=':selected==required,
                        '<=':selected<=required, '<':selected<required}[operator]
            if not accepted:
                raise SystemExit(f'{path}: selected components do not satisfy {name}{operator}{minimum}.')
scanner = source / ('openvas-scanner-' + sys.argv[4])
if not (scanner/'rust'/'Cargo.lock').is_file():
    raise SystemExit('Selected scanner source has no rust/Cargo.lock for the required openvasd/scannerctl build.')
if (scanner/'rust/crates/nasl-c-lib/libopenvas-krb5-sys/build.rs').is_file():
    dockerfile = (scanner/'.docker/prod.Dockerfile').read_text()
    for variable, directory, suffix in [('KRB5_VERSION','krb5','src/configure'),('LIBPCAP_VERSION','libpcap','configure')]:
        match = re.search(r'(?m)^ARG '+variable+r'=([0-9.]+)\s*$',dockerfile)
        if not match or not (scanner/'.docker/vendor'/f'{directory}-{match[1]}'/suffix).is_file():
            raise SystemExit('Selected scanner source lacks the expected vendored native library: ' + directory)
print('Declared CMake/library minimums and scanner source prerequisites passed.')
SOURCE_REQUIREMENTS
}
check_web_destination() {
    "$PYTHON_BIN" - "${1:-$INSTALL_PREFIX/share/gvm/gsad/web}" <<'WEB_DESTINATION'
from pathlib import Path
import sys
path = Path(sys.argv[1])
if path.resolve() != path:
    raise SystemExit('Review the symlinked GSA web destination before using asset pruning: ' + str(path))
if path.exists() and not path.is_dir():
    raise SystemExit('GSA web destination is not a directory: ' + str(path))
WEB_DESTINATION
}

# END SHARED SAFETY HELPERS

# BEGIN SHARED FEED SCHEDULE HELPERS
# Direct and env/sudo-wrapped jobs are supported. Complex shell jobs must be
# suspended explicitly; preparation finishes for every owner before any pause.
read_migration_cron() {
    local owner="$1" destination="$2" status
    if sudo env LC_ALL=C crontab -u "$owner" -l > "$destination" 2> "$destination.err"; then
        return 0
    else
        status=$?
    fi
    if [[ "$status" == 1 && "$(<"$destination.err")" == "no crontab for $owner" ]]; then
        : > "$destination"
        return 0
    fi
    cat "$destination.err" >&2
    return "$status"
}

check_external_feed_schedules() {
    # These schedules cannot be safely edited as per-user crontabs. Fail before
    # stopping services and name the actual file or timer that needs attention.
    sudo "$PYTHON_BIN" - <<'EXTERNAL_FEED_SCHEDULES'
from pathlib import Path
import re, subprocess
names = re.compile(r'(?<![\w-])(?:greenbone-(?:feed|nvt|scapdata|certdata)-sync|gvm-feed-update|openvas-nvt-sync)(?![\w-])')
files = [Path('/etc/crontab')]
for directory in ('cron.d', 'cron.hourly', 'cron.daily', 'cron.weekly', 'cron.monthly'):
    root = Path('/etc') / directory
    if root.exists(): files.extend(p for p in root.iterdir() if p.is_file())
problems = []
for path in files:
    if not path.is_file(): continue
    for line in path.read_text(errors='replace').splitlines():
        if not line.lstrip().startswith('#') and names.search(line):
            problems.append(str(path)); break
result = subprocess.run(['systemctl', 'list-unit-files', '--type=timer', '--no-legend', '--no-pager'],
                        text=True, capture_output=True, check=True)
timers = {}
for line in result.stdout.splitlines():
    fields = line.split()
    if len(fields) >= 2 and not fields[0].endswith('@.timer'):
        timers[fields[0]] = fields[1]
# Loaded instances and transient timers may have no installed unit-file entry.
result = subprocess.run(['systemctl', 'list-units', '--all', '--type=timer', '--plain', '--no-legend', '--no-pager'],
                        text=True, capture_output=True, check=True)
for line in result.stdout.splitlines():
    fields = line.split()
    if fields and not fields[0].endswith('@.timer'):
        timers.setdefault(fields[0], '')
for timer, state in sorted(timers.items()):
    active = subprocess.run(['systemctl', 'is-active', '--quiet', timer]).returncode == 0
    if state not in ('enabled', 'enabled-runtime', 'linked', 'linked-runtime', 'alias') and not active:
        continue
    units = subprocess.run(['systemctl', 'show', timer, '--property=Triggers', '--value'],
                           text=True, capture_output=True, check=True).stdout.split()
    for unit in units:
        result = subprocess.run(['systemctl', 'cat', unit, '--no-pager'],
                                text=True, capture_output=True)
        if result.returncode != 0:
            # Transient services have runtime properties rather than unit files.
            result = subprocess.run(['systemctl', 'show', unit, '--property=ExecStart',
                                     '--property=ExecStartPre', '--property=ExecStartPost',
                                     '--property=Environment', '--value'],
                                    text=True, capture_output=True, check=True)
        if any(names.search(row) for row in result.stdout.splitlines() if not row.lstrip().startswith('#')):
            problems.append(timer); break
if problems:
    raise SystemExit('Suspend these external feed schedules before continuing: ' + ', '.join(sorted(set(problems))))
EXTERNAL_FEED_SCHEDULES
}

prepare_feed_cron() {
    "$PYTHON_BIN" - "$1" "$FORCE_FEED_RELEASE" "$INSTALL_PREFIX/bin/greenbone-feed-sync" <<'FEED_CRON'
from pathlib import Path, PurePosixPath
import re, shlex, sys
base, release, executable = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
original = Path(str(base) + '.original').read_text()
marker = '# Easy-OpenVAS maintenance paused: '
if marker in original or '# Easy-OpenVAS migration paused: ' in original:
    raise SystemExit('Earlier maintenance left feed cron jobs paused; restore its saved crontab before retrying.')
names = {'greenbone-feed-sync', 'greenbone-nvt-sync', 'greenbone-scapdata-sync', 'greenbone-certdata-sync'}
pattern = re.compile(r'(?<![\w-])(?:' + '|'.join(sorted(names | {'gvm-feed-update', 'openvas-nvt-sync'})) + r')(?![\w-])')
paused, resumed = [], []
for line in original.splitlines(keepends=True):
    if line.lstrip().startswith('#') or not pattern.search(line):
        paused.append(line); resumed.append(line); continue
    match = re.match(r'^(\s*(?:@\w+\s+|(?:\S+\s+){5}))(.*?)(\r?\n)?$', line)
    if not match:
        raise SystemExit('Unrecognised feed cron entry: ' + line.rstrip())
    command = match.group(2)
    # Reject shell operators, expansion and cron stdin syntax instead of silently
    # leaving the feed job enabled or dropping custom arguments/redirections.
    if any(c in command for c in ';|&<>%$`#\\\n\r'):
        raise SystemExit('Suspend this custom feed cron shell command manually: ' + command)
    args = shlex.split(command)
    i = 0
    while i < len(args):
        token = args[i]
        if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=.*', token):
            i += 1; continue
        wrapper = PurePosixPath(token).name
        if wrapper == 'env':
            i += 1
            while i < len(args) and args[i].startswith('-'):
                flag = args[i]; i += 1
                if flag in ('-u', '--unset'):
                    if i == len(args): raise SystemExit('Missing env option value: ' + command)
                    i += 1
                elif flag not in ('-i', '--ignore-environment', '--') and not flag.startswith('--unset='):
                    raise SystemExit('Unsupported env wrapper: ' + command)
            continue
        if wrapper == 'sudo':
            i += 1
            while i < len(args) and args[i].startswith('-'):
                flag = args[i]; i += 1
                if flag in ('-u', '--user', '-g', '--group'):
                    if i == len(args): raise SystemExit('Missing sudo option value: ' + command)
                    i += 1
                elif flag not in ('-n', '--non-interactive', '-H', '--set-home', '-E', '--preserve-env', '--') and not flag.startswith(('--user=', '--group=')):
                    raise SystemExit('Unsupported sudo wrapper: ' + command)
            continue
        break
    if i == len(args) or PurePosixPath(args[i]).name not in names:
        raise SystemExit('Suspend this custom feed cron wrapper manually: ' + command)
    launcher = PurePosixPath(args[i]).name
    new, j = args[:i] + [executable], i + 1
    while j < len(args):
        if args[j] == '--feed-release':
            if j + 1 == len(args) or not re.fullmatch(r'\d+\.\d+', args[j+1]):
                raise SystemExit('Invalid --feed-release: ' + command)
            j += 2; continue
        if args[j].startswith('--feed-release='):
            if not re.fullmatch(r'--feed-release=\d+\.\d+', args[j]):
                raise SystemExit('Invalid --feed-release: ' + command)
            j += 1; continue
        new.append(args[j]); j += 1
    if launcher != 'greenbone-feed-sync':
        if any(a == '--type' or a.startswith('--type=') for a in new[i+1:]):
            raise SystemExit('Conflicting legacy feed launcher/type: ' + command)
        new += ['--type', {'greenbone-nvt-sync':'nvt', 'greenbone-scapdata-sync':'scap', 'greenbone-certdata-sync':'cert'}[launcher]]
    if release: new += ['--feed-release', release]
    paused.append(marker + line.rstrip('\r\n') + '\n')
    words = [shlex.quote(arg) for arg in new]
    # A shell assignment must keep its name/equal sign unquoted. env/sudo
    # arguments may be quoted as whole words, but leading assignments may not.
    for position, argument in enumerate(new):
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=.*', argument): break
        variable, value = argument.split('=', 1)
        words[position] = variable + '=' + shlex.quote(value)
    resumed.append(match.group(1) + ' '.join(words) + '\n')
Path(str(base) + '.paused').write_text(''.join(paused))
Path(str(base) + '.resume').write_text(''.join(resumed))
FEED_CRON
}

pause_migration_cron() {
    local owner
    local -a owners
    check_external_feed_schedules || return
    mkdir -p "$BACKUP_DIR/cron" || return
    # Debian/Ubuntu/Raspbian all store user crontabs here. Include every owner,
    # plus the standard accounts, so another user's feed job is also protected.
    sudo "$PYTHON_BIN" - "$(id -un)" <<'CRON_OWNERS' > "$BACKUP_DIR/cron/owners"
from pathlib import Path
import pwd, sys
owners = {'root', sys.argv[1]}
try:
    pwd.getpwnam('gvm'); owners.add('gvm')
except KeyError:
    pass
root = Path('/var/spool/cron/crontabs')
if root.exists():
    owners.update(p.name for p in root.iterdir() if not p.name.startswith('.'))
for owner in sorted(owners):
    pwd.getpwnam(owner)
    print(owner)
CRON_OWNERS
    [[ "$?" == 0 ]] || return 1
    mapfile -t owners < "$BACKUP_DIR/cron/owners"
    : > "$BACKUP_DIR/cron/paused-owners"
    : > "$BACKUP_DIR/cron/pending-owners"
    for owner in "${owners[@]}"; do
        read_migration_cron "$owner" "$BACKUP_DIR/cron/$owner.original" || return
        prepare_feed_cron "$BACKUP_DIR/cron/$owner" || return
        if ! cmp -s "$BACKUP_DIR/cron/$owner.original" "$BACKUP_DIR/cron/$owner.paused"; then
            printf '%s\n' "$owner" >> "$BACKUP_DIR/cron/pending-owners"
        fi
    done
    while IFS= read -r owner; do
        read_migration_cron "$owner" "$BACKUP_DIR/cron/$owner.current" || return
        cmp -s "$BACKUP_DIR/cron/$owner.original" "$BACKUP_DIR/cron/$owner.current" || {
            printf 'The %s crontab changed during preparation; not overwriting it.\n' "$owner" >&2
            return 1
        }
        printf '%s\n' "$owner" >> "$BACKUP_DIR/cron/paused-owners"
        sudo crontab -u "$owner" - < "$BACKUP_DIR/cron/$owner.paused" || return
        printf 'Paused feed jobs for %s.\n' "$owner"
    done < "$BACKUP_DIR/cron/pending-owners"
}

check_migration_feed_idle() {
    local processes status deadline=$((SECONDS + FEED_WAIT_SECONDS))
    while true; do
        if processes=$(pgrep -f '(^|/|[[:space:]])(greenbone-(feed|nvt|scapdata|certdata)-sync|gvm-feed-update|openvas-nvt-sync)([[:space:]]|$)'); then
            (( SECONDS < deadline )) || {
                printf 'Feed sync still running (PIDs: %s); timed out after %s seconds.\n' "$processes" "$FEED_WAIT_SECONDS" >&2
                return 1
            }
            sleep 2
        else
            status=$?
            (( status == 1 )) || return "$status"
            return 0
        fi
    done
}

restore_migration_cron() {
    local variant="${1:-resume}" owner target status=0
    local -a pending=() restored=()
    [[ "$variant" == original || "$variant" == resume ]] || return 1
    [[ -f "$BACKUP_DIR/cron/paused-owners" ]] || return 0
    # Validate every owner before changing the first crontab. Keep unrelated
    # concurrent edits, and roll back a partial resume if installation fails.
    while IFS= read -r owner; do
        target="$BACKUP_DIR/cron/$owner.$variant"
        if ! read_migration_cron "$owner" "$BACKUP_DIR/cron/$owner.current"; then status=1; continue; fi
        if cmp -s "$target" "$BACKUP_DIR/cron/$owner.current"; then continue; fi
        if ! cmp -s "$BACKUP_DIR/cron/$owner.paused" "$BACKUP_DIR/cron/$owner.current"; then
            printf 'The %s crontab changed. Keep those edits and merge %s manually.\n' "$owner" "$target" >&2
            status=1; continue
        fi
        pending+=("$owner")
    done < "$BACKUP_DIR/cron/paused-owners"
    (( status == 0 )) || return "$status"
    for owner in "${pending[@]}"; do
        target="$BACKUP_DIR/cron/$owner.$variant"
        if ! read_migration_cron "$owner" "$BACKUP_DIR/cron/$owner.current" ||
            ! cmp -s "$BACKUP_DIR/cron/$owner.paused" "$BACKUP_DIR/cron/$owner.current"; then
            printf 'The %s crontab changed during restoration; not overwriting it.\n' "$owner" >&2
            status=1; break
        fi
        if ! sudo crontab -u "$owner" - < "$target"; then status=1; break; fi
        restored+=("$owner")
        printf 'Restored %s feed schedule for %s.\n' "$variant" "$owner"
    done
    if (( status != 0 )) && [[ "$variant" == resume ]]; then
        for owner in "${restored[@]}"; do
            if read_migration_cron "$owner" "$BACKUP_DIR/cron/$owner.current" &&
                cmp -s "$BACKUP_DIR/cron/$owner.resume" "$BACKUP_DIR/cron/$owner.current"; then
                sudo crontab -u "$owner" - < "$BACKUP_DIR/cron/$owner.paused" || true
            fi
        done
    fi
    return "$status"
}
# END SHARED FEED SCHEDULE HELPERS

prepare_all_sources() {
    run_logged_task "Preparing gvm-libs $GVM_LIBS_VERSION sources" download_source gvm-libs "$GVM_LIBS_VERSION" "gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc"
    run_logged_task "Preparing gvmd $GVMD_VERSION sources" download_source gvmd "$GVMD_VERSION" "gvmd-$GVMD_VERSION.tar.gz.asc"
    run_logged_task "Preparing pg-gvm $PG_GVM_VERSION sources" download_source pg-gvm "$PG_GVM_VERSION" "pg-gvm-$PG_GVM_VERSION.tar.gz.asc"
    run_logged_task "Preparing gsad $GSAD_VERSION sources" download_source gsad "$GSAD_VERSION" "gsad-$GSAD_VERSION.tar.gz.asc"
    run_logged_task "Preparing openvas-smb $OPENVAS_SMB_VERSION sources" download_source openvas-smb "$OPENVAS_SMB_VERSION" "openvas-smb-v$OPENVAS_SMB_VERSION.tar.gz.asc"
    run_logged_task "Preparing openvas-scanner $OPENVAS_SCANNER_VERSION sources" download_source openvas-scanner "$OPENVAS_SCANNER_VERSION" "openvas-scanner-v$OPENVAS_SCANNER_VERSION.tar.gz.asc"
    run_logged_task "Preparing ospd-openvas $OSPD_OPENVAS_VERSION sources" download_source ospd-openvas "$OSPD_OPENVAS_VERSION" "ospd-openvas-v$OSPD_OPENVAS_VERSION.tar.gz.asc"
    run_logged_task "Preparing greenbone-feed-sync $FEED_SYNC_VERSION sources" download_source greenbone-feed-sync "$FEED_SYNC_VERSION" "greenbone-feed-sync-$FEED_SYNC_VERSION.tar.gz.asc"
    run_logged_task "Preparing python-gvm $PYTHON_GVM_VERSION sources" download_source python-gvm "$PYTHON_GVM_VERSION" "python-gvm-$PYTHON_GVM_VERSION.tar.gz.asc"
    run_logged_task "Preparing gvm-tools $GVM_TOOLS_VERSION sources" download_source gvm-tools "$GVM_TOOLS_VERSION" "gvm-tools-$GVM_TOOLS_VERSION.tar.gz.asc"
    # Upstream publishes no detached signature for pypsrp-cli.
    run_logged_task "Downloading pypsrp-cli $PYPSRP_CLI_VERSION sources (HTTPS)" download_source pypsrp-cli "$PYPSRP_CLI_VERSION"
    local archive="$SOURCE_DIR/gsa-$GSA_VERSION.tar.gz"
    run_logged_task "Downloading GSA $GSA_VERSION web assets" curl -f -sS -L --retry 3 "https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz" -o "$archive"
    run_logged_task 'Downloading the GSA signature' curl -f -sS -L --retry 3 "https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz.asc" -o "$archive.asc"
    run_logged_task 'Verifying the GSA signature' verify_source_signature "$archive.asc" "$archive"
    mkdir -p "$SOURCE_DIR/gsa-$GSA_VERSION"
    run_logged_task "Extracting GSA $GSA_VERSION" tar -C "$SOURCE_DIR/gsa-$GSA_VERSION" -xzf "$archive"
    [[ -f "$SOURCE_DIR/gsa-$GSA_VERSION/index.html" ]] || die 'The GSA archive has no index.html.'
}

##############################################################################
# Do not edit settings below this point.
##############################################################################

GVM_SERVICES=(gsad gvmd ospd-openvas openvasd)
SERVICE_PATH="$INSTALL_PREFIX/bin:$INSTALL_PREFIX/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
MAINTENANCE_STARTED=false
UPGRADE_LOCKED=false
UPGRADE_COMPLETE=false
FEED_SYNC_FAILED=false
LEGACY_MIGRATION=false
MIGRATION_TEST_DB=""
MIGRATION_TEST_CREATED=false
LEGACY_KEY_DIR=""
LEGACY_GVM_HOME=""
UPGRADER_PID=$BASHPID
sudo_keepalive_pid=""
RUN_DIR=""
BUILD_LOG=""
BACKUP_DIR=""
PROGRESS_PID=""
PROGRESS_LABEL=""
PROGRESS_STARTED=0
PROGRESS_FD=1
PROGRESS_INLINE=false
OUTPUT_PID=""
GREY="" GREYB="" LGREEN="" LGREENB="" LRED="" LPURPLE="" LPURPLEB="" LYELLOW="" NC=""

# BEGIN SHARED PROGRESS DISPLAY
# Keep this region identical in all three standalone scripts.
PROGRESS_OWNER_PID=$BASHPID
PROGRESS_PID=""
PROGRESS_LABEL=""
PROGRESS_STARTED=0
PROGRESS_FD=5
exec 5>&1
PROGRESS_INLINE=false
PROGRESS_TERMINAL=false
OUTPUT_PID=""
# shellcheck disable=SC2034  # Full shared palette is intentional.
init_style() {
    # Detect the terminal before logging redirects stdout; use the installer's palette.
    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
        PROGRESS_INLINE=true
        GREY=$'\033[0;37m'
        GREYB=$'\033[1;37m'
        LGREEN=$'\033[0;92m'
        LGREENB=$'\033[1;92m'
        LRED=$'\033[0;91m'
        LPURPLE=$'\033[0;95m'
        LPURPLEB=$'\033[1;95m'
        LYELLOW=$'\033[0;93m'
        NC=$'\033[0m'
    fi
}

section() {
    [[ -z "$PROGRESS_LABEL" ]] || die "Cannot change section while a task is still active: $PROGRESS_LABEL"
    local width=79 terminal_fd=5 rule
    if [[ -t 3 ]]; then terminal_fd=3; fi
    if [[ "$PROGRESS_TERMINAL" == true && -t "$terminal_fd" && -x "$PYTHON_BIN" ]]; then
        width=$("$PYTHON_BIN" -c 'import os, sys; print(max(1, min(79, os.get_terminal_size(int(sys.argv[1])).columns - 1)))' "$terminal_fd") || width=79
    fi
    printf -v rule '%*s' "$width" ''
    rule="${rule// /#}"
    printf '\n%s%s\n %s\n%s%s\n\n' "$LGREEN" "$rule" "$*" "$rule" "$NC"
}

# Initialize colours before logging redirects stdout, as in the upgrade script.
init_style
PROGRESS_TERMINAL="$PROGRESS_INLINE"

elapsed_time() {
    local seconds="$1"
    printf '%02d:%02d:%02d' "$((seconds / 3600))" "$((seconds / 60 % 60))" "$((seconds % 60))"
}

validate_progress_interval() {
    [[ "$PROGRESS_INTERVAL" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ && "$PROGRESS_INTERVAL" == *[1-9]* ]] ||
        die 'PROGRESS_INTERVAL must be greater than zero (for example, 0.2 or 10).'
}

print_progress() {
    local complete="$1" text="$2"
    if [[ "$PROGRESS_INLINE" == true ]]; then
        # Send a complete record to the same pipe as command output. A single
        # terminal writer prevents the spinner and compiler messages colliding.
        printf '\036%s%s\037' "$complete" "$text" >&"$PROGRESS_FD"
    else
        printf '%s\n' "$text" >&"$PROGRESS_FD"
    fi
}

terminal_output() {
    exec 9>&-
    trap - ERR EXIT INT TERM HUP
    "$PYTHON_BIN" -u - "$BUILD_LOG" 4<&0 <<'PY'
import os
import re
import sys

ansi = re.compile(rb"\x1b\[[0-9;]*m")
output = sys.stdout.buffer
log = open(sys.argv[1], "ab", buffering=0)
visible = False
line_start = True

def command_output(data):
    global visible, line_start
    if not data:
        return
    log.write(ansi.sub(b"", data))
    if visible:
        output.write(b"\r\x1b[2K")
        visible = False
    # Reset the column explicitly, even while sudo changes terminal settings.
    output.write(data.replace(b"\n", b"\r\n"))
    line_start = data.endswith((b"\n", b"\r"))
    output.flush()

def progress(record):
    global visible, line_start
    complete, text = record[:1] == b"1", record[1:]
    plain = ansi.sub(b"", text).decode("utf-8", errors="replace")
    # Store starts/completions; timer frames belong on the terminal only.
    if complete or b"[>]" in text:
        log.write(plain.encode("utf-8") + b"\n")
    # Never erase a command's unfinished output line for a timer update.
    if not line_start and not complete:
        return
    if not line_start:
        output.write(b"\r\n")
    try:
        width = max(1, os.get_terminal_size(1).columns - 1)
    except OSError:
        width = 79
    if len(plain) > width:
        # Keep elapsed time visible and avoid wrapping onto another screen row.
        suffix = re.search(r" \[(?:exit \d+; )?\d+:\d{2}:\d{2} elapsed\]$", plain)
        tail = suffix.group() if suffix else ""
        room = width - len(tail)
        clipped = plain[:max(0, room - 3)] + "..." + tail if room >= 3 else plain[-width:]
        colour = ansi.match(text)
        text = (colour.group() if colour else b"") + clipped.encode("utf-8") + b"\x1b[0m"
    output.write(b"\r\x1b[2K" + text)
    visible = not complete
    line_start = True
    if complete:
        output.write(b"\r\n")
    output.flush()

pending = b""
while True:
    chunk = os.read(4, 65536)
    if not chunk:
        break
    pending += chunk
    while pending:
        start = pending.find(b"\x1e")
        if start < 0:
            command_output(pending)
            pending = b""
            break
        command_output(pending[:start])
        pending = pending[start:]
        end = pending.find(b"\x1f", 1)
        if end < 0:
            break
        record, pending = pending[1:end], pending[end + 1:]
        if record[:1] in (b"0", b"1"):
            progress(record)
        else:
            command_output(b"\x1e" + record + b"\x1f")
command_output(pending)
if visible:
    output.write(b"\r\n")
    output.flush()
PY
}

start_logging() {
    validate_progress_interval
    exec 3>&1 4>&2
    PROGRESS_FD=1
    # Python is installed by COMMON_DEPS on minimal systems. Keep the existing
    # tee logger until it is available, then enable the terminal renderer.
    if [[ "$PROGRESS_TERMINAL" == true && -x "$PYTHON_BIN" ]]; then
        PROGRESS_INLINE=true
        exec > >(terminal_output) 2>&1
    else
        PROGRESS_INLINE=false
        exec > >(tee -a "$BUILD_LOG") 2>&1
    fi
    OUTPUT_PID=$!
    exec 5>&1
    PROGRESS_FD=5
}

stop_logging() {
    if [[ -n "$OUTPUT_PID" ]]; then
        exec 1>&3 2>&4 5>&3
        wait "$OUTPUT_PID" || true
        exec 3>&- 4>&-
        OUTPUT_PID=""
        PROGRESS_INLINE=false
    fi
}

enable_terminal_progress() {
    if [[ "$PROGRESS_TERMINAL" == true && "$PROGRESS_INLINE" != true && -x "$PYTHON_BIN" ]]; then
        stop_logging
        start_logging
    fi
}

progress_loop() {
    local parent_pid="$1" started="$2" label="$3"
    exec 9>&-
    local frames='|/-\' frame=0 elapsed last_plain=0 sleeper=""
    # This helper only reports status; the actual task stays in the main shell.
    # Reap the timer sleep when the display stops.
    trap - ERR EXIT
    trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi' EXIT
    trap 'exit 0' INT TERM HUP
    while kill -0 "$parent_pid" 2>/dev/null; do
        sleep "$PROGRESS_INTERVAL" &
        sleeper=$!
        wait "$sleeper"
        sleeper=""
        elapsed=$((SECONDS - started))
        # A fast animation is useful on a terminal; plain logs need fewer lines.
        if [[ "$PROGRESS_INLINE" == true ]] || (( elapsed - last_plain >= 10 )); then
            print_progress 0 "${LPURPLE}[${frames:frame%${#frames}:1}]${NC} $label [$(elapsed_time "$elapsed") elapsed]" >&"$PROGRESS_FD"
            last_plain=$elapsed
        fi
        frame=$((frame + 1))
    done
}

finish_progress() {
    # Subshell error/exit traps must leave the main shell's reporter alone.
    [[ "$BASHPID" == "$PROGRESS_OWNER_PID" ]] || return 0
    local status="${1:-0}" elapsed
    if [[ -n "$PROGRESS_PID" ]]; then
        kill "$PROGRESS_PID" 2>/dev/null || true
        wait "$PROGRESS_PID" 2>/dev/null || true
        PROGRESS_PID=""
    fi
    if [[ -n "$PROGRESS_LABEL" ]]; then
        elapsed=$(elapsed_time "$((SECONDS - PROGRESS_STARTED))")
        if (( status == 0 )); then
            print_progress 1 "${LGREEN}[OK] $PROGRESS_LABEL [$elapsed elapsed]${NC}"
        else
            print_progress 1 "${LRED}[FAILED] $PROGRESS_LABEL [exit $status; $elapsed elapsed]${NC}" >&2
        fi
        PROGRESS_LABEL=""
    fi
}

start_progress() {
    PROGRESS_LABEL="$1"
    PROGRESS_STARTED=$SECONDS
    print_progress 0 "${LPURPLE}[>]${NC} $PROGRESS_LABEL ..."
    progress_loop "$BASHPID" "$PROGRESS_STARTED" "$PROGRESS_LABEL" &
    PROGRESS_PID=$!
}

run_task() {
    local task_status
    start_progress "$1"
    shift
    # Keep the command in this shell: exports, cwd, stdin and errexit survive.
    "$@"
    task_status=$?
    finish_progress "$task_status"
    return "$task_status"
}

run_optional_task() {
    local status=0
    start_progress "$1"
    shift
    "$@" || status=$?
    finish_progress "$status"
    return "$status"
}

log_task_output() {
    "$@" >> "$BUILD_LOG" 2>&1
}

run_logged_task() {
    local label="$1"
    shift
    run_task "$label" log_task_output "$@"
}

component_done() {
    [[ -z "$PROGRESS_LABEL" ]] || die "A component still has an active task: $PROGRESS_LABEL"
    printf '\n%s[OK] %s %s installed successfully.%s\n' "$LGREEN" "$1" "$2" "$NC"
}
# END SHARED PROGRESS DISPLAY

save_output() {
    local destination="$1"
    shift
    "$@" > "$destination"
}

die() {
    exec 1>&"$PROGRESS_FD" 2>&"$PROGRESS_FD"
    finish_progress 1
    printf '\n%sERROR: %s%s\n' "$LRED" "$*" "$NC" >&2
    exit 1
}



upgrade_failed() {
    local status="$1" line="$2"
    trap - ERR
    exec 1>&"$PROGRESS_FD" 2>&"$PROGRESS_FD"
    finish_progress "$status"
    printf '\n%sUpgrade failed at line %s (exit %s).\nLog: %s%s\n' \
        "$LRED" "$line" "$status" "$BUILD_LOG" "$NC" >&2
    exit "$status"
}

cleanup() {
    local status="${1:-$?}"
    # A reporter killed just after forking may still inherit this EXIT trap.
    # Only the main shell may finish tasks, stop services or drain the log pipe.
    [[ "$BASHPID" == "$UPGRADER_PID" ]] || return "$status"
    trap - EXIT ERR
    exec 1>&"$PROGRESS_FD" 2>&"$PROGRESS_FD"
    finish_progress "$status"
    if [[ "$MAINTENANCE_STARTED" != true && -n "$BACKUP_DIR" &&
          -f "$BACKUP_DIR/cron/paused-owners" ]]; then
        # No installation changes have begun: undo a pause on timeout/cancellation.
        if ! restore_migration_cron original; then
            printf 'Could not restore every original feed schedule. Recovery files: %s/cron\n' "$BACKUP_DIR" >&2
        fi
    fi
    if [[ "$MAINTENANCE_STARTED" == true && "$UPGRADE_COMPLETE" != true ]]; then
        # Do not leave a partially upgraded set of daemons running after a failure.
        sudo -n systemctl stop "${GVM_SERVICES[@]}" || true
        printf '\nGVM services were stopped. Work and recovery files retained at: %s\n' "$RUN_DIR" >&2
    fi
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        if [[ "$MAINTENANCE_STARTED" == true && ! -f "$RUN_DIR/upgrade-complete.txt" ]]; then
            printf 'Feed cron recovery files, if paused: %s/cron\n' "$BACKUP_DIR" >&2
        fi
        if [[ "$MIGRATION_TEST_CREATED" == true ]]; then
            printf 'Rehearsal database retained for inspection: %s (live database: %s)\n' "$MIGRATION_TEST_DB" "$DB_NAME" >&2
        fi
    fi
    if [[ -n "$sudo_keepalive_pid" ]]; then
        kill "$sudo_keepalive_pid" 2>/dev/null || true
        wait "$sudo_keepalive_pid" 2>/dev/null || true
    fi
    if [[ "$UPGRADE_LOCKED" == true ]]; then
        flock -u 9 || true
        exec 9<&-
        UPGRADE_LOCKED=false
    fi
    if [[ -n "$OUTPUT_PID" ]]; then
        # Drain the output pipe before returning, including the final result.
        exec 1>&3 2>&4 5>&3
        wait "$OUTPUT_PID" || true
        OUTPUT_PID=""
    fi
    return "$status"
}



start_sudo_keepalive() {
    local upgrader_pid=$$
    sudo -v
    (
        # Do not let the refresher hold the upgrade lock after the parent exits.
        exec 9>&-
        sleeper=""
        trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi' EXIT
        trap 'exit 0' TERM INT HUP
        while kill -0 "$upgrader_pid" 2>/dev/null; do
            sudo -n -v || exit 1
            sleep 60 &
            sleeper=$!
            wait "$sleeper"
            sleeper=""
        done
    ) &
    sudo_keepalive_pid=$!
}

as_postgres() {
    (cd /; sudo -H -u postgres "$@")
}

psql_db() {
    as_postgres "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 \
        --host="$DB_HOST" --port="$DB_PORT" --dbname="$DB_NAME" "$@"
}

as_gvm() {
    (cd /; sudo -H -u gvm env PATH="$SERVICE_PATH" "$@")
}

select_postgresql_major() {
    local server_version="$1" detected
    [[ "$server_version" =~ ^[0-9]+$ ]] || die "Cannot determine the existing PostgreSQL server version."
    detected=$((server_version / 10000))
    [[ -z "$POSTGRESQL_MAJOR" || "$POSTGRESQL_MAJOR" == "$detected" ]] || \
        die "PostgreSQL $detected is running; this script does not change its major version."
    POSTGRESQL_MAJOR="$detected"
}

detect_postgresql() {
    local server_version tool
    server_version=$(as_postgres psql -X -At --host="$DB_HOST" --port="$DB_PORT" \
        --dbname="$DB_NAME" -c 'SHOW server_version_num;')
    select_postgresql_major "$server_version"
    PG_BIN="/usr/lib/postgresql/$POSTGRESQL_MAJOR/bin"
    PG_CONFIG="$PG_BIN/pg_config"
    local -a required_tools=(psql)
    if [[ "$SKIP_MIGRATION_REHEARSAL" != true ]]; then
        required_tools+=(pg_dump pg_dumpall pg_restore)
        if [[ "$LEGACY_MIGRATION" == true ]]; then required_tools+=(createdb dropdb); fi
    fi
    for tool in "${required_tools[@]}"; do
        [[ -x "$PG_BIN/$tool" ]] || die "Missing PostgreSQL client: $PG_BIN/$tool"
    done
    GVMD_DEPS1+=("postgresql-$POSTGRESQL_MAJOR" "postgresql-server-dev-$POSTGRESQL_MAJOR")
    PGGVM_DEPS+=("postgresql-$POSTGRESQL_MAJOR" "postgresql-server-dev-$POSTGRESQL_MAJOR")
    # pg_config is checked after install_dependencies installs the development package.
    if [[ -n "${VERSION_LOG:-}" ]]; then
        printf 'POSTGRESQL_MAJOR=%s\n' "$POSTGRESQL_MAJOR" >> "$VERSION_LOG"
    fi
    printf 'Existing PostgreSQL major: %s\n' "$POSTGRESQL_MAJOR"
}

check_existing_installation() {
    local binary app service state
    id gvm >/dev/null
    for binary in sbin/gvmd sbin/gsad sbin/openvas bin/openvasd bin/scannerctl; do
        sudo -u gvm test -x "$INSTALL_PREFIX/$binary" || die "Existing executable unavailable to gvm: $INSTALL_PREFIX/$binary"
    done
    if [[ "$LEGACY_MIGRATION" != true ]]; then
        for app in ospd-openvas greenbone-feed-sync gvm-tools pypsrp-cli; do
            sudo -u gvm test -x "$PYTHON_ENV_DIR/$app/bin/python" ||
                die "Python environment missing/unreadable: $app. Use --check to assess an older installation, then --migrate-legacy if supported."
        done
    fi
    for binary in /etc/openvas/openvas.conf /etc/redis/redis-openvas.conf; do
        sudo test -f "$binary" || die "Existing configuration missing: $binary"
    done
    for service in "${GVM_SERVICES[@]}" redis-server@openvas; do
        state=$(systemctl show "$service.service" --property=LoadState --value)
        [[ "$state" == loaded ]] || die "Existing service missing: $service.service"
    done
    read -r GVMD_OWNER GVMD_MODE < <(stat -Lc '%u:%g %a' "$INSTALL_PREFIX/sbin/gvmd")
    [[ -n "$GVMD_OWNER" && "$GVMD_MODE" =~ ^[0-7]+$ ]] || die "Cannot record gvmd permissions."
}


upgrade_usage() {
    cat <<'HELP'
Usage: bash openvas-migrate-legacy.sh [--check | --migrate-legacy] [--skip-migration-rehearsal]

No option: upgrade an installation already using /opt/gvm/venvs.
--check: inspect the installation and database without changing services,
         packages, cron jobs, configuration or the database.
--migrate-legacy: migrate a source installation using the older global/user
         Python layout to the October 2026 layout, then upgrade its components.
--skip-migration-rehearsal: skip ALL backup archives/dumps and copies of replaced
         files, plus the restored-copy test and its free-space checks.
         The live migration and final account/key checks still run. Small cron
         recovery files, account/key checks and file-metadata records are retained.
         Also available as SKIP_MIGRATION_REHEARSAL=true in the settings/environment.

Example: bash openvas-migrate-legacy.sh --migrate-legacy --skip-migration-rehearsal

Run as your normal sudo-enabled user. Edit FORCE_*_VERSION settings to pin
releases; blank selects latest stable. OSPD has its own release selection.
openvasd and scannerctl both use the selected openvas-scanner source release.

Legacy support is limited to the original systemd layout with all four services,
/usr/local binaries, /etc/openvas, /var/lib/gvm and the local gvmd database.
Package/container installs, notus-only layouts and custom service commands need
a separate migration plan. --check reports these rather than deleting anything.

Before migration: stop scans, take a VM/disk snapshot, allow space for a full
state/program backup and a restored database copy unless backups/rehearsal are
skipped. Builds and live migration always require working space.
Suspend custom feed wrappers/timers; detected external jobs are rejected before maintenance.
Recognised feed cron commands are paused automatically;
running syncs are given FEED_WAIT_SECONDS (default 600) to finish before services
are stopped. Early failure restores original cron jobs; failure after maintenance
starts leaves them paused for repair. Schedules are restored after success.
FORCE_FEED_RELEASE is optional;
blank leaves feed selection to feed-sync's defaults/configuration.

Rehearsal free-space threshold: database size x MIGRATION_TEST_SPACE_PERCENT / 100,
plus 1 GiB. Default: 200; 150 allows less headroom. Lowering the threshold does
not reduce the restore's actual disk use or guarantee enough space.

BUILD_JOBS defaults to 2. APT_AUTOREMOVE defaults to false; setting it to
true runs APT autoremove before starting and checking services.
AUTO_REMOVE_PACKAGES is accepted as a legacy environment alias.
Feed downloads repair existing lock-file ownership/modes before every attempt.
FEED_SYNC_ATTEMPTS defaults to 3 and FEED_SYNC_RETRY_DELAY to 60 seconds.
Exhausted retries are reported with a saved retry script and do not prevent
the upgraded services from starting.

Migration and upgrade share /run/lock/easy-openvas-maintenance.lock, including
runs from different accounts or work folders. Use the accompanying upgrader.
WORK_ROOT must be absolute without whitespace; BUILD_LOG_DIR must be absolute.
Package arrays are embedded and kept identical in the three accompanying scripts.
--check does not acquire the maintenance lock.

No existing users, roles, passwords, keys, certificates or live database are recreated.
The rehearsal creates and restores a separate temporary database.
System Python packages and services are retained by default. Optional APT
autoremove can remove packages marked unused. PostgreSQL stays on its existing
major version. Failure before successful service checks leaves GVM
stopped for repair. Paused feed jobs, backups and any failed rehearsal database
are retained until recovery or successful completion.
HELP
}

capture_accounts() {
    local database="$1" destination="$2"
    as_postgres "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 \
        --host="$DB_HOST" --port="$DB_PORT" --dbname="$database" \
        -c 'COPY (SELECT uuid, name FROM public.users ORDER BY uuid) TO STDOUT WITH (FORMAT csv)' \
        > "$destination"
}

check_migration_database_space() {
    if [[ "$SKIP_MIGRATION_REHEARSAL" == true ]]; then
        printf 'Migration rehearsal free-space check skipped.\n'
        return
    fi
    local bytes directory available required
    [[ "$MIGRATION_TEST_SPACE_PERCENT" =~ ^[1-9][0-9]{2,3}$ ]] &&
        (( MIGRATION_TEST_SPACE_PERCENT <= 1000 )) ||
        die 'MIGRATION_TEST_SPACE_PERCENT must be an integer from 100 to 1000.'
    bytes=$(psql_db -At -c 'SELECT pg_database_size(current_database());')
    directory=$(psql_db -At -c 'SHOW data_directory;')
    [[ "$bytes" =~ ^[0-9]+$ && "$directory" == /* ]] || die 'Cannot assess PostgreSQL storage.'
    available=$(sudo df -PB1 -- "$directory" | awk 'NR == 2 { print $4 }')
    [[ "$available" =~ ^[0-9]+$ ]] || die 'Cannot read free space on the PostgreSQL filesystem.'
    # A configurable estimate for the restored copy, indexes and WAL; not a reservation.
    required=$(((bytes * MIGRATION_TEST_SPACE_PERCENT + 99) / 100 + 1073741824))
    (( available >= required )) || die "Insufficient free PostgreSQL space for rehearsal: $available bytes available, at least $required required."
    printf 'Database size: %s bytes; free PostgreSQL space: %s bytes (minimum floor: %s).\n' "$bytes" "$available" "$required"
}

check_legacy_layout() {
    local service expected actual state owner path home
    [[ "$INSTALL_PREFIX" == /usr/local && "$PYTHON_ENV_DIR" == /opt/gvm/venvs ]] ||
        die 'Automatic legacy migration supports /usr/local and /opt/gvm/venvs only.'
    [[ "$DB_NAME" == gvmd && "$DB_HOST" == /var/run/postgresql && "$DB_PORT" == 5432 ]] ||
        die 'A custom database endpoint needs a separate migration plan.'
    for service in "${GVM_SERVICES[@]}"; do
        case "$service" in
            gsad|gvmd) expected="$INSTALL_PREFIX/sbin/$service" ;;
            *) expected="$INSTALL_PREFIX/bin/$service" ;;
        esac
        actual=$(systemctl show "$service.service" --property=ExecStart --value)
        [[ "$actual" == *"path=$expected ;"* || "$actual" == *"path=$expected;"* ]] ||
            die "Custom $service ExecStart needs manual review; expected $expected."
        [[ "$actual" != *--database* && "$actual" != *--db-host* && "$actual" != *--db-port* ]] ||
            die "Custom database arguments in $service.service need manual review."
        if [[ "$service" != gsad ]]; then
            owner=$(systemctl show "$service.service" --property=User --value)
            [[ "$owner" == gvm ]] || die "$service.service must run as the existing gvm account."
        fi
    done
    state=$(systemctl show notus-scanner.service --property=LoadState --value 2>/dev/null) || state=not-found
    [[ "$state" != loaded ]] || die 'A notus-scanner service needs a separate migration plan.'
    if dpkg-query -S "$INSTALL_PREFIX/sbin/gvmd" >/dev/null 2>&1; then
        die 'The manager binary is package-owned; this migration is for source installations.'
    fi
    for path in /var/lib/gvm /var/lib/openvas /var/lib/notus; do
        sudo test -d "$path" || die "Expected legacy data directory missing: $path"
        if sudo test -L "$path"; then
            die "Custom data symlink needs a separate backup/migration plan: $path"
        fi
    done
    for path in /etc/gvm /etc/openvas /etc/redis/redis-openvas.conf; do
        if sudo test -L "$path"; then
            die "Custom configuration symlink needs a separate migration plan: $path"
        fi
    done
    # Losing this key can make saved scan credentials unusable even with a good DB.
    LEGACY_KEY_DIR=/var/lib/gvm/gvmd/gnupg
    sudo test -d "$LEGACY_KEY_DIR" || die "Credential encryption key directory missing: $LEGACY_KEY_DIR. Restore/review it first; do not generate a replacement."
    home=$(getent passwd gvm | cut -d: -f6)
    [[ "$home" == /* && "$home" != / ]] || die 'Cannot identify the existing gvm home directory.'
    LEGACY_GVM_HOME="$home"
    if sudo test -L "$home"; then
        die "The gvm home is a symlink; review the external key/data backup first: $home"
    fi
    owner=$(psql_db -At -c 'SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database();')
    [[ "$owner" == gvm ]] || die 'Expected the existing gvmd database to be owned by gvm.'
    psql_db -At -c "SELECT value FROM public.meta WHERE name = 'database_version';"
    psql_db -At -c 'SELECT count(*) FROM public.users;'
    printf 'Legacy profile recognised. Existing gvm UID/GID: %s\n' "$(id -u gvm):$(id -g gvm)"
}

show_layout_report() {
    local app missing=0
    section 'OpenVAS layout assessment (no installation changes)'
    check_existing_installation
    detect_postgresql
    check_legacy_layout
    check_migration_database_space
    for app in ospd-openvas greenbone-feed-sync gvm-tools pypsrp-cli; do
        if sudo -u gvm test -x "$PYTHON_ENV_DIR/$app/bin/python"; then
            printf '[OK] Python environment: %s\n' "$app"
        else
            printf '[>] Needs an isolated Python environment: %s\n' "$app"
            missing=$((missing + 1))
        fi
    done
    if (( missing > 0 )); then
        printf '\nUse --migrate-legacy after completing the snapshot and maintenance preparation.\n'
    else
        printf '\nAll four Python environments exist; the normal upgrade path is available.\n'
    fi
    printf 'Keep the gvm account, database, /var/lib/gvm, /var/lib/openvas, /var/lib/notus,\n'
    printf '/etc/gvm, /etc/openvas, existing keys, certificates and service units.\n'
    if [[ "$SKIP_MIGRATION_REHEARSAL" == true ]]; then
        printf 'Assessment checks layout only; the upgrade will migrate the live database without a rehearsal.\n'
    else
        printf 'Assessment checks layout only; a successful restored-copy migration is still required.\n'
    fi
}







capture_gvm_identity() {
    "$PYTHON_BIN" - <<'GVM_IDENTITY'
import json, os, pwd
account = pwd.getpwnam('gvm')
print(json.dumps(dict(uid=account.pw_uid, gid=account.pw_gid,
    home=account.pw_dir, shell=account.pw_shell,
    groups=sorted(set(os.getgrouplist(account.pw_name, account.pw_gid)))), sort_keys=True))
GVM_IDENTITY
}

verify_legacy_account() {
    capture_gvm_identity > "$BACKUP_DIR/gvm-account-after.txt"
    cmp -s "$BACKUP_DIR/gvm-account.txt" "$BACKUP_DIR/gvm-account-after.txt" ||
        die 'Linux gvm account identity changed; keep services stopped and review the UID, GID, home, shell and group verification records.'
}

record_legacy_identity() {
    run_task 'Recording the existing account UUIDs and names' capture_accounts "$DB_NAME" "$BACKUP_DIR/users-before.csv"
    # Store hashes, not private key copies; these are also used when backups are skipped.
    sudo find "$LEGACY_KEY_DIR" -type f \( -name '*.key' -o -name secring.gpg \) \
        -exec sha256sum -- {} + > "$BACKUP_DIR/credential-key-checksums.txt"
    [[ -s "$BACKUP_DIR/credential-key-checksums.txt" ]] ||
        die 'No credential encryption private key found. Review/restore the key before migration.'
    capture_gvm_identity > "$BACKUP_DIR/gvm-account.txt"
}

backup_legacy_state() {
    local path
    local -a paths=(var/lib/gvm var/lib/openvas var/lib/notus)
    if [[ "$LEGACY_GVM_HOME" != /var/lib/gvm ]] && sudo test -d "$LEGACY_GVM_HOME"; then
        paths+=("${LEGACY_GVM_HOME#/}")
    fi
    run_task 'Backing up scan data and credential encryption keys' save_output "$BACKUP_DIR/legacy-state.tar.gz" \
        sudo tar --acls --xattrs -C / -czf - "${paths[@]}"
    tar -tzf "$BACKUP_DIR/legacy-state.tar.gz" > /dev/null
    paths=()
    for path in "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/sbin" "$INSTALL_PREFIX/lib" \
        "$INSTALL_PREFIX/lib64" "$INSTALL_PREFIX/share/gvm" "$INSTALL_PREFIX/share/openvas" \
        "/usr/lib/postgresql/$POSTGRESQL_MAJOR/lib/pg-gvm.so"; do
        if sudo test -e "$path"; then paths+=("${path#/}"); fi
    done
    for path in /usr/share/postgresql/"$POSTGRESQL_MAJOR"/extension/*gvm*; do
        [[ -e "$path" ]] && paths+=("${path#/}")
    done
    run_task 'Backing up the existing local program and Python files' save_output "$BACKUP_DIR/legacy-programs.tar.gz" \
        sudo tar --acls --xattrs -C / -czf - "${paths[@]}"
    tar -tzf "$BACKUP_DIR/legacy-programs.tar.gz" > /dev/null
    record_legacy_identity
    dpkg-query -W > "$BACKUP_DIR/packages-before.txt"
    for path in "${GVM_SERVICES[@]}" redis-server@openvas; do
        systemctl cat "$path.service" > "$BACKUP_DIR/$path.service.txt"
    done
    printf 'Manual recovery requires matching program files, database, keys and configuration.\n' > "$BACKUP_DIR/RECOVERY.txt"
    printf 'After failure, restore saved cron files only after repairing the installation.\n' >> "$BACKUP_DIR/RECOVERY.txt"
}



configure_legacy_runtime() {
    local command marker
    for command in ospd-openvas greenbone-feed-sync gvm-cli pypsrp-cli; do
        run_task "Checking $command as the existing gvm user" as_gvm "$command" --help
    done
    # Preserve ExecStart, sockets, certificates, listeners and custom unit options.
    mkdir -p "$BUILD_DIR/legacy-runtime"
    cat > "$BUILD_DIR/legacy-runtime/90-easy-openvas-migration.conf" <<EOF
# Easy-OpenVAS legacy migration runtime environment
[Service]
Environment="PATH=$PYTHON_ENV_DIR/ospd-openvas/bin:$SERVICE_PATH"
Environment="PYTHONNOUSERSITE=1"
UnsetEnvironment=PYTHONPATH PYTHONHOME
EOF
    sudo install -d -m 0755 /etc/systemd/system/ospd-openvas.service.d
    sudo install -m 0644 "$BUILD_DIR/legacy-runtime/90-easy-openvas-migration.conf" \
        /etc/systemd/system/ospd-openvas.service.d/90-easy-openvas-migration.conf
    sudo systemctl daemon-reload
    # Restore the distro marker only from the exact .old file left by old scripts.
    marker=$("$PYTHON_BIN" -c 'import sysconfig; print(sysconfig.get_path("stdlib") + "/EXTERNALLY-MANAGED")')
    if ! sudo test -e "$marker" && sudo test -f "$marker.old"; then
        if [[ "$SKIP_MIGRATION_REHEARSAL" != true ]]; then
            sudo cp -a -- "$marker.old" "$BACKUP_DIR/EXTERNALLY-MANAGED.old"
        fi
        sudo cp -a -- "$marker.old" "$marker"
        printf 'Restored the original distro EXTERNALLY-MANAGED marker from its .old copy.\n'
    fi
}

verify_legacy_keys() {
    sudo sha256sum --check --status "$BACKUP_DIR/credential-key-checksums.txt" ||
        die 'Credential encryption key material changed; keep services stopped and review the verification records and original keys.'
}

rehearse_database_migration() {
    if [[ "$SKIP_MIGRATION_REHEARSAL" == true ]]; then
        printf '%sMigration rehearsal skipped; proceeding with the live database migration.%s\n' "$LYELLOW" "$NC"
        return
    fi
    check_migration_database_space
    # createdb must succeed; never reuse or drop a pre-existing database.
    MIGRATION_TEST_DB="gvmd_migration_${BUILD_ID//[^[:alnum:]]/_}"
    [[ ${#MIGRATION_TEST_DB} -le 63 && "$MIGRATION_TEST_DB" != "$DB_NAME" ]] ||
        die 'Cannot form a separate rehearsal database name.'
    printf '%s\n' "$MIGRATION_TEST_DB" > "$BACKUP_DIR/rehearsal-database.txt"
    run_task 'Creating a separate database for the migration rehearsal' \
        as_postgres "$PG_BIN/createdb" --host="$DB_HOST" --port="$DB_PORT" \
        --template=template0 --owner=gvm "$MIGRATION_TEST_DB"
    MIGRATION_TEST_CREATED=true
    run_task 'Restoring the backup into the rehearsal database' \
        as_postgres "$PG_BIN/pg_restore" --host="$DB_HOST" --port="$DB_PORT" \
        --exit-on-error --dbname="$MIGRATION_TEST_DB" < "$BACKUP_DIR/gvmd.dump"
    run_task 'Updating pg-gvm in the rehearsal database' \
        as_postgres "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 --host="$DB_HOST" --port="$DB_PORT" \
        --dbname="$MIGRATION_TEST_DB" -c 'ALTER EXTENSION "pg-gvm" UPDATE;'
    run_task 'Testing gvmd migration on the restored database' \
        as_gvm "$INSTALL_PREFIX/sbin/gvmd" --migrate --database="$MIGRATION_TEST_DB" \
        --db-host="$DB_HOST" --db-port="$DB_PORT"
    run_task 'Checking the rehearsed database revision' check_database_revision "$MIGRATION_TEST_DB"
    capture_accounts "$MIGRATION_TEST_DB" "$BACKUP_DIR/users-rehearsal.csv"
    cmp -s "$BACKUP_DIR/users-before.csv" "$BACKUP_DIR/users-rehearsal.csv" ||
        die 'Rehearsal account UUIDs/names differ; the live database has not been migrated.'
    verify_legacy_keys
    run_task 'Removing the successful rehearsal database' \
        as_postgres "$PG_BIN/dropdb" --host="$DB_HOST" --port="$DB_PORT" "$MIGRATION_TEST_DB"
    MIGRATION_TEST_DB=""
    MIGRATION_TEST_CREATED=false
}



get_latest_release() {
    local response
    response=$(curl -f -sS -L --retry 3 "https://api.github.com/repos/$1/releases/latest")
    "$PYTHON_BIN" -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])' <<< "$response"
}

resolve_versions() {
    local version forced selected
    local -A repos=(
        [GVM_LIBS_VERSION]=greenbone/gvm-libs [GVMD_VERSION]=greenbone/gvmd
        [PG_GVM_VERSION]=greenbone/pg-gvm [GSA_VERSION]=greenbone/gsa
        [GSAD_VERSION]=greenbone/gsad [OPENVAS_SMB_VERSION]=greenbone/openvas-smb
        [OPENVAS_SCANNER_VERSION]=greenbone/openvas-scanner
        [OSPD_OPENVAS_VERSION]=greenbone/ospd-openvas
        [FEED_SYNC_VERSION]=greenbone/greenbone-feed-sync
        [GVM_TOOLS_VERSION]=greenbone/gvm-tools [PYTHON_GVM_VERSION]=greenbone/python-gvm
        [PYPSRP_CLI_VERSION]=greenbone/pypsrp-cli
    )
    for version in GVM_LIBS_VERSION GVMD_VERSION PG_GVM_VERSION GSA_VERSION GSAD_VERSION \
        OPENVAS_SMB_VERSION OPENVAS_SCANNER_VERSION OSPD_OPENVAS_VERSION \
        FEED_SYNC_VERSION GVM_TOOLS_VERSION PYTHON_GVM_VERSION PYPSRP_CLI_VERSION; do
        forced="FORCE_$version"
        if [[ -n "${!forced}" ]]; then
            selected="${!forced}"
        else
            printf '%sChecking latest %s release...%s\n' "$LPURPLE" "${repos[$version]#greenbone/}" "$NC"
            selected=$(get_latest_release "${repos[$version]}")
        fi
        selected="${selected#v}"
        [[ "$selected" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || \
            die "Invalid release for ${repos[$version]}: $selected"
        printf -v "$version" '%s' "$selected"
        export "${version?}"
        printf '%s%s=%s%s\n' "$LGREEN" "$version" "$selected" "$NC"
        printf 'FORCE_%s=%s\n' "$version" "$selected" >> "$VERSION_LOG"
    done

    # Use feed-sync's defaults unless a feed release is explicitly forced.

    if [[ -n "$FORCE_FEED_RELEASE" ]]; then
        [[ "$FORCE_FEED_RELEASE" =~ ^[0-9]+\.[0-9]+$ ]] ||
            die "Invalid feed release: $FORCE_FEED_RELEASE"

    fi

    # Record the requested override; blank means no script-level override.
    printf 'FORCE_FEED_RELEASE=%s\n' "${FORCE_FEED_RELEASE:-}" >> "$VERSION_LOG"
    printf 'FEED_SYNC_ATTEMPTS=%s\nFEED_SYNC_RETRY_DELAY=%s\n' "$FEED_SYNC_ATTEMPTS" "$FEED_SYNC_RETRY_DELAY" >> "$VERSION_LOG"
}

reject_gvmd_downgrade() {
    local output current
    output=$(as_gvm "$INSTALL_PREFIX/sbin/gvmd" --version 2>&1)
    current=$(sed -n 's/^Greenbone Vulnerability Manager \([0-9][0-9.]*\).*/\1/p' <<< "$output")
    [[ -n "$current" ]] || die "Cannot read the installed gvmd version."
    dpkg --compare-versions "$GVMD_VERSION" ge "$current" || \
        die "Refusing gvmd downgrade $current -> $GVMD_VERSION; database downgrades are not supported."
    printf 'INSTALLED_GVMD_VERSION=%s\n' "$current" >> "$VERSION_LOG"
}

check_database_compatibility() {
    local current
    current=$(psql_db -At -c "SELECT value FROM public.meta WHERE name = 'database_version';") || return
    [[ "$current" =~ ^[0-9]+$ ]] || { printf 'Cannot determine the existing GVMD database revision.\n' >&2; return 1; }
    TARGET_DB_REVISION=$("$PYTHON_BIN" - "$SOURCE_DIR/gvmd-$GVMD_VERSION/CMakeLists.txt" <<'DB_REVISION'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
matches = re.findall(r'(?im)^\s*set\s*\(\s*GVMD_DATABASE_VERSION\s+(\d+)\s*\)', text)
if len(matches) != 1:
    raise SystemExit('Cannot determine the selected GVMD database revision.')
print(matches[0])
DB_REVISION
    ) || return
    (( TARGET_DB_REVISION >= current )) || { printf 'The selected GVMD would downgrade the database (%s to %s); no software has been replaced.\n' "$current" "$TARGET_DB_REVISION" >&2; return 1; }
    psql_db -At -c "SELECT extversion FROM pg_extension WHERE extname = 'pg-gvm';" > "$RUN_DIR/pg-gvm.before" || return
    [[ -s "$RUN_DIR/pg-gvm.before" ]] || { printf 'The existing pg-gvm extension is missing.\n' >&2; return 1; }
    "$PYTHON_BIN" - "$SOURCE_DIR/pg-gvm-$PG_GVM_VERSION/CMakeLists.txt" "$RUN_DIR/pg-gvm.before" <<'PG_EXTENSION_VERSION'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
project = re.search(r'(?i)project\s*\(\s*pg-gvm\s+VERSION\s+(\d+)\.(\d+)\.(\d+)', text)
api = re.search(r'(?is)set\s*\(\s*PROJECT_API_VERSION\s+"?([^"\s)]+)"?\s*\)', text)
if not project or not api:
    raise SystemExit('Cannot determine the selected pg-gvm extension API version.')
value = api.group(1)
if value == '${CMAKE_PROJECT_VERSION_MAJOR}.${CMAKE_PROJECT_VERSION_MINOR}':
    value = '.'.join(project.groups()[:2])
old = Path(sys.argv[2]).read_text().strip()
if not re.fullmatch(r'\d+\.\d+', value) or not re.fullmatch(r'\d+\.\d+', old):
    raise SystemExit('Cannot compare the existing and selected pg-gvm extension versions.')
if tuple(map(int, value.split('.'))) < tuple(map(int, old.split('.'))):
    raise SystemExit('The selected pg-gvm would downgrade the extension; no software has been replaced.')
PG_EXTENSION_VERSION
    [[ "$?" == 0 ]] || return 1
    printf 'Existing database revision: %s; selected GVMD revision: %s.\n' "$current" "$TARGET_DB_REVISION"
    printf 'DB_NAME=%s\nDATABASE_REVISION_BEFORE=%s\nDATABASE_REVISION_SELECTED=%s\n' "$DB_NAME" "$current" "$TARGET_DB_REVISION" >> "$VERSION_LOG"
}

check_database_revision() {
    local database="$1" current
    current=$(as_postgres "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 -At \
        --host="$DB_HOST" --port="$DB_PORT" --dbname="$database" \
        -c "SELECT value FROM public.meta WHERE name = 'database_version';") || return
    [[ "$current" == "$TARGET_DB_REVISION" ]] || {
        printf 'Database %s did not reach the selected revision %s (found %s).\n' \
            "$database" "$TARGET_DB_REVISION" "$current" >&2
        return 1
    }
}

download_source() {
    local component="$1" version="$2" signature="${3:-}"
    local archive="$SOURCE_DIR/$component-$version.tar.gz"
    # Only this private run creates these directories, after successful verification.
    [[ ! -d "$SOURCE_DIR/$component-$version" ]] || return 0
    curl -f -sS -L --retry 3 "https://github.com/greenbone/$component/archive/refs/tags/v$version.tar.gz" -o "$archive" || return
    if [[ -n "$signature" ]]; then
        curl -f -sS -L --retry 3 "https://github.com/greenbone/$component/releases/download/v$version/$signature" -o "$archive.asc" || return
        verify_source_signature "$archive.asc" "$archive" || return
    fi
    tar -C "$SOURCE_DIR" -xzf "$archive"
}



backup_existing_system() {
    local path previous_umask
    previous_umask=$(umask)
    umask 077
    mkdir -p "$BACKUP_DIR"
    if [[ "$SKIP_MIGRATION_REHEARSAL" == true ]]; then
        printf '%sBackups skipped: no database dump, archives or copies of replaced files will be made.%s\n' "$LYELLOW" "$NC"
        if [[ "$LEGACY_MIGRATION" == true ]]; then record_legacy_identity; fi
        umask "$previous_umask"
        return
    fi
    psql_db -At -c 'SELECT version();' > "$BACKUP_DIR/postgresql-version.txt"
    run_task 'Backing up the GVMD database' save_output "$BACKUP_DIR/gvmd.dump" \
        as_postgres "$PG_BIN/pg_dump" --host="$DB_HOST" --port="$DB_PORT" --format=custom --dbname="$DB_NAME"
    run_task 'Checking that the database backup archive is readable'         save_output "$BACKUP_DIR/gvmd-archive-list.txt" "$PG_BIN/pg_restore" --list "$BACKUP_DIR/gvmd.dump"
    [[ -s "$BACKUP_DIR/gvmd-archive-list.txt" ]] || die 'The database backup archive list is empty.'
    run_task 'Backing up PostgreSQL global roles' save_output "$BACKUP_DIR/postgresql-globals.sql" \
        as_postgres "$PG_BIN/pg_dumpall" --host="$DB_HOST" --port="$DB_PORT" --globals-only
    local -a config_paths=()
    for path in etc/gvm etc/openvas etc/redis/redis-openvas.conf etc/ssl \
        etc/systemd/system etc/ld.so.conf.d/gvm-local.conf; do
        if sudo test -e "/$path"; then config_paths+=("$path"); fi
    done
    run_task 'Backing up configuration and certificates' save_output "$BACKUP_DIR/configuration.tar.gz" \
        sudo tar -C / -czf - "${config_paths[@]}"
    if sudo test -d "$PYTHON_ENV_DIR"; then
        run_task 'Backing up the existing Python environments' sudo cp -a "$PYTHON_ENV_DIR" "$BACKUP_DIR/venvs"
    fi
    if [[ "$LEGACY_MIGRATION" == true ]]; then
        backup_legacy_state
    fi
    umask "$previous_umask"
    printf '%sBackups: %s%s\n' "$LGREEN" "$BACKUP_DIR" "$NC"
}

install_dependencies() {
    # Upgrade the named dependencies only. Keep existing conffiles and repositories.
    run_task 'Refreshing APT package lists' sudo env DEBIAN_FRONTEND=noninteractive apt-get --allow-releaseinfo-change-codename --error-on=any update
    run_task 'Updating OpenVAS build and runtime dependencies' \
        sudo env DEBIAN_FRONTEND=noninteractive apt-get --assume-yes --no-remove \
        --no-install-recommends -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold install \
        "${COMMON_DEPS[@]}" "${MAIL_DEPS[@]}" util-linux \
        "${GVMLIBS_DEPS[@]}" "${GVMD_DEPS1[@]}" \
        "${GVMD_DEPS2[@]}" "${PGGVM_DEPS[@]}" "${GSAD_DEPS[@]}" \
        "${OPENVASSMB_DEPS[@]}" "${OPENVASSCAN_DEPS[@]}" "${OSPD_DEPS[@]}" \
        "${FEED_DEPS[@]}" "${GVMTOOLS_DEPS[@]}" "${REDIS_DEPS[@]}" \
        "${OPENVASD_DEPS[@]}" "${PYPSRP_DEPS[@]}" \
        "postgresql-$POSTGRESQL_MAJOR" "postgresql-server-dev-$POSTGRESQL_MAJOR"
    [[ -x "$PG_CONFIG" ]] || die "PostgreSQL development tool missing after package installation: $PG_CONFIG"
    "$PG_CONFIG" --version
    local server_version
    server_version=$(psql_db -At -c 'SHOW server_version_num;')
    [[ "$server_version" =~ ^[0-9]+$ ]] && \
        (( server_version / 10000 == POSTGRESQL_MAJOR )) || die "PostgreSQL major changed unexpectedly."
}

upgrade_file_metadata() {
    sudo "$PYTHON_BIN" - "$1" "$2" "$3" "${4:-/}" "$INSTALL_PREFIX" <<'UPGRADE_METADATA'
import base64, json, os, stat, sys
from pathlib import Path

operation, stage, metadata = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
root = Path(sys.argv[4])
prefix = sys.argv[5].lstrip('/').rstrip('/')
protected = ('etc/', 'var/', 'run/', 'lib/systemd/', 'usr/lib/systemd/',
             prefix + '/etc/', prefix + '/lib/systemd/')
if operation == 'capture':
    records = {}
    for source in stage.rglob('*'):
        relative = str(source.relative_to(stage))
        if root == Path('/') and any((relative + '/').startswith(p) for p in protected):
            continue
        target = root / relative
        if not target.exists() and not target.is_symlink(): continue
        info = target.lstat()
        if stat.S_ISDIR(info.st_mode): continue
        records[str(target)] = dict(uid=info.st_uid, gid=info.st_gid,
            mode=stat.S_IMODE(info.st_mode), kind=stat.S_IFMT(info.st_mode),
            xattrs={name: base64.b64encode(os.getxattr(target, name, follow_symlinks=False)).decode()
                    for name in os.listxattr(target, follow_symlinks=False)})
    with metadata.open('w') as output: json.dump(records, output)
else:
    for path, item in json.loads(metadata.read_text()).items():
        if not os.path.lexists(path): continue  # Obsolete web assets were intentionally deleted.
        # A replacement file type keeps its staged ownership, permissions and xattrs.
        if stat.S_IFMT(os.lstat(path).st_mode) != item['kind']: continue
        os.chown(path, item['uid'], item['gid'], follow_symlinks=False)
        if not Path(path).is_symlink(): os.chmod(path, item['mode'])
        for name, value in item['xattrs'].items():
            os.setxattr(path, name, base64.b64decode(value), follow_symlinks=False)
UPGRADE_METADATA
}

deploy_stage() {
    local metadata status=0
    metadata="$RUN_DIR/metadata-$(basename "$1").json"
    local -a backup_args=()
    if [[ "$SKIP_MIGRATION_REHEARSAL" != true ]]; then
        backup_args=(--backup --backup-dir="$BACKUP_DIR/files")
    fi
    upgrade_file_metadata capture "$1" "$metadata" || return
    # Keep destination metadata, including ACLs and capabilities, through updates.
    # Always copy selected release files, even when sizes and timestamps match.
    run_optional_task "Installing $(basename "$1") program files" \
        sudo rsync -rl --keep-dirlinks --inplace --ignore-times "${backup_args[@]}" \
        --exclude='/etc/***' --exclude='/var/***' --exclude='/run/***' \
        --exclude="$INSTALL_PREFIX/etc/***" \
        --exclude='/lib/systemd/***' --exclude='/usr/lib/systemd/***' \
        --exclude="$INSTALL_PREFIX/lib/systemd/***" \
        "$1/" / || status=$?
    # Restore metadata after a partial transfer too, then propagate its failure.
    upgrade_file_metadata restore "$1" "$metadata" || return
    return "$status"
}

deploy_web_assets() {
    local source="$1" target="$INSTALL_PREFIX/share/gvm/gsad/web"
    local metadata status=0
    metadata="$RUN_DIR/metadata-gsa.json"
    shift
    check_web_destination "$target" || return
    upgrade_file_metadata capture "$source" "$metadata" "$target" || return
    run_optional_task "Installing GSA $GSA_VERSION web assets" \
        sudo rsync -rl --delete --keep-dirlinks --inplace --ignore-times "$@" \
        "$source/" "$target/" || status=$?
    upgrade_file_metadata restore "$source" "$metadata" "$target" || return
    return "$status"
}

build_cmake() {
    local component="$1" version="$2"
    shift 2
    section "Building & installing $component $version"
    run_logged_task "Configuring $component $version" \
        cmake -S "$SOURCE_DIR/$component-$version" -B "$BUILD_DIR/$component" "$@"
    run_logged_task "Compiling $component $version" cmake --build "$BUILD_DIR/$component" --parallel "$BUILD_JOBS"
    run_logged_task "Staging $component $version" env DESTDIR="$INSTALL_DIR/$component" cmake --install "$BUILD_DIR/$component"
    deploy_stage "$INSTALL_DIR/$component"
    sudo ldconfig
    case "$component" in
        gvm-libs) pkg-config --exists libgvm_base ;;
        gvmd) as_gvm "$INSTALL_PREFIX/sbin/gvmd" --version ;;
        gsad) "$INSTALL_PREFIX/sbin/gsad" --version ;;
        openvas-scanner) "$INSTALL_PREFIX/sbin/openvas" --version | sed '${/^$/d;}' ;;
    esac
    component_done "$component" "$version"
}

# Fix HTTPS redirects to use --port (443), rather than --rport (80).
patch_gsad_redirect() {
    "$PYTHON_BIN" - "$SOURCE_DIR/gsad-$GSAD_VERSION/src/gsad.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
broken = 'g_strdup_printf ("https://%%s:%i/", redirect_port);'
fixed = 'g_strdup_printf ("https://%%s:%i/", gsad_args_get_port (gsad_args));'
if broken in source:
    path.write_text(source.replace(broken, fixed))
    print("Applied GSAD HTTP-to-HTTPS redirect port fix.")
PY
}

prepare_native_archives() {
    local scanner="$1" krb5_version pcap_version part archive
    local krb5_prefix="$BUILD_DIR/openvas-static/krb5"
    local pcap_prefix="$BUILD_DIR/openvas-static/pcap"
    # Use the dependency sources and versions shipped with this scanner tag.
    krb5_version=$(sed -n 's/^ARG KRB5_VERSION=\([0-9][0-9.]*\)$/\1/p' "$scanner/.docker/prod.Dockerfile")
    pcap_version=$(sed -n 's/^ARG LIBPCAP_VERSION=\([0-9][0-9.]*\)$/\1/p' "$scanner/.docker/prod.Dockerfile")
    [[ -n "$krb5_version" && -n "$pcap_version" ]] || die "Scanner source does not declare the expected native dependency versions."
    [[ -x "$scanner/.docker/vendor/krb5-$krb5_version/src/configure" ]] || die "Vendored MIT Kerberos source is missing."
    [[ -x "$scanner/.docker/vendor/libpcap-$pcap_version/configure" ]] || die "Vendored libpcap source is missing."

    (
        cd "$scanner/.docker/vendor/krb5-$krb5_version/src"
        ./configure --prefix="$krb5_prefix" --enable-static --disable-shared \
            --without-system-verto --without-libedit --without-keyutils --disable-rpath
        # Build only the library subtrees, as in upstream's archive preparation.
        for part in util/support util/et util/profile include lib/crypto lib/krb5 lib/gssapi; do
            make -C "$part" -j"$BUILD_JOBS"
        done
        make install-mkdirs
        for part in util/support util/et util/profile include lib/crypto lib/krb5 lib/gssapi; do
            make -C "$part" install
        done
    )
    (
        cd "$scanner/.docker/vendor/libpcap-$pcap_version"
        # Prevent host-installed optional capture backends adding static link dependencies.
        ./configure --prefix="$pcap_prefix" --disable-shared --disable-dbus \
            --without-libnl --disable-usb --disable-bluetooth --disable-rdma
        make -j"$BUILD_JOBS"
        make install
    )

    export OPENVAS_KRB5_INCLUDE_DIR="$krb5_prefix/include"
    export OPENVAS_KRB5_ARCHIVES=""
    for archive in libgssapi_krb5.a libkrb5.a libk5crypto.a libcom_err.a libkrb5support.a; do
        [[ -f "$krb5_prefix/lib/$archive" ]] || die "Native archive missing: $archive"
        OPENVAS_KRB5_ARCHIVES+="${OPENVAS_KRB5_ARCHIVES:+:}$krb5_prefix/lib/$archive"
    done
    for part in krb5.h gssapi/gssapi.h gssapi/gssapi_krb5.h; do
        [[ -f "$OPENVAS_KRB5_INCLUDE_DIR/$part" ]] || die "Native header missing: $part"
    done
    export LIBPCAP_LIBDIR="$pcap_prefix/lib"
    export LIBPCAP_VER="$pcap_version"
    [[ -f "$LIBPCAP_LIBDIR/libpcap.a" ]] || die "Native libpcap archive missing."
    [[ -f "$pcap_prefix/include/pcap.h" ]] || die "Native libpcap header missing."
    printf 'KRB5_VERSION=%s\nLIBPCAP_VERSION=%s\n' "$krb5_version" "$pcap_version" >> "$VERSION_LOG"
}

build_rust_scanner() {
    local scanner="$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION" rust_toolchain
    if [[ ! -x "$HOME/.cargo/bin/rustup" ]]; then
        run_logged_task 'Downloading Rustup' \
            curl --proto '=https' --tlsv1.2 -f -sS -L --retry 3 https://sh.rustup.rs -o "$BUILD_DIR/rustup-init.sh"
        run_logged_task 'Installing Rustup' sh "$BUILD_DIR/rustup-init.sh" -y --profile minimal --no-modify-path
    fi
    source "$HOME/.cargo/env"
    if [[ -f "$scanner/rust/crates/nasl-c-lib/libopenvas-krb5-sys/build.rs" ]]; then
        run_logged_task "Building static Kerberos and libpcap libraries" prepare_native_archives "$scanner"
    fi
    cd "$scanner/rust"
    if [[ -f rust-toolchain.toml ]]; then
        rust_toolchain=$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' rust-toolchain.toml)
        [[ "$rust_toolchain" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]] || die "Cannot read the scanner's Rust toolchain."
        run_task "Preparing Rust toolchain $rust_toolchain" rustup toolchain install "$rust_toolchain" --profile minimal
        export RUSTUP_TOOLCHAIN="$rust_toolchain"
    fi
    rustc --version
    cargo --version
    printf 'RUST_VERSION=%q\nCARGO_VERSION=%q\n' "$(rustc --version)" "$(cargo --version)" >> "$VERSION_LOG"
    [[ -f Cargo.lock ]] || die "The scanner release does not contain Cargo.lock."
    BIN_VERSION="$OPENVAS_SCANNER_VERSION" run_logged_task "Compiling openvasd and scannerctl $OPENVAS_SCANNER_VERSION" \
        cargo build --locked --release --jobs "$BUILD_JOBS" \
        --bin openvasd --bin scannerctl --target-dir "$BUILD_DIR/openvasd-target"
    mkdir -p "$INSTALL_DIR/rust$INSTALL_PREFIX/bin"
    install -m 755 "$BUILD_DIR/openvasd-target/release/openvasd" "$INSTALL_DIR/rust$INSTALL_PREFIX/bin/openvasd"
    install -m 755 "$BUILD_DIR/openvasd-target/release/scannerctl" "$INSTALL_DIR/rust$INSTALL_PREFIX/bin/scannerctl"
    deploy_stage "$INSTALL_DIR/rust"
}



link_python_commands() {
    local name="$1" command
    shift
    for command in "$@"; do
        [[ -x "$PYTHON_ENV_DIR/$name/bin/$command" ]] || die "Missing Python command: $command"
        if [[ "$LEGACY_MIGRATION" == true && "$SKIP_MIGRATION_REHEARSAL" != true ]] &&
            { sudo test -e "$INSTALL_PREFIX/bin/$command" || sudo test -L "$INSTALL_PREFIX/bin/$command"; }; then
            sudo install -d -m 0700 "$BACKUP_DIR/launchers"
            sudo cp -a -- "$INSTALL_PREFIX/bin/$command" "$BACKUP_DIR/launchers/$command"
        fi
        sudo ln -sfn "$PYTHON_ENV_DIR/$name/bin/$command" "$INSTALL_PREFIX/bin/$command"
    done
}

upgrade_python_apps() {
    section "Building & installing ospd-openvas $OSPD_OPENVAS_VERSION"
    run_logged_task "Installing ospd-openvas and Python dependencies" install_python_app ospd-openvas "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION"
    link_python_commands ospd-openvas ospd-openvas
    "$PYTHON_ENV_DIR/ospd-openvas/bin/ospd-openvas" --help >/dev/null
    component_done ospd-openvas "$OSPD_OPENVAS_VERSION"
    section "Building & installing openvasd $OPENVAS_SCANNER_VERSION"
    build_rust_scanner
    run_logged_task "Checking openvasd executable" "$INSTALL_PREFIX/bin/openvasd" --version
    run_logged_task "Checking scannerctl executable" "$INSTALL_PREFIX/bin/scannerctl" --help
    component_done openvasd "$OPENVAS_SCANNER_VERSION"
    component_done scannerctl "$OPENVAS_SCANNER_VERSION"
    section "Building & installing Windows helpers (pypsrp-cli $PYPSRP_CLI_VERSION and Impacket)"
    local -a windows_packages=("$SOURCE_DIR/pypsrp-cli-$PYPSRP_CLI_VERSION")
    local impacket_command
    if needs_isolated_impacket; then windows_packages+=(impacket); fi
    run_logged_task "Installing pypsrp-cli and Python dependencies" install_python_app pypsrp-cli "${windows_packages[@]}"
    link_python_commands pypsrp-cli pypsrp-cli
    if (( ${#windows_packages[@]} > 1 )); then
        impacket_command="$PYTHON_ENV_DIR/pypsrp-cli/bin/impacket-wmiexec"
        [[ -x "$impacket_command" ]] || impacket_command="$PYTHON_ENV_DIR/pypsrp-cli/bin/wmiexec.py"
        [[ -x "$impacket_command" ]] || die 'The Impacket environment did not install a WMI command.'
        sudo ln -sfn "$impacket_command" "$INSTALL_PREFIX/bin/impacket-wmiexec"
    fi
    as_gvm pypsrp-cli --help >/dev/null
    as_gvm impacket-wmiexec -h >/dev/null
    component_done pypsrp-cli "$PYPSRP_CLI_VERSION"
    printf '%s[OK] Impacket WMI command checked as gvm.%s\n' "$LGREEN" "$NC"
    section "Setting up greenbone-feed-sync"
    run_logged_task "Installing greenbone-feed-sync and Python dependencies" install_python_app greenbone-feed-sync "$SOURCE_DIR/greenbone-feed-sync-$FEED_SYNC_VERSION"
    link_python_commands greenbone-feed-sync greenbone-feed-sync greenbone-nvt-sync greenbone-scapdata-sync greenbone-certdata-sync
    "$PYTHON_ENV_DIR/greenbone-feed-sync/bin/greenbone-feed-sync" --version
    component_done greenbone-feed-sync "$FEED_SYNC_VERSION"
    section "Setting up gvm-tools"
    run_logged_task "Installing gvm-tools and Python dependencies" install_python_app gvm-tools "$SOURCE_DIR/python-gvm-$PYTHON_GVM_VERSION" "$SOURCE_DIR/gvm-tools-$GVM_TOOLS_VERSION"
    link_python_commands gvm-tools gvm-cli gvm-script gvm-pyshell
    "$PYTHON_ENV_DIR/gvm-tools/bin/gvm-cli" --help >/dev/null
    component_done python-gvm "$PYTHON_GVM_VERSION"
    component_done gvm-tools "$GVM_TOOLS_VERSION"
    section "Setting up the Redis data store"
    run_logged_task "Checking Redis executable" redis-server --version
    component_done Redis "$(redis-server --version | awk '{print $3}')"
}

verify_binaries() {
    sudo ldconfig
    "$INSTALL_PREFIX/sbin/openvas" --version
    as_gvm "$INSTALL_PREFIX/sbin/gvmd" --version
    "$INSTALL_PREFIX/sbin/gsad" --version
    "$INSTALL_PREFIX/bin/openvasd" --version
    "$INSTALL_PREFIX/bin/scannerctl" --help >/dev/null
}

migrate_database() {
    # Refresh the loader BEFORE invoking the new executable or extension library.
    sudo ldconfig
    if [[ "$LEGACY_MIGRATION" == true ]]; then
        rehearse_database_migration
    fi
    run_task 'Updating the PostgreSQL pg-gvm extension' psql_db -c 'ALTER EXTENSION "pg-gvm" UPDATE;'
    run_task 'Migrating the GVMD database' as_gvm "$INSTALL_PREFIX/sbin/gvmd" --migrate --database="$DB_NAME" \
        --db-host="$DB_HOST" --db-port="$DB_PORT"
    run_task 'Checking the migrated database revision' check_database_revision "$DB_NAME"
    if [[ "$LEGACY_MIGRATION" == true ]]; then
        capture_accounts "$DB_NAME" "$BACKUP_DIR/users-after.csv"
        cmp -s "$BACKUP_DIR/users-before.csv" "$BACKUP_DIR/users-after.csv" ||
            die 'Account UUIDs/names differ after live migration; keep services stopped and review the verification records and recovery options.'
        verify_legacy_keys
        run_task 'Checking the preserved Linux gvm account identity' verify_legacy_account
    fi
}


write_feed_retry_script() {
    # Retain a standalone retry command with the same lock repairs and version pin.
    # It contains no passwords and runs as the original sudo-enabled user.
    (umask 077
        {
            printf '#!/bin/bash\nset -e\n'
            printf 'INSTALL_PREFIX=%q\nFORCE_FEED_RELEASE=%q\n' "$INSTALL_PREFIX" "$FORCE_FEED_RELEASE"
            printf 'FEED_SYNC_ATTEMPTS="${FEED_SYNC_ATTEMPTS:-%s}"\nFEED_SYNC_RETRY_DELAY="${FEED_SYNC_RETRY_DELAY:-%s}"\n' "$FEED_SYNC_ATTEMPTS" "$FEED_SYNC_RETRY_DELAY"
            printf 'BUILD_LOG=%q\nLYELLOW=%q\nLRED=%q\nNC=%q\n' "$BUILD_LOG" "$LYELLOW" "$LRED" "$NC"
            cat <<'RETRY_SETTINGS'
[[ "$FEED_SYNC_ATTEMPTS" =~ ^[1-9][0-9]?$ ]] || {
    printf 'FEED_SYNC_ATTEMPTS must be an integer from 1 to 99.\n' >&2
    exit 1
}
[[ "$FEED_SYNC_RETRY_DELAY" =~ ^(0|[1-9][0-9]{0,3})$ ]] &&
    (( FEED_SYNC_RETRY_DELAY <= 3600 )) || {
    printf 'FEED_SYNC_RETRY_DELAY must be an integer from 0 to 3600 seconds.\n' >&2
    exit 1
}
RETRY_SETTINGS
            printf 'PYTHON_BIN=%q\n' "$PYTHON_BIN"
            declare -f acquire_maintenance_lock
            declare -f sync_feeds_with_retries
            cat <<'RETRY_RUN'
trap 'if [[ "${UPGRADE_LOCKED:-false}" == true ]]; then flock -u 9; exec 9<&-; fi' EXIT
acquire_maintenance_lock
sync_feeds_with_retries
RETRY_RUN
        } > "$RUN_DIR/retry-feed-sync.sh"
    )
}


upgrade_components() {
    local -a web_backup_args=()
    if [[ "$SKIP_MIGRATION_REHEARSAL" != true ]]; then
        web_backup_args=(--backup --backup-dir="$BACKUP_DIR/web")
    fi
    build_cmake gvm-libs "$GVM_LIBS_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
        -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var
    build_cmake gvmd "$GVMD_VERSION" \
        -DPG_CONFIG_EXECUTABLE="$PG_CONFIG" -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DCMAKE_BUILD_TYPE=Release -DLOCALSTATEDIR=/var -DSYSCONFDIR=/etc \
        -DGVM_DATA_DIR=/var -DGVMD_RUN_DIR=/run/gvmd \
        -DOPENVAS_DEFAULT_SOCKET=/run/ospd/ospd-openvas.sock \
        -DGVM_FEED_LOCK_PATH=/var/lib/gvm/feed-update.lock \
        -DSYSTEMD_SERVICE_DIR=/lib/systemd/system -DLOGROTATE_DIR=/etc/logrotate.d
    sudo chown "$GVMD_OWNER" "$INSTALL_PREFIX/sbin/gvmd"
    sudo chmod "$GVMD_MODE" "$INSTALL_PREFIX/sbin/gvmd"
    build_cmake pg-gvm "$PG_GVM_VERSION" -DPGCONFIG="$PG_CONFIG" -DCMAKE_BUILD_TYPE=Release
    section "Building & installing gsa $GSA_VERSION"
    # Only this generated web distribution is pruned; no deletion is used at /.
    deploy_web_assets "$SOURCE_DIR/gsa-$GSA_VERSION" "${web_backup_args[@]}"
    component_done gsa "$GSA_VERSION"
    patch_gsad_redirect
    build_cmake gsad "$GSAD_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
        -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var -DGVMD_RUN_DIR=/run/gvmd \
        -DGSAD_RUN_DIR=/run/gsad -DLOGROTATE_DIR=/etc/logrotate.d
    build_cmake openvas-smb "$OPENVAS_SMB_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release
    build_cmake openvas-scanner "$OPENVAS_SCANNER_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
        -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var \
        -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock -DOPENVAS_RUN_DIR=/run/ospd
    upgrade_python_apps
}

perform_upgrade() {
    section 'Checking the existing OpenVAS installation'
    run_task 'Checking executables, configuration and services' check_existing_installation
    run_task 'Checking the existing PostgreSQL installation' detect_postgresql
    if [[ "$LEGACY_MIGRATION" == true ]]; then
        run_task 'Checking the recognised legacy source-installation layout' check_legacy_layout
        run_task 'Checking space for the restored-copy migration test' check_migration_database_space
    fi
    section 'Selecting OpenVAS releases'
    resolve_versions
    reject_gvmd_downgrade
    section 'Downloading and verifying selected sources'
    run_logged_task 'Downloading the Greenbone signing key' curl -f -sS -L --retry 3 https://www.greenbone.net/GBCommunitySigningKey.asc -o "$RUN_DIR/signing-key.asc"
    run_logged_task 'Checking and importing the signing key' import_signing_key "$RUN_DIR/signing-key.asc"
	run_logged_task "Refreshing APT package lists for preflight" sudo env DEBIAN_FRONTEND=noninteractive apt-get --allow-releaseinfo-change-codename --error-on=any update
    prepare_all_sources
    run_logged_task "Checking distro package availability and conflicts" check_dependency_plan
	run_logged_task "Checking selected CMake, library and scanner requirements" check_source_requirements
    run_task "Checking the GSA web destination" check_web_destination
    run_task 'Checking selected database and extension compatibility' check_database_compatibility
    run_task "Preparing Python preflight build dependencies" prepare_python_build_dependencies
    run_logged_task "Checking selected Python and feed requirements" check_selected_compatibility
    section 'Preparing feed schedules and stopping GVM'
    mkdir -p "$BACKUP_DIR"
    run_task 'Pausing recognised feed cron jobs' pause_migration_cron
    run_task 'Waiting for any running feed sync to finish' check_migration_feed_idle
    MAINTENANCE_STARTED=true
    run_task 'Stopping OpenVAS services for the upgrade' sudo systemctl stop "${GVM_SERVICES[@]}"
    backup_existing_system
    section 'Updating build and runtime dependency packages'
    install_dependencies
    local multiarch
    multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
    export PKG_CONFIG_PATH="$INSTALL_PREFIX/lib/pkgconfig:$INSTALL_PREFIX/lib/$multiarch/pkgconfig:$INSTALL_PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    upgrade_components
    if [[ "$LEGACY_MIGRATION" == true ]]; then
        section 'Checking the migrated Python commands and service environment'
        configure_legacy_runtime
    fi
    section 'Verifying the upgraded executables'
    run_task 'Checking installed executable and library dependencies' verify_binaries
    section 'Updating the PostgreSQL extension and migrating gvmd'
    migrate_database
    if [[ "$APT_AUTOREMOVE" == true ]]; then
        run_task 'Removing unused APT packages (explicitly enabled)' sudo apt-get autoremove -qq -y
    fi
    if [[ "$SYNC_FEEDS" == true ]]; then
        section "Synchronizing existing feeds (${FORCE_FEED_RELEASE:-feed-sync defaults})"
        local feed_status=0
        run_optional_task "Synchronizing Greenbone feeds (${FORCE_FEED_RELEASE:-feed-sync defaults/configuration})" \
            sync_feeds_with_retries || feed_status=$?
        case "$feed_status" in 129|130|143) exit "$feed_status" ;; esac
        if (( feed_status != 0 )); then
            FEED_SYNC_FAILED=true
            write_feed_retry_script
            printf '%sFeed sync did not complete. Continuing with service startup; a retry command will be shown below.%s\n' "$LYELLOW" "$NC" >&2
        fi
    fi
    section 'Starting and checking the existing services'
    start_services
    if [[ "$LEGACY_MIGRATION" == true ]]; then
        run_task 'Checking credential keys after service startup' verify_legacy_keys
    fi
    run_task 'Restoring recognised feed schedules' restore_migration_cron
    UPGRADE_COMPLETE=true
    printf 'Upgrade completed: %s\n' "$(date -Is)" > "$RUN_DIR/upgrade-complete.txt"
    if [[ "$LEGACY_MIGRATION" == true ]]; then
        printf 'Legacy layout migration completed: %s\n' "$(date -Is)" > "$RUN_DIR/legacy-migration-complete.txt"
    fi
    if [[ "$KEEP_BUILD_FILES" != true ]]; then
        cd "$HOME"
        # Python builds run under sudo and can leave root-owned metadata here.
        run_task 'Removing temporary build files' sudo rm -rf -- "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"
    fi

    if [[ "$FEED_SYNC_FAILED" == true ]]; then
        section 'OpenVAS software upgrade complete - feed synchronization incomplete'
    else
        section 'OpenVAS upgrade complete'
    fi
    printf '%sLog: %s\nResolved versions: %s\n' "$LGREEN" "$BUILD_LOG" "$VERSION_LOG"
    if [[ "$SKIP_MIGRATION_REHEARSAL" == true ]]; then
        printf 'Backups and rehearsal: skipped\nRecovery/verification records: %s\n' "$BACKUP_DIR"
    else
        printf 'Backups: %s\n' "$BACKUP_DIR"
    fi
    if [[ "$FEED_SYNC_FAILED" == true ]]; then
        printf '%sFeed sync requires a retry. Run:\n  ' "$LYELLOW"
        printf '%q ' bash "$RUN_DIR/retry-feed-sync.sh"
        printf '\n'
    fi
    printf '%s\n' "$NC"
}

main() {
    init_style
    local assessment=false action="" option
    for option in "$@"; do
        case "$option" in
            --help|-h) upgrade_usage; return ;;
            --check|--migrate-legacy)
                [[ -z "$action" ]] || die 'Choose either --check or --migrate-legacy; see --help.'
                action="$option"
                LEGACY_MIGRATION=true
                if [[ "$option" == --check ]]; then assessment=true; fi
                ;;
            --skip-migration-rehearsal) SKIP_MIGRATION_REHEARSAL=true ;;
            *) die "Unknown argument: $option (use --help)." ;;
        esac
    done
    [[ "$SKIP_MIGRATION_REHEARSAL" == true || "$SKIP_MIGRATION_REHEARSAL" == false ]] ||
        die 'SKIP_MIGRATION_REHEARSAL must be true or false.'
    [[ $EUID -ne 0 ]] || die 'Run this script as your normal sudo-enabled user, not root.'
    local tool
    for tool in sudo gpg python3 psql systemctl dpkg dpkg-query stat tar rsync flock getent cmp sha256sum find pgrep crontab; do
        command -v "$tool" >/dev/null || die "Required existing host tool missing: $tool"
    done
    [[ -x "$PYTHON_BIN" ]] || die "Python is missing: $PYTHON_BIN"
    [[ "$SYNC_FEEDS" == true || "$SYNC_FEEDS" == false ]] || die 'SYNC_FEEDS must be true or false.'
    [[ "$KEEP_BUILD_FILES" == true || "$KEEP_BUILD_FILES" == false ]] || die 'KEEP_BUILD_FILES must be true or false.'
    [[ "$APT_AUTOREMOVE" == true || "$APT_AUTOREMOVE" == false ]] || die 'APT_AUTOREMOVE must be true or false.'
    [[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || die 'BUILD_JOBS must be a positive integer.'
    [[ "$FEED_WAIT_SECONDS" =~ ^(0|[1-9][0-9]*)$ ]] || die 'FEED_WAIT_SECONDS must be a non-negative integer without leading zeroes.'
    [[ "$SERVICE_CHECK_SECONDS" =~ ^(0|[1-9][0-9]*)$ ]] || die 'SERVICE_CHECK_SECONDS must be an integer.'
    validate_progress_interval
    [[ "$INSTALL_PREFIX" == /usr/local && "$PYTHON_ENV_DIR" == /opt/gvm/venvs ]] || die 'These scripts support INSTALL_PREFIX=/usr/local and PYTHON_ENV_DIR=/opt/gvm/venvs.'
    [[ "$DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die 'Use a simple DB_NAME.' 
    [[ "$WORK_ROOT" == /* && "$WORK_ROOT" != / && "$WORK_ROOT" != *[[:space:]]* ]] ||
        die 'WORK_ROOT must be an absolute directory without whitespace.'
    [[ "$BUILD_LOG_DIR" == /* ]] || die 'BUILD_LOG_DIR must be an absolute directory.'
    [[ "$FEED_SYNC_ATTEMPTS" =~ ^[1-9][0-9]?$ ]] || die 'FEED_SYNC_ATTEMPTS must be an integer from 1 to 99.'
    [[ "$FEED_SYNC_RETRY_DELAY" =~ ^(0|[1-9][0-9]{0,3})$ ]] &&
        (( FEED_SYNC_RETRY_DELAY <= 3600 )) || die 'FEED_SYNC_RETRY_DELAY must be an integer from 0 to 3600 seconds.'
    set -Ee -o pipefail
    shopt -s inherit_errexit
    if [[ "$assessment" == true ]]; then
        sudo -v
        export PATH="$SERVICE_PATH:$PATH"
        show_layout_report
        return
    fi
    umask 077
    mkdir -p "$WORK_ROOT" "$BUILD_LOG_DIR"
    sudo -v
	clear 2>/dev/null || true
    acquire_maintenance_lock
    RUN_DIR=$(mktemp -d "$WORK_ROOT/run-$(date +%Y%m%d-%H%M%S)-XXXXXX")
    BUILD_ID="${RUN_DIR##*/}"
    SOURCE_DIR="$RUN_DIR/source"
    BUILD_DIR="$RUN_DIR/build"
    INSTALL_DIR="$RUN_DIR/install"
    BACKUP_DIR="$RUN_DIR/backup"
    BUILD_LOG="$BUILD_LOG_DIR/$BUILD_ID-upgrade.log"
    VERSION_LOG="$BUILD_LOG_DIR/$BUILD_ID-versions.env"
    mkdir "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"
    export GNUPGHOME="$RUN_DIR/gnupg"
    mkdir -m 700 "$GNUPGHOME"
    : > "$BUILD_LOG"
    : > "$VERSION_LOG"
    # Work/backup directories and logs stay private, while installed program data
    # needs normal readable file and directory modes for the gvm service account.
    umask 022
    trap 'case "$BASHPID" in "$UPGRADER_PID") cleanup "$?" ;; esac' EXIT
    trap 'upgrade_failed "$?" "$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    start_sudo_keepalive
    start_logging
    export PATH="$SERVICE_PATH:$PATH"
    printf '\n%s Itiligent GVM/OpenVAS Appliance Upgrader\n                    %sPowered by Greenbone%s\n\n%s' \
        "$GREYB" "$LGREENB" "$GREY" "$NC"
    printf 'Upgrade log: %s\nWorking directory: %s\n' "$BUILD_LOG" "$RUN_DIR"
    if [[ "$LEGACY_MIGRATION" == true ]]; then
        printf '%sLegacy migration selected: preserve data, keys, account identities and unit commands.%s\n' "$LYELLOW" "$NC"
        printf 'Complete the snapshot, free-space and custom-feed-job preparation described in --help first.\n'
    fi
	
	section "Preparing script dependency download"

	run_logged_task "Refreshing APT package lists" \
		sudo apt-get --allow-releaseinfo-change-codename --error-on=any update

	run_logged_task "Installing curl and CA certificates" \
		sudo env DEBIAN_FRONTEND=noninteractive apt-get install \
			--no-install-recommends --assume-yes curl ca-certificates

	# BEGIN SHARED DEPENDENCIES
	SHARED_DEPENDENCIES=$(curl -fsSL --retry 3 \
		https://raw.githubusercontent.com/itiligent/Easy-OpenVAS-Installer/main/openvas-dependencies) &&
		[[ -n "$SHARED_DEPENDENCIES" ]] || {
		printf 'Failed to download OpenVAS dependencies.\n' >&2
		exit 1
	}
	# shellcheck source=/dev/null
	source /dev/stdin <<< "$SHARED_DEPENDENCIES" || exit 1
	unset SHARED_DEPENDENCIES
	# END SHARED DEPENDENCIES

    perform_upgrade
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
