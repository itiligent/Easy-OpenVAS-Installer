#!/bin/bash
# shellcheck disable=SC2024  # Redirects write invoking-user logs/backups, intentionally outside sudo.
##############################################################################
# Greenbone Vulnerability Manager appliance Upgrade script
# Multi-distro support for Ubuntu, Debian & Raspbian
# David Harrop
# November 2026
# Run as a normal sudo-enabled user: ./openvas-upgrade.sh
# Existing data, accounts, permissions, certificates and service settings are kept.
# Product upgrades use gvmd --migrate --database with the existing database.
# PostgreSQL stays on its existing major version; roles and permissions are kept.
# Database backups are enabled by default.
# Feed cron times and arguments are retained
# On failure, sources are retained. 
# Partially upgraded services remain stopped; no automatic software rollback.
# Feed jobs stay paused once maintenance begins.
##############################################################################

##############################################################################
# EDIT THESE SETTINGS: All custom settings & dependency mgmt between distros 
# is handled in this section. Blank module versions select GitHub's latest 
# stable release. Environment overrides are also supported, for example:
# FORCE_GVMD_VERSION=26.42.0
##############################################################################

# FORCE MODULE VERSIONS or use blank "" to automatically download latest
FORCE_GVM_LIBS_VERSION="${FORCE_GVM_LIBS_VERSION:-}"				# see https://github.com/greenbone/gvm-libs
FORCE_GVMD_VERSION="${FORCE_GVMD_VERSION:-}"						# see https://github.com/greenbone/gvmd
FORCE_PG_GVM_VERSION="${FORCE_PG_GVM_VERSION:-}"					# see https://github.com/greenbone/pg-gvm
FORCE_GSA_VERSION="${FORCE_GSA_VERSION:-}"							# see https://github.com/greenbone/gsa
FORCE_GSAD_VERSION="${FORCE_GSAD_VERSION:-}"						# see https://github.com/greenbone/gsad
FORCE_OPENVAS_SMB_VERSION="${FORCE_OPENVAS_SMB_VERSION:-}"			# see https://github.com/greenbone/openvas-smb
FORCE_OPENVAS_SCANNER_VERSION="${FORCE_OPENVAS_SCANNER_VERSION:-}"	# see https://github.com/greenbone/openvas-scanner
FORCE_OSPD_OPENVAS_VERSION="${FORCE_OSPD_OPENVAS_VERSION:-}"		# see https://github.com/greenbone/ospd-openvas
# openvasd and scannerctl use the selected OPENVAS_SCANNER_VERSION source; OSPD is versioned independently.
FORCE_FEED_SYNC_VERSION="${FORCE_FEED_SYNC_VERSION:-}"				# see https://github.com/greenbone/greenbone-feed-sync
FORCE_GVM_TOOLS_VERSION="${FORCE_GVM_TOOLS_VERSION:-}"				# see https://github.com/greenbone/gvm-tools
FORCE_PYTHON_GVM_VERSION="${FORCE_PYTHON_GVM_VERSION:-}"			# see https://github.com/greenbone/python-gvm
FORCE_PYPSRP_CLI_VERSION="${FORCE_PYPSRP_CLI_VERSION:-}"			# see https://github.com/greenbone/pypsrp-cli
FORCE_FEED_RELEASE="${FORCE_FEED_RELEASE:-}"						# Blank: use feed-sync's defaults; set a release to pin.

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

# EXISTING DATABASE
DB_NAME="${DB_NAME:-gvmd}"								# The database used by the existing gvmd service.
BACKUP_DATABASE="${BACKUP_DATABASE:-true}"				# false: rely on an existing external backup.

# FEED DOWNLOAD RETRIES
FEED_SYNC_ATTEMPTS="${FEED_SYNC_ATTEMPTS:-3}"			# Total attempts, including the first (1-99).
FEED_SYNC_RETRY_DELAY="${FEED_SYNC_RETRY_DELAY:-60}"	# Seconds between attempts (0-3600).

# BUILD PATHS
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"							# Use the distro Python with matching development headers.
PYTHON_ENV_DIR="/opt/gvm/venvs"							                # Separate Python applications from distro packages.
BUILD_LOG_DIR="${BUILD_LOG_DIR:-$HOME/openvas-build-logs}"				# Kept after build/source cleanup.
WORK_ROOT="${WORK_ROOT:-$HOME/openvas-upgrade}"			                # Private, separate directory for upgrade files and output.
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-0.2}"			                # Spinner interval in seconds; fractions are supported.

BUILD_JOBS="${BUILD_JOBS:-2}"											# Parallel CMake, Make, Rust and Python build jobs.
FEED_WAIT_SECONDS="${FEED_WAIT_SECONDS:-600}"							# Wait for running feed sync after pausing cron; 0 fails 
SERVICE_CHECK_SECONDS="${SERVICE_CHECK_SECONDS:-15}"					# Time to wait for service check service startup.

# OPTIONAL APT CLEANUP
APT_AUTOREMOVE="${APT_AUTOREMOVE:-false}" # true: remove unused APT packages after the build.

# POSTGRESQL VERSION MANAGEMENT
source /etc/os-release
# Filled by the existing server preflight, before any dependency installation.
# The shared dependency arrays below must remain identical to the original installer.
POSTGRESQL_MAJOR=""
POSTGRESQL=()
PG_CONFIG=""


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
            --no-install-recommends -o Dpkg::Options::=--force-confdef \
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
    sudo env DEBIAN_FRONTEND=noninteractive apt-get --simulate --no-install-recommends install \
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
            result = subprocess.run(['systemctl', 'show', unit, '--property=ExecStart',
                                     '--property=ExecStartPre', '--property=ExecStartPost',
                                     '--property=Environment', '--value'],
                                    text=True, capture_output=True, check=True)
        if any(names.search(row) for row in result.stdout.splitlines() if not row.lstrip().startswith('#')):
            problems.append(timer)
            break
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

# Set colours
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

installer_exit() {
    local status="${1:-$?}"
    [[ "$BASHPID" == "$PROGRESS_OWNER_PID" ]] || return "$status"
    trap - EXIT
    exec 1>&"$PROGRESS_FD" 2>&"$PROGRESS_FD"
    finish_progress "$status"
    # Leave a partially upgraded stack stopped; never restart mixed versions.
    if [[ "$status" != 0 && "${UPGRADE_STARTED:-false}" == true ]]; then
        sudo -n systemctl stop gsad gvmd ospd-openvas openvasd redis-server@openvas ||
            printf '\nStop the OpenVAS services before reviewing the failed upgrade.\n' >&2
    fi
    if [[ "$status" != 0 && "${UPGRADE_STARTED:-false}" != true ]]; then
        restore_migration_cron original || printf '\nReview saved feed schedules in %s/cron.\n' "$BACKUP_DIR" >&2
    elif [[ "$status" != 0 && "${UPGRADE_STARTED:-false}" == true ]]; then
        printf '\nFeed schedules remain paused for repair. Recovery files: %s/cron\n' "$BACKUP_DIR" >&2
    fi
    # Preserve the installer's existing sudo refresher shutdown.
    if [[ -n "${sudo_keepalive_pid:-}" ]]; then
        kill "$sudo_keepalive_pid" 2>/dev/null || true
    fi
    if [[ "${UPGRADE_LOCKED:-false}" == true ]]; then
        flock -u 9 || true
        exec 9<&-
    fi
    stop_logging
    return "$status"
}


[[ "$SERVICE_CHECK_SECONDS" =~ ^(0|[1-9][0-9]*)$ ]] || { printf 'Invalid SERVICE_CHECK_SECONDS.\n' >&2; exit 1; }
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || { printf 'BUILD_JOBS must be positive.\n' >&2; exit 1; }
[[ "$FEED_WAIT_SECONDS" =~ ^(0|[1-9][0-9]*)$ ]] || { printf 'Invalid FEED_WAIT_SECONDS.\n' >&2; exit 1; }
for path in "$WORK_ROOT" "$PYTHON_ENV_DIR" "$BUILD_LOG_DIR"; do
    [[ "$path" == /* && "$path" != / && "$path" != *[[:space:]]* ]] || {
        printf 'Build paths must be absolute non-root directories without whitespace: %s\n' "$path" >&2; exit 1;
    }
done

# Validate optional cleanup before the installer changes the system.
if [[ "$APT_AUTOREMOVE" != true && "$APT_AUTOREMOVE" != false ]]; then
    printf '%sAPT_AUTOREMOVE must be true or false.%s\n' "$LRED" "$NC" >&2
    exit 1
fi

if [[ ! "$DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ || ( "$BACKUP_DATABASE" != true && "$BACKUP_DATABASE" != false ) ]]; then
    printf '%sUse a simple DB_NAME and set BACKUP_DATABASE to true or false.%s\n' "$LRED" "$NC" >&2
    exit 1
fi

# Validate retry settings before the installer changes the system.
if [[ ! "$FEED_SYNC_ATTEMPTS" =~ ^[1-9][0-9]?$ ]]; then
    printf '%sFEED_SYNC_ATTEMPTS must be an integer from 1 to 99.%s\n' "$LRED" "$NC" >&2
    exit 1
fi
if [[ ! "$FEED_SYNC_RETRY_DELAY" =~ ^(0|[1-9][0-9]{0,3})$ ]] || (( FEED_SYNC_RETRY_DELAY > 3600 )); then
    printf '%sFEED_SYNC_RETRY_DELAY must be an integer from 0 to 3600 seconds.%s\n' "$LRED" "$NC" >&2
    exit 1
fi

if [[ "$WORK_ROOT" != /* || "$WORK_ROOT" == *[[:space:]]* ]]; then
    printf '%sWORK_ROOT must be an absolute path without whitespace, as required by the shared build commands.%s\n' "$LRED" "$NC" >&2
    exit 1
fi

if [[ -t 1 ]]; then clear; fi

# Make sure the user is NOT running this script as root
if [[ $EUID -eq 0 ]]; then
    echo
    echo -e "${LRED}This script must NOT be run as root, it will prompt for sudo when needed." 1>&2
    echo -e ${NC}
    exit 1
fi

# Check if sudo is installed. (Debian does not always include sudo by default.)
if ! command -v sudo &> /dev/null; then
    echo "${LRED}The sudo package is not installed. Please install sudo."
    echo -e ${NC}
    exit 1
fi

# Make sure the user running this script is a member of the sudo group
if ! id -nG "$USER" | grep -qw "sudo"; then
    echo
    echo -e "${LRED}The current user (${USER}) must be a member of the 'sudo' group & be granted sudo privilages to run this script.${NC}" 1>&2
    exit 1
fi

# Authenticate once and keep sudo active during long builds.
sudo -v || exit 1

installer_pid=$$
(
    exec 9>&-
    while kill -0 "$installer_pid" 2>/dev/null; do
        sudo -n -v || exit 1
        sleep 60
    done
) &
sudo_keepalive_pid=$!

# Stop the refresh loop when the installer exits.
# Check identity before any command in an inherited EXIT trap.
trap 'case "$BASHPID" in "$PROGRESS_OWNER_PID") installer_exit "$?" ;; esac' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -t 1 ]]; then clear; fi

# Script branding header
printf '\n%s Itiligent GVM/OpenVAS Appliance Upgrader\n                    %sPowered by Greenbone%s\n\n%s' \
    "$GREYB" "$LGREENB" "$GREY" "$NC"

# Set global variables & paths
export INSTALL_PREFIX=/usr/local
export PATH=$INSTALL_PREFIX/bin:$INSTALL_PREFIX/sbin:$PATH
# Work in a new private tree; never remove the installer's shared ~/source paths.
mkdir -p "$WORK_ROOT" || exit 1
command -v flock >/dev/null || { printf 'Required upgrade tool missing: flock\n' >&2; exit 1; }
acquire_maintenance_lock || exit 1
RUN_DIR=$(mktemp -d "$WORK_ROOT/run-$(date +%Y%m%d-%H%M%S)-XXXXXX") || exit 1
export SOURCE_DIR="$RUN_DIR/source"
export BUILD_DIR="$RUN_DIR/build"
export INSTALL_DIR="$RUN_DIR/install"
mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"
export GNUPGHOME="$RUN_DIR/gnupg"
mkdir -m 700 "$GNUPGHOME"
BACKUP_DIR="$RUN_DIR/backup"
UPGRADE_STARTED=false
UPGRADE_DEST_ROOT=/

# Build dependency helpers. Failures keep the build tree and a private log.
die() {
    exec 1>&"$PROGRESS_FD" 2>&"$PROGRESS_FD"
    finish_progress 1
    printf '\n%s\n' "$*" >&2
    exit 1
}

build_failed() {
    local status="$1" line="$2"
    trap - ERR
    exec 1>&"$PROGRESS_FD" 2>&"$PROGRESS_FD"
    finish_progress "$status"
    printf '\nUpgrade failed at line %s (exit %s).\nLog: %s\nUpgrade sources have been retained.\n' \
        "$line" "$status" "$BUILD_LOG" >&2
    exit "$status"
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

# Upgrade-only helpers: protect the working installation while reusing its builds.
read_only_db() {
    sudo -Hiu postgres env PGOPTIONS='-c default_transaction_read_only=on' \
        psql -X -q -A -t -v ON_ERROR_STOP=1 --dbname="$DB_NAME" -c "$1"
}

record_database_identity() {
    read_only_db 'COPY (SELECT uuid, name FROM public.users ORDER BY uuid) TO STDOUT WITH CSV;' > "$1.users" || return
    read_only_db "SELECT pg_get_userbyid(datdba), COALESCE(datacl::text, '') FROM pg_database WHERE datname = current_database();
SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin, rolreplication, rolbypassrls, rolconnlimit, rolvaliduntil FROM pg_roles WHERE rolname IN ('gvm', 'dba') ORDER BY rolname;
SELECT parent.rolname, child.rolname, (to_jsonb(m) - 'oid' - 'roleid' - 'member')::text FROM pg_auth_members m JOIN pg_roles parent ON parent.oid=m.roleid JOIN pg_roles child ON child.oid=m.member WHERE child.rolname IN ('gvm', 'dba') ORDER BY parent.rolname, child.rolname;" > "$1.permissions"
}

snapshot_protected_state() {
    sudo "$PYTHON_BIN" - "$1" "$UPGRADE_DEST_ROOT" <<'PROTECTED_STATE'
import base64, hashlib, json, os, stat, sys
from pathlib import Path

root = Path(sys.argv[2])
paths = [root / p.lstrip('/') for p in ('/etc/gvm', '/etc/openvas/openvas.conf',
    '/etc/redis/redis-openvas.conf', '/etc/sudoers', '/etc/sudoers.d',
    '/etc/ld.so.conf.d/gvm-local.conf')]
for name in ('gvmd', 'gsad', 'ospd-openvas', 'openvasd', 'redis-server@openvas'):
    paths.extend((root / 'etc/systemd/system' / (name + '.service'),
                  root / 'etc/systemd/system' / (name + '.service.d')))
keys = root / 'var/lib/gvm/gvmd/gnupg'
if keys.exists():
    paths.extend(p for p in keys.rglob('*') if p.is_file() and
                 (p.suffix == '.key' or p.name == 'secring.gpg'))
records = {}
def record(path):
    if not path.exists() and not path.is_symlink():
        return
    s = path.lstat()
    item = dict(mode=stat.S_IMODE(s.st_mode), uid=s.st_uid, gid=s.st_gid)
    if path.is_symlink():
        item['link'] = os.readlink(path)
    elif path.is_file():
        item['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    elif not path.is_dir():
        return
    item['xattrs'] = {n: base64.b64encode(os.getxattr(path, n, follow_symlinks=False)).decode()
                     for n in os.listxattr(path, follow_symlinks=False)}
    records[str(path)] = item
    if path.is_dir() and not path.is_symlink():
        for child in sorted(path.iterdir()):
            record(child)
for path in paths:
    record(path)
with open(sys.argv[1], 'w') as out:
    json.dump(records, out, sort_keys=True)
PROTECTED_STATE
}

check_existing_installation() {
    local service tool server_version
    for tool in "$PYTHON_BIN" curl gpg tar rsync psql pg_dump pg_dumpall pg_restore stat cmp pgrep crontab; do
        command -v "$tool" >/dev/null || { printf 'Required upgrade tool missing: %s\n' "$tool" >&2; return 1; }
    done
    getent passwd gvm > "$RUN_DIR/gvm-account.before" || return
    id gvm >> "$RUN_DIR/gvm-account.before" || return
    for service in redis-server@openvas gsad gvmd ospd-openvas openvasd; do
        systemctl is-active --quiet "$service.service" || { printf 'Existing service is not active: %s\n' "$service.service" >&2; return 1; }
    done
    for tool in "$INSTALL_PREFIX/sbin/gvmd" "$INSTALL_PREFIX/sbin/openvas" "$INSTALL_PREFIX/sbin/gsad" \
                "$INSTALL_PREFIX/bin/openvasd" "$INSTALL_PREFIX/bin/scannerctl"; do
        sudo test -x "$tool" || { printf 'Existing executable missing: %s\n' "$tool" >&2; return 1; }
    done
    for tool in ospd-openvas greenbone-feed-sync gvm-tools pypsrp-cli; do
        [[ -x "$PYTHON_ENV_DIR/$tool/bin/python" ]] || { printf 'Existing Python environment missing: %s\n' "$tool" >&2; return 1; }
    done
    server_version=$(read_only_db 'SHOW server_version_num;') || return
    [[ "$server_version" =~ ^[0-9]{6,}$ ]] || {
        printf 'Cannot determine the existing PostgreSQL major version.\n' >&2
        return 1
    }
    POSTGRESQL_MAJOR=$((server_version / 10000))
    POSTGRESQL=("postgresql-${POSTGRESQL_MAJOR}" "postgresql-server-dev-${POSTGRESQL_MAJOR}")
    PG_CONFIG="/usr/lib/postgresql/${POSTGRESQL_MAJOR}/bin/pg_config"
    # The shared arrays expand an empty POSTGRESQL at startup; add the detected
    # packages once here, preserving every other installer dependency.
    GVMD_DEPS1+=("${POSTGRESQL[@]}")
    PGGVM_DEPS+=("${POSTGRESQL[@]}")
    # The normal upgrader preserves custom launchers; reject them before any
    # service stop. Older global scripts belong on the legacy migration path.
    for tool in ospd-openvas greenbone-feed-sync greenbone-nvt-sync greenbone-scapdata-sync \
        greenbone-certdata-sync gvm-cli gvm-script gvm-pyshell pypsrp-cli; do
        if sudo test -e "$INSTALL_PREFIX/bin/$tool" && ! sudo test -L "$INSTALL_PREFIX/bin/$tool"; then
            printf 'Existing custom/global launcher needs review before upgrade: %s/bin/%s\n' "$INSTALL_PREFIX" "$tool" >&2
            return 1
        fi
    done
    snapshot_protected_state "$RUN_DIR/protected.before.json"
}

reject_gvmd_downgrade() {
    local output current
    output=$(sudo -u gvm "$INSTALL_PREFIX/sbin/gvmd" --version 2>&1)
    current=$(sed -n 's/^Greenbone Vulnerability Manager \([0-9][0-9.]*\).*/\1/p' <<< "$output")
    [[ -n "$current" ]] || die "Cannot read the installed gvmd version."
    dpkg --compare-versions "$GVMD_VERSION" ge "$current" || \
        die "Refusing gvmd downgrade $current -> $GVMD_VERSION; database downgrades are not supported."
    printf 'INSTALLED_GVMD_VERSION=%s\n' "$current" >> "$VERSION_LOG"
}

check_database_compatibility() {
    local current
    current=$(read_only_db "SELECT value FROM public.meta WHERE name = 'database_version';") || return
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
    read_only_db "SELECT extversion FROM pg_extension WHERE extname = 'pg-gvm';" > "$RUN_DIR/pg-gvm.before" || return
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

backup_existing_database() {
    local path
    mkdir -p "$RUN_DIR/backup" || return
    record_database_identity "$RUN_DIR/database.before" || return
    if [[ "$BACKUP_DATABASE" == true ]]; then
        (umask 077; sudo -Hiu postgres pg_dump --format=custom --dbname="$DB_NAME" > "$RUN_DIR/backup/gvmd.dump") || return
        pg_restore --list "$RUN_DIR/backup/gvmd.dump" > "$RUN_DIR/backup/gvmd-archive-list.txt" || return
        [[ -s "$RUN_DIR/backup/gvmd-archive-list.txt" ]] || return 1
        (umask 077; sudo -Hiu postgres pg_dumpall --globals-only > "$RUN_DIR/backup/postgresql-globals.sql") || return
    else
        printf '%sDatabase dump skipped (BACKUP_DATABASE=false).%s\n' "$LYELLOW" "$NC"
    fi
    local -a paths=()
    for path in etc/gvm etc/openvas etc/redis/redis-openvas.conf etc/systemd/system var/lib/gvm/gvmd/gnupg; do
        if sudo test -e "${UPGRADE_DEST_ROOT%/}/$path"; then paths+=("$path"); fi
    done
    (umask 077; sudo tar --acls --xattrs -C "$UPGRADE_DEST_ROOT" -czf - "${paths[@]}" > "$RUN_DIR/backup/configuration-and-keys.tar.gz")
}

check_migrated_database() {
    local current
    current=$(read_only_db "SELECT value FROM public.meta WHERE name = 'database_version';") || return
    [[ "$current" == "$TARGET_DB_REVISION" ]] || { printf 'Database migration did not reach revision %s.\n' "$TARGET_DB_REVISION" >&2; return 1; }
    record_database_identity "$RUN_DIR/database.after" || return
    cmp -s "$RUN_DIR/database.before.users" "$RUN_DIR/database.after.users" || { printf 'Database user identities changed; keep services stopped and review the backup.\n' >&2; return 1; }
    cmp -s "$RUN_DIR/database.before.permissions" "$RUN_DIR/database.after.permissions" || { printf 'Database ownership or role permissions changed; keep services stopped and review the backup.\n' >&2; return 1; }
}

upgrade_file_metadata() {
    sudo "$PYTHON_BIN" - "$1" "$2" "$3" "${4:-$UPGRADE_DEST_ROOT}" <<'UPGRADE_METADATA'
import base64, json, os, stat, sys
from pathlib import Path

operation, stage, metadata = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
root = Path(sys.argv[4])
protected = ('etc/', 'var/', 'run/', 'lib/systemd/', 'usr/lib/systemd/', 'usr/local/etc/')
if operation == 'capture':
    records = {}
    for source in stage.rglob('*'):
        relative = str(source.relative_to(stage))
        if root == Path('/') and any((relative + '/').startswith(p) for p in protected):
            continue
        target = root / relative
        if not target.exists() and not target.is_symlink(): continue
        s = target.lstat()
        if stat.S_ISDIR(s.st_mode): continue
        records[str(target)] = dict(uid=s.st_uid, gid=s.st_gid, mode=stat.S_IMODE(s.st_mode),
            kind=stat.S_IFMT(s.st_mode),
            xattrs={n: base64.b64encode(os.getxattr(target, n, follow_symlinks=False)).decode()
                    for n in os.listxattr(target, follow_symlinks=False)})
    with metadata.open('w') as out: json.dump(records, out)
else:
    for path, item in json.loads(metadata.read_text()).items():
        if not os.path.lexists(path): continue
        if stat.S_IFMT(os.lstat(path).st_mode) != item['kind']:
            continue
        os.chown(path, item['uid'], item['gid'], follow_symlinks=False)
        if not Path(path).is_symlink(): os.chmod(path, item['mode'])
        for name, value in item['xattrs'].items():
            os.setxattr(path, name, base64.b64decode(value), follow_symlinks=False)
UPGRADE_METADATA
}

deploy_web_assets() {
    local source="$1" target="$INSTALL_PREFIX/share/gvm/gsad/web"
    local metadata status=0
    metadata="$RUN_DIR/metadata-gsa.json"
    shift
    [[ -f "$source/index.html" ]] || return 1
    check_web_destination "$target" || return
    upgrade_file_metadata capture "$source" "$metadata" "$target" || return
    sudo rsync -rl --delete --keep-dirlinks --inplace --ignore-times "$@" \
        "$source/" "$target/" || status=$?
    upgrade_file_metadata restore "$source" "$metadata" "$target" || return
    return "$status"
}

install_upgrade_tree() {
    local metadata status=0
    metadata="$RUN_DIR/metadata-$(basename "$1").json"
    upgrade_file_metadata capture "$1" "$metadata" || return
    # Configuration/state are excluded even if a future source install stages them.
    # In-place file updates retain inode-based ACLs; restore owner/mode/capabilities.
    # Release files may have matching lengths/timestamps despite new contents.
    sudo rsync -rlv --keep-dirlinks --inplace --ignore-times \
        --exclude='/etc/***' --exclude='/var/***' --exclude='/run/***' \
        --exclude='/lib/systemd/***' --exclude='/usr/lib/systemd/***' \
        --exclude='/usr/local/etc/***' "$1/" "$UPGRADE_DEST_ROOT/" || status=$?
    upgrade_file_metadata restore "$1" "$metadata" || return
    return "$status"
}

install_upgrade_binary() {
    local stage
    stage="$INSTALL_DIR/$(basename "$2")"
    mkdir -p "$stage$(dirname "$2")" || return
    install -m 755 "$1" "$stage$2" || return
    install_upgrade_tree "$stage"
}

upgrade_launcher() {
    sudo "$PYTHON_BIN" - "$1" "$2" <<'UPGRADE_LAUNCHER'
import os, stat, sys
target, link = sys.argv[1:]
old = os.lstat(link) if os.path.lexists(link) else None
if old and not stat.S_ISLNK(old.st_mode):
    raise SystemExit('Keep the existing custom launcher; review before replacing: ' + link)
temporary = link + '.upgrade-' + str(os.getpid())
try:
    os.symlink(target, temporary)
    os.replace(temporary, link)
    if old: os.chown(link, old.st_uid, old.st_gid, follow_symlinks=False)
finally:
    if os.path.lexists(temporary): os.unlink(temporary)
UPGRADE_LAUNCHER
}

check_preserved_state() {
    getent passwd gvm > "$RUN_DIR/gvm-account.after" || return
    id gvm >> "$RUN_DIR/gvm-account.after" || return
    cmp -s "$RUN_DIR/gvm-account.before" "$RUN_DIR/gvm-account.after" || { printf 'The gvm system account changed; review the upgrade log.\n' >&2; return 1; }
    snapshot_protected_state "$RUN_DIR/protected.after.json" || return
    cmp -s "$RUN_DIR/protected.before.json" "$RUN_DIR/protected.after.json" || { printf 'Protected configuration, permissions or credential keys changed; compare %s/protected.*.json.\n' "$RUN_DIR" >&2; return 1; }
}

# End build dependency helpers.

mkdir -p "$BUILD_LOG_DIR" || exit 1
BUILD_ID="$(date +%Y%m%d-%H%M%S)-$$"
BUILD_LOG="$BUILD_LOG_DIR/$BUILD_ID-upgrade.log"
VERSION_LOG="$BUILD_LOG_DIR/$BUILD_ID-versions.env"
(umask 077; : > "$BUILD_LOG"; : > "$VERSION_LOG") || exit 1
start_logging
printf 'Build log: %s\n' "$BUILD_LOG"
set -Ee -o pipefail
shopt -s inherit_errexit
trap 'build_failed "$?" "$LINENO"' ERR


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
				

section "Checking the existing OpenVAS installation"
run_task "Checking existing services, accounts and database" check_existing_installation

run_logged_task "Downloading the Greenbone source signing key" curl -f -sS -L --retry 3 https://www.greenbone.net/GBCommunitySigningKey.asc -o "$RUN_DIR/GBCommunitySigningKey.asc"
run_logged_task "Checking and importing the signing key" import_signing_key "$RUN_DIR/GBCommunitySigningKey.asc"

section "Checking latest OpenVAS GitHub releases - edit script to force a version"
get_latest_release() {
    local response
    response=$(curl -f -sS -L --retry 3 "https://api.github.com/repos/$1/releases/latest") || return
    "$PYTHON_BIN" -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])' <<< "$response"
}

declare -A repos=(
    [GVM_LIBS_VERSION]="greenbone/gvm-libs"
    [GVMD_VERSION]="greenbone/gvmd"
    [PG_GVM_VERSION]="greenbone/pg-gvm"
    [GSA_VERSION]="greenbone/gsa"
    [GSAD_VERSION]="greenbone/gsad"
    [OPENVAS_SMB_VERSION]="greenbone/openvas-smb"
    [OPENVAS_SCANNER_VERSION]="greenbone/openvas-scanner"
    [OSPD_OPENVAS_VERSION]="greenbone/ospd-openvas"
    [FEED_SYNC_VERSION]="greenbone/greenbone-feed-sync"
    [GVM_TOOLS_VERSION]="greenbone/gvm-tools"
    [PYTHON_GVM_VERSION]="greenbone/python-gvm"
    [PYPSRP_CLI_VERSION]="greenbone/pypsrp-cli"
)

echo -e " ${LGREEN}Selected OpenVAS package releases:${NC}"
start_progress "Checking selected OpenVAS releases"
for version in GVM_LIBS_VERSION GVMD_VERSION PG_GVM_VERSION GSA_VERSION GSAD_VERSION \
    OPENVAS_SMB_VERSION OPENVAS_SCANNER_VERSION OSPD_OPENVAS_VERSION \
    FEED_SYNC_VERSION GVM_TOOLS_VERSION PYTHON_GVM_VERSION PYPSRP_CLI_VERSION; do
    forced="FORCE_$version"
    if [[ -n "${!forced}" ]]; then
        latest_version="${!forced}"
    else
        latest_version=$(get_latest_release "${repos[$version]}")
    fi
    latest_version="${latest_version#v}"
    [[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || die "Invalid release version for ${repos[$version]}: $latest_version"
    printf -v "$version" '%s' "$latest_version"
    export "${version?}"
    echo " $version=$latest_version"
    printf 'FORCE_%s=%s\n' "$version" "$latest_version" >> "$VERSION_LOG"
done
finish_progress "$?"
export OPENVAS_DAEMON="$OPENVAS_SCANNER_VERSION"
printf 'POSTGRESQL_MAJOR=%s\n' "$POSTGRESQL_MAJOR" >> "$VERSION_LOG"
printf 'BACKUP_DATABASE=%s\n' "$BACKUP_DATABASE" >> "$VERSION_LOG"
printf 'APT_AUTOREMOVE=%s\n' "$APT_AUTOREMOVE" >> "$VERSION_LOG"
printf 'FEED_SYNC_ATTEMPTS=%s\nFEED_SYNC_RETRY_DELAY=%s\n' "$FEED_SYNC_ATTEMPTS" "$FEED_SYNC_RETRY_DELAY" >> "$VERSION_LOG"

# Use feed-sync's defaults unless a feed release is explicitly forced.
# Share this command between the initial sync and the daily cron job.
FEED_COMMAND="$INSTALL_PREFIX/bin/greenbone-feed-sync"

if [[ -n "${FORCE_FEED_RELEASE:-}" ]]; then
    [[ "$FORCE_FEED_RELEASE" =~ ^[0-9]+\.[0-9]+$ ]] ||
        die "Invalid feed release: $FORCE_FEED_RELEASE"

    FEED_COMMAND+=" --feed-release $FORCE_FEED_RELEASE"
fi

# Record the requested override; blank means no script-level override.
printf 'FORCE_FEED_RELEASE=%s\n' "${FORCE_FEED_RELEASE:-}" >> "$VERSION_LOG"
section "Checking selected releases against the existing database"
run_logged_task "Refreshing APT package lists for preflight" sudo env DEBIAN_FRONTEND=noninteractive apt-get --allow-releaseinfo-change-codename --error-on=any update
prepare_all_sources
run_logged_task "Checking distro package availability and conflicts" check_dependency_plan
run_logged_task "Checking selected CMake, library and scanner requirements" check_source_requirements
run_task "Checking the GSA web destination" check_web_destination
run_task "Checking selected database versions before the upgrade" check_database_compatibility
run_task "Rejecting GVMD software downgrades" reject_gvmd_downgrade
run_task "Preparing Python preflight build dependencies" prepare_python_build_dependencies
run_logged_task "Checking selected Python and feed requirements" check_selected_compatibility
run_task "Pausing existing feed schedules" pause_migration_cron
run_task "Waiting for running feed updates" check_migration_feed_idle
UPGRADE_STARTED=true
run_task "Stopping OpenVAS services for the upgrade" sudo systemctl stop gsad gvmd ospd-openvas openvasd redis-server@openvas
run_task "Backing up the existing database and recording its account state" backup_existing_database

section "Updating dependency package lists"


dependency_step_1() {
	# Update Linux base
	sudo apt-get --allow-releaseinfo-change-codename --error-on=any update >>"$BUILD_LOG" 2>&1

}
run_logged_task "Updating dependency package lists" dependency_step_1

echo
echo -e "${LGREEN}Dependency package lists updated successfully...${NC}"


section "Installing common dependencies"

dependency_step_2() {
    # Install common dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install --no-install-recommends --assume-yes "${COMMON_DEPS[@]}" >>"$BUILD_LOG" 2>&1
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${MAIL_DEPS[@]}" >>"$BUILD_LOG" 2>&1
    sudo service postfix restart >>"$BUILD_LOG" 2>&1

}
run_logged_task "Installing common dependencies" dependency_step_2

echo
enable_terminal_progress


multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
export PKG_CONFIG_PATH="$INSTALL_PREFIX/lib/pkgconfig:$INSTALL_PREFIX/lib/$multiarch/pkgconfig:$INSTALL_PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
"$PYTHON_BIN" --version
cmake --version
cc --version
printf 'BUILD_OS=%q\nBUILD_ARCH=%q\n' "$PRETTY_NAME" "$multiarch" >> "$VERSION_LOG"


section "Building & installing gvm-libs $GVM_LIBS_VERSION"

dependency_step_3() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${GVMLIBS_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing gvm-libs dependency packages" dependency_step_3

echo

# Download the gvm-libs sources
export GVM_LIBS_VERSION=$GVM_LIBS_VERSION

# Build gvm-libs
echo
mkdir -p $BUILD_DIR/gvm-libs && cd $BUILD_DIR/gvm-libs
run_logged_task "Configuring gvm-libs" cmake $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var
run_logged_task "Compiling gvm-libs" make -j"$BUILD_JOBS"

# Install gvm-libs
mkdir -p $INSTALL_DIR/gvm-libs
run_logged_task "Staging gvm-libs" make DESTDIR=$INSTALL_DIR/gvm-libs install
# Follow existing destination directory links, including /lib -> /usr/lib.
run_logged_task "Installing gvm-libs" install_upgrade_tree "$INSTALL_DIR/gvm-libs"
sudo ldconfig


run_logged_task "Checking gvm-libs pkg-config metadata" env PKG_CONFIG_PATH="$PKG_CONFIG_PATH" pkg-config --exists libgvm_base
component_done gvm-libs "$GVM_LIBS_VERSION"

section "Building & installing gvmd $GVMD_VERSION"

dependency_step_4() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${GVMD_DEPS1[@]}" >>"$BUILD_LOG" 2>&1
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y --no-install-recommends "${GVMD_DEPS2[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing gvmd dependency packages" dependency_step_4

echo

# Selected sources and signatures were verified before stopping services.

# Use headers and extension paths for the selected PostgreSQL server.
[[ -x "$PG_CONFIG" ]] || die "Missing PostgreSQL development tool: $PG_CONFIG"
"$PG_CONFIG" --version
server_version=$(sudo -Hiu postgres psql -X -At -c 'SHOW server_version_num;')
[[ "$server_version" =~ ^[0-9]+$ ]] || die "Cannot determine the default PostgreSQL server version."
(( server_version / 10000 == POSTGRESQL_MAJOR )) || die "Default PostgreSQL cluster does not match PostgreSQL $POSTGRESQL_MAJOR headers. Select the matching cluster before continuing."

# Build gvmd
echo
mkdir -p $BUILD_DIR/gvmd && cd $BUILD_DIR/gvmd
run_logged_task "Configuring gvmd" cmake $SOURCE_DIR/gvmd-$GVMD_VERSION \
  -DPG_CONFIG_EXECUTABLE="$PG_CONFIG" \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DLOCALSTATEDIR=/var \
  -DSYSCONFDIR=/etc \
  -DGVM_DATA_DIR=/var \
  -DGVMD_RUN_DIR=/run/gvmd \
  -DOPENVAS_DEFAULT_SOCKET=/run/ospd/ospd-openvas.sock \
  -DGVM_FEED_LOCK_PATH=/var/lib/gvm/feed-update.lock \
  -DSYSTEMD_SERVICE_DIR=/lib/systemd/system \
  -DLOGROTATE_DIR=/etc/logrotate.d
run_logged_task "Compiling gvmd" make -j"$BUILD_JOBS"

# Install gvmd
mkdir -p $INSTALL_DIR/gvmd
run_logged_task "Staging gvmd" make DESTDIR=$INSTALL_DIR/gvmd install
run_logged_task "Installing gvmd" install_upgrade_tree "$INSTALL_DIR/gvmd"
# Keep the existing gvmd service unit and enablement unchanged.


run_logged_task "Checking gvmd executable" sudo -u gvm "$INSTALL_PREFIX/sbin/gvmd" --version
component_done gvmd "$GVMD_VERSION"

section "Building & installing pg-gvm $PG_GVM_VERSION"

dependency_step_5() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${PGGVM_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing pg-gvm dependency packages" dependency_step_5

echo

# Selected sources and signatures were verified before stopping services.

# Build pg-gvm
echo
mkdir -p $BUILD_DIR/pg-gvm && cd $BUILD_DIR/pg-gvm
run_logged_task "Configuring pg-gvm" cmake $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION \
  -DPGCONFIG="$PG_CONFIG" \
  -DCMAKE_BUILD_TYPE=Release
run_logged_task "Compiling pg-gvm" make -j"$BUILD_JOBS"

# Install pg-gvm
mkdir -p $INSTALL_DIR/pg-gvm
run_logged_task "Staging pg-gvm" make DESTDIR=$INSTALL_DIR/pg-gvm install
run_logged_task "Installing pg-gvm" install_upgrade_tree "$INSTALL_DIR/pg-gvm"
sudo ldconfig


component_done pg-gvm "$PG_GVM_VERSION"

section "Building & installing gsa $GSA_VERSION"
    export GSA_VERSION=$GSA_VERSION

    # Extract & install gsa
    echo
    mkdir -p $SOURCE_DIR/gsa-$GSA_VERSION
    mkdir -p "$INSTALL_DIR/gsa$INSTALL_PREFIX/share/gvm/gsad/web"
    cp -R "$SOURCE_DIR/gsa-$GSA_VERSION/." "$INSTALL_DIR/gsa$INSTALL_PREFIX/share/gvm/gsad/web/"
    run_logged_task "Installing GSA web assets" deploy_web_assets "$SOURCE_DIR/gsa-$GSA_VERSION"


[[ -f "$INSTALL_PREFIX/share/gvm/gsad/web/index.html" ]] || die "Installed GSA has no index.html."
component_done gsa "$GSA_VERSION"

section "Building & installing gsad $GSAD_VERSION"

dependency_step_6() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${GSAD_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing gsad dependency packages" dependency_step_6

echo

# Download gsad sources
echo
export GSAD_VERSION=$GSAD_VERSION

# Build gsad
echo

# Fix HTTPS redirects to use --port (443), rather than --rport (80).
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

mkdir -p "$BUILD_DIR/gsad" && cd "$BUILD_DIR/gsad"
run_logged_task "Configuring gsad" cmake "$SOURCE_DIR/gsad-$GSAD_VERSION" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var \
  -DGVMD_RUN_DIR=/run/gvmd \
  -DGSAD_RUN_DIR=/run/gsad \
  -DLOGROTATE_DIR=/etc/logrotate.d

run_logged_task "Compiling gsad" make -j"$BUILD_JOBS"

# Install gsad
mkdir -p $INSTALL_DIR/gsad
run_logged_task "Staging gsad" make DESTDIR=$INSTALL_DIR/gsad install
run_logged_task "Installing gsad" install_upgrade_tree "$INSTALL_DIR/gsad"

# Keep the existing gsad service unit and enablement unchanged.

run_logged_task "Checking gsad executable" "$INSTALL_PREFIX/sbin/gsad" --version
component_done gsad "$GSAD_VERSION"

section "Building & installing openvas-smb $OPENVAS_SMB_VERSION"

dependency_step_7() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${OPENVASSMB_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing openvas-smb dependency packages" dependency_step_7

echo

# Download the openvas-smb sources
export OPENVAS_SMB_VERSION=$OPENVAS_SMB_VERSION

# Build openvas-smb
echo
mkdir -p $BUILD_DIR/openvas-smb && cd $BUILD_DIR/openvas-smb
run_logged_task "Configuring openvas-smb" cmake $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release
run_logged_task "Compiling openvas-smb" make -j"$BUILD_JOBS"

# Install openvas-smb
mkdir -p $INSTALL_DIR/openvas-smb
run_logged_task "Staging openvas-smb" make DESTDIR=$INSTALL_DIR/openvas-smb install
run_logged_task "Installing openvas-smb" install_upgrade_tree "$INSTALL_DIR/openvas-smb"
sudo ldconfig


component_done openvas-smb "$OPENVAS_SMB_VERSION"

section "Building & installing openvas-scanner $OPENVAS_SCANNER_VERSION"

dependency_step_8() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${OPENVASSCAN_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing openvas-scanner dependency packages" dependency_step_8

echo

# Download openvas-scanner sources
export OPENVAS_SCANNER_VERSION=$OPENVAS_SCANNER_VERSION

# Build openvas-scanner
echo
mkdir -p $BUILD_DIR/openvas-scanner && cd $BUILD_DIR/openvas-scanner
run_logged_task "Configuring openvas-scanner" cmake $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var \
  -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock \
  -DOPENVAS_RUN_DIR=/run/ospd
run_logged_task "Compiling openvas-scanner" make -j"$BUILD_JOBS"

# Install openvas-scanner
mkdir -p $INSTALL_DIR/openvas-scanner
run_logged_task "Staging openvas-scanner" make DESTDIR=$INSTALL_DIR/openvas-scanner install
run_logged_task "Installing openvas-scanner" install_upgrade_tree "$INSTALL_DIR/openvas-scanner"
sudo ldconfig


run_logged_task "Checking openvas-scanner executable" "$INSTALL_PREFIX/sbin/openvas" --version
component_done openvas-scanner "$OPENVAS_SCANNER_VERSION"

section "Building & installing ospd-openvas $OSPD_OPENVAS_VERSION"

dependency_step_9() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${OSPD_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing ospd-openvas dependency packages" dependency_step_9

echo

# Download ospd-openvas sources
export OSPD_OPENVAS_VERSION=$OSPD_OPENVAS_VERSION

# Install ospd-openvas
echo
cd $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION
run_logged_task "Installing ospd-openvas and Python dependencies" install_python_app ospd-openvas "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION"
upgrade_launcher "$PYTHON_ENV_DIR/ospd-openvas/bin/ospd-openvas" "$INSTALL_PREFIX/bin/ospd-openvas"
# --version constructs the daemon before Redis/log permissions are configured.
"$PYTHON_ENV_DIR/ospd-openvas/bin/ospd-openvas" --help >/dev/null
"$PYTHON_ENV_DIR/ospd-openvas/bin/python" -c 'from importlib.metadata import version; print("ospd-openvas " + version("ospd-openvas"))'
# Keep the existing ospd-openvas service unit and enablement unchanged.

component_done ospd-openvas "$OSPD_OPENVAS_VERSION"

section "Building & installing openvasd $OPENVAS_DAEMON"

dependency_step_10() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${OPENVASD_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing openvasd dependency packages" dependency_step_10


# Install Rustup only if absent; the source's rust-toolchain.toml selects Rust.
if [[ ! -x "$HOME/.cargo/bin/rustup" ]]; then
    run_logged_task "Downloading Rustup" curl --proto '=https' --tlsv1.2 -f -sS -L --retry 3 https://sh.rustup.rs -o "$BUILD_DIR/rustup-init.sh"
    run_logged_task "Installing Rustup" sh "$BUILD_DIR/rustup-init.sh" -y --profile minimal --no-modify-path
fi
source "$HOME/.cargo/env"
echo

# openvasd and scannerctl use the already verified scanner source tree.
scanner_source="$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION"
if [[ -f "$scanner_source/rust/crates/nasl-c-lib/libopenvas-krb5-sys/build.rs" ]]; then
    run_task "Building static Kerberos and libpcap libraries" prepare_native_archives "$scanner_source"
fi
cd "$scanner_source/rust"
if [[ -f rust-toolchain.toml ]]; then
    rust_toolchain=$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' rust-toolchain.toml)
    [[ "$rust_toolchain" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]] || die "Cannot read the scanner's Rust toolchain."
    run_task "Preparing the scanner Rust toolchain" rustup toolchain install "$rust_toolchain" --profile minimal
    # Override inherited Rustup settings for this build only.
    export RUSTUP_TOOLCHAIN="$rust_toolchain"
fi
rustc --version
cargo --version
printf 'RUST_VERSION=%q\nCARGO_VERSION=%q\n' "$(rustc --version)" "$(cargo --version)" >> "$VERSION_LOG"
[[ -f Cargo.lock ]] || die "The scanner release does not contain Cargo.lock."
BIN_VERSION="$OPENVAS_SCANNER_VERSION" run_logged_task "Compiling openvasd and scannerctl" cargo build --locked --release --jobs "$BUILD_JOBS" --bin openvasd --bin scannerctl --target-dir "$BUILD_DIR/openvasd-target"
run_logged_task "Installing openvasd" install_upgrade_binary "$BUILD_DIR/openvasd-target/release/openvasd" "$INSTALL_PREFIX/bin/openvasd"
run_logged_task "Installing scannerctl" install_upgrade_binary "$BUILD_DIR/openvasd-target/release/scannerctl" "$INSTALL_PREFIX/bin/scannerctl"

# Keep the existing openvasd service unit and enablement unchanged.

run_logged_task "Checking openvasd executable" "$INSTALL_PREFIX/bin/openvasd" --version
run_logged_task "Checking scannerctl executable" "$INSTALL_PREFIX/bin/scannerctl" --help
component_done openvasd "$OPENVAS_SCANNER_VERSION"
component_done scannerctl "$OPENVAS_SCANNER_VERSION"

section "Building & installing Windows helpers (pypsrp-cli $PYPSRP_CLI_VERSION and Impacket)"
# Windows PSRP is a separate runtime helper, with its own Python dependency set.
start_progress "Installing Windows helper dependencies"
sudo env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${PYPSRP_DEPS[@]}" >>"$BUILD_LOG" 2>&1
finish_progress "$?"
# Upstream does not publish a detached signature for this helper's releases.
run_task "Using prepared pypsrp-cli sources (HTTPS)" download_source pypsrp-cli "$PYPSRP_CLI_VERSION"
windows_packages=("$SOURCE_DIR/pypsrp-cli-$PYPSRP_CLI_VERSION")
# Some distro Impacket wrappers reference missing example files. Keep a working
# distro command; otherwise install both Windows helpers in the isolated env.
if needs_isolated_impacket; then
    windows_packages+=(impacket)
fi
run_logged_task "Installing pypsrp-cli and Python dependencies" install_python_app pypsrp-cli "${windows_packages[@]}"
upgrade_launcher "$PYTHON_ENV_DIR/pypsrp-cli/bin/pypsrp-cli" "$INSTALL_PREFIX/bin/pypsrp-cli"
if (( ${#windows_packages[@]} > 1 )); then
    impacket_command="$PYTHON_ENV_DIR/pypsrp-cli/bin/impacket-wmiexec"
    [[ -x "$impacket_command" ]] || impacket_command="$PYTHON_ENV_DIR/pypsrp-cli/bin/wmiexec.py"
    [[ -x "$impacket_command" ]] || die "The Impacket environment did not install a WMI command."
    upgrade_launcher "$impacket_command" "$INSTALL_PREFIX/bin/impacket-wmiexec"
fi
sudo -u gvm env PATH=/usr/local/bin:/usr/bin:/bin pypsrp-cli --help >/dev/null
sudo -u gvm env PATH=/usr/local/bin:/usr/bin:/bin impacket-wmiexec -h >/dev/null

component_done pypsrp-cli "$PYPSRP_CLI_VERSION"
printf '%s[OK] Impacket WMI command checked as gvm.%s\n' "$LGREEN" "$NC"

section "Setting up greenbone-feed-sync"

dependency_step_11() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${FEED_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing greenbone-feed-sync dependency packages" dependency_step_11


# Install greenbone-feed-sync
run_task "Using verified greenbone-feed-sync sources" download_source greenbone-feed-sync "$FEED_SYNC_VERSION" "greenbone-feed-sync-$FEED_SYNC_VERSION.tar.gz.asc"
run_logged_task "Installing greenbone-feed-sync and Python dependencies" install_python_app greenbone-feed-sync "$SOURCE_DIR/greenbone-feed-sync-$FEED_SYNC_VERSION"
for command in greenbone-feed-sync greenbone-nvt-sync greenbone-scapdata-sync greenbone-certdata-sync; do
    upgrade_launcher "$PYTHON_ENV_DIR/greenbone-feed-sync/bin/$command" "$INSTALL_PREFIX/bin/$command"
done
"$PYTHON_ENV_DIR/greenbone-feed-sync/bin/greenbone-feed-sync" --version


component_done greenbone-feed-sync "$FEED_SYNC_VERSION"

section "Setting up gvm-tools"

dependency_step_12() {
# Install dependencies
sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${GVMTOOLS_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing gvm-tools dependency packages" dependency_step_12


# Install gvm-tools
run_task "Using verified python-gvm sources" download_source python-gvm "$PYTHON_GVM_VERSION" "python-gvm-$PYTHON_GVM_VERSION.tar.gz.asc"
run_task "Using verified gvm-tools sources" download_source gvm-tools "$GVM_TOOLS_VERSION" "gvm-tools-$GVM_TOOLS_VERSION.tar.gz.asc"
run_logged_task "Installing gvm-tools and Python dependencies" install_python_app gvm-tools "$SOURCE_DIR/python-gvm-$PYTHON_GVM_VERSION" "$SOURCE_DIR/gvm-tools-$GVM_TOOLS_VERSION"
for command in gvm-cli gvm-script gvm-pyshell; do
    upgrade_launcher "$PYTHON_ENV_DIR/gvm-tools/bin/$command" "$INSTALL_PREFIX/bin/$command"
done
"$PYTHON_ENV_DIR/gvm-tools/bin/gvm-cli" --help >/dev/null


component_done python-gvm "$PYTHON_GVM_VERSION"
component_done gvm-tools "$GVM_TOOLS_VERSION"

section "Setting up the Redis data store"

dependency_step_13() {
    # Install dependencies
    sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y "${REDIS_DEPS[@]}" >>"$BUILD_LOG" 2>&1
}
run_logged_task "Installing redis dependency packages" dependency_step_13


component_done Redis "$(redis-server --version | awk '{print $3}')"

section "Verifying installed executables"
# Verify the installed executable/library dependencies before configuring services.
sudo ldconfig
"$INSTALL_PREFIX/sbin/openvas" --version
sudo -u gvm "$INSTALL_PREFIX/sbin/gvmd" --version
"$INSTALL_PREFIX/sbin/gsad" --version
"$INSTALL_PREFIX/bin/openvasd" --version
"$INSTALL_PREFIX/bin/scannerctl" --help >/dev/null
# Keep strict error handling active through configuration and service checks.
echo "Build log: $BUILD_LOG"
echo "Resolved versions: $VERSION_LOG"

# Existing Redis/scanner configuration, account permissions, keys,
# certificates, sudoers, firewall and administrative settings are retained.
section "Migrating the existing OpenVAS database for the new software"
run_task "Updating the existing pg-gvm database extension" sudo -Hiu postgres psql -X -v ON_ERROR_STOP=1 --dbname="$DB_NAME" -c 'ALTER EXTENSION "pg-gvm" UPDATE;'
run_task "Migrating the existing GVMD database" sudo -u gvm "$INSTALL_PREFIX/sbin/gvmd" --migrate --database="$DB_NAME"
run_task "Checking the migrated database and retained accounts" check_migrated_database

if [[ "$APT_AUTOREMOVE" == true ]]; then
    run_task "Removing unused APT packages" sudo apt-get autoremove -qq -y
else
    printf '%sSkipping APT autoremove (APT_AUTOREMOVE=false).%s\n' "$LYELLOW" "$NC"
fi

section "Synchronizing existing feeds and starting the existing services"
run_task "Synchronizing Greenbone feeds (${FORCE_FEED_RELEASE:-feed-sync defaults/configuration})" sync_feeds_with_retries
section "Starting and checking the existing services"
start_services
run_task "Checking preserved account and configuration state" check_preserved_state
run_task "Restoring the existing feed schedule" restore_migration_cron resume
UPGRADE_STARTED=false

section "Cleaning up upgrade build files"
cd "$HOME"
run_task "Removing temporary sources" sudo rm -rf "$SOURCE_DIR"
run_task "Removing temporary staging files" sudo rm -rf "$INSTALL_DIR"
run_task "Removing temporary build files" sudo rm -rf "$BUILD_DIR"
stop_logging

section "OpenVAS upgrade complete"
printf 'Use your existing management-console address and credentials.\n'
printf 'Upgrade log: %s%s%s\n' "$GREYB" "$BUILD_LOG" "$NC"
printf 'Resolved versions: %s%s%s\n' "$GREYB" "$VERSION_LOG" "$NC"
printf 'Upgrade state records: %s%s%s\n' "$GREYB" "$RUN_DIR" "$NC"
