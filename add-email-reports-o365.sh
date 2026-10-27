#!/bin/bash
###############################################################################
# Microsoft 365 outbound email setup for an OpenVAS appliance
# For Ubuntu / Debian / Raspberry Pi OS
# David Harrop
# November 2026
#
# Run: sudo ./add-email-reports-o365.sh
# Help: ./add-email-reports-o365.sh --help
#
# Configures this host's Postfix for outbound mail submitted locally. Existing
# Postfix configuration is backed up before changes. All non-empty envelope
# and From/Sender header addresses are rewritten to the selected sender address.
# Recipient addresses and null envelope senders (bounces) are not rewritten.
# Intended for an appliance, rather than an existing general-purpose mail server.
#
# Modes:
# 1. IP connector relay: static, unshared public IP; Exchange Online inbound
#    connector configured by your administrator; outbound TCP 25 available.
#    Uses your tenant's MX endpoint. No mailbox/password is required.
# 2. Legacy SMTP AUTH: licensed mailbox; SMTP AUTH and Basic authentication
#    permitted by tenant/mailbox policies; outbound TCP 587 available.
#    App passwords are still Basic authentication. This mode is deprecated.
#
# 
###############################################################################

# Never trace passwords, including when someone invokes this script with bash -x.
set +x
set +v
set -Eeuo pipefail
umask 077

POSTFIX_DIR=/etc/postfix
SASL_FILE="$POSTFIX_DIR/sasl_passwd"
SENDER_FILE="$POSTFIX_DIR/openvas-sender-canonical"
BACKUP_DIR=""
ACTIVE_TASK=""
TASK_STARTED=0
SMTP_PASSWORD=""

# Use the same terminal-aware palette as the installer, upgrader and cert updater.
GREY="" GREYB="" LGREEN="" LGREENB="" LRED="" LPURPLE="" LPURPLEB="" LYELLOW="" NC=""

init_style() {
    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
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
    printf '\n%s###############################################################################\n %s\n###############################################################################%s\n\n' \
        "$LGREEN" "$*" "$NC"
}

die() {
    printf '\n%s[FAILED] %s%s\n' "$LRED" "$*" "$NC" >&2
    if [[ -n "$BACKUP_DIR" ]]; then
        printf 'Original Postfix configuration: %s/postfix\n' "$BACKUP_DIR" >&2
    fi
    exit 1
}

on_error() {
    local status="$1" line="$2"
    trap - ERR
    printf '\n%s[FAILED] %s (line %s, exit %s)%s\n' \
        "$LRED" "${ACTIVE_TASK:-Email setup}" "$line" "$status" "$NC" >&2
    if [[ -n "$BACKUP_DIR" ]]; then
        printf 'Original Postfix configuration: %s/postfix\n' "$BACKUP_DIR" >&2
    fi
    exit "$status"
}

elapsed_time() {
    local seconds="$1"
    printf '%02d:%02d:%02d' "$((seconds / 3600))" "$((seconds / 60 % 60))" "$((seconds % 60))"
}

run_task() {
    ACTIVE_TASK="$1"
    shift
    TASK_STARTED=$SECONDS
    printf '%s[>] %s ...%s\n' "$LPURPLE" "$ACTIVE_TASK" "$NC"
    # Keep package/service output visible while long-running commands execute.
    "$@"
    printf '%s[OK] %s [%s elapsed]%s\n' "$LGREEN" "$ACTIVE_TASK" \
        "$(elapsed_time "$((SECONDS - TASK_STARTED))")" "$NC"
    ACTIVE_TASK=""
}

prompt() {
    local variable="$1" message="$2"
    printf '%s%s%s' "$LYELLOW" "$message" "$NC"
    IFS= read -r "$variable" || die 'Input ended before setup was complete.'
}

validate_email() {
    # Accept ordinary mailbox addresses, without display names or configuration
    # metacharacters. This deliberately is not a full RFC mailbox parser.
    [[ ${#1} -le 254 && "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ && "$1" != *..* ]] ||
        die 'Enter an ordinary email address, for example openvas@example.com.'
}

backup_postfix() {
    [[ -d "$POSTFIX_DIR" && -z "$BACKUP_DIR" ]] || return 0
    BACKUP_DIR=$(mktemp -d "/var/backups/openvas-postfix-$(date +%Y%m%d-%H%M%S)-XXXXXX")
    cp -a -- "$POSTFIX_DIR" "$BACKUP_DIR/postfix"
    printf '%sConfiguration backup: %s%s\n' "$GREYB" "$BACKUP_DIR" "$NC"
}

submit_test_email() {
    {
        printf 'From: %s\nTo: %s\nSubject: OpenVAS Microsoft 365 email test\n\n' "$SMTP_EMAIL" "$TEST_EMAIL"
        printf 'This test was submitted by the OpenVAS host %s using relay %s.\n' "$(uname -n)" "$RELAY_TARGET"
    } | sendmail -i -t -f "$SMTP_EMAIL"
}

usage() {
    cat <<'HELP'
Usage: sudo bash ./add-email-reports-o365.sh

Sets up Postfix on this OpenVAS host for locally submitted outbound email.
Prompts for the delivery method, sender address and an optional test recipient.

1. Microsoft 365 IP connector relay
   Use this for an on-premises host with a static public egress IP belonging
   exclusively to your organisation. Requires outbound TCP 25.
   Before running, ask your Microsoft 365 administrator to:
   - Create/verify an Exchange Online inbound connector from your organisation's
     email server to Microsoft 365, authenticated by that public egress IP.
   - Provide the tenant MX endpoint, e.g. example-com.mail.protection.outlook.com.
   - Verify the sender's domain is accepted in Microsoft 365 and update SPF to
     include the public sending IP. A mailbox for the sender is not required.
   This script configures the local Postfix host, not the Microsoft 365 tenant.
   Microsoft does not support this relay method for third-party hosted services.
   Certificate-authenticated connectors are another supported option, but are
   outside this script's IP connector setup.

2. Legacy SMTP AUTH with a mailbox password or app password
   Uses smtp.office365.com:587 with STARTTLS and a licensed mailbox.
   Requires SMTP AUTH enabled for the mailbox and tenant policies permitting
   Basic authentication. Security Defaults blocks this method. An app password
   does not enable OAuth or bypass tenant authentication policies.
   Use a dedicated non-administrator mailbox. This method is deprecated;
   prefer OAuth or a supported relay method for a new deployment. This script
   does not enable legacy authentication or alter Microsoft 365 security policy.

Both modes require verified TLS 1.2 or newer. Postfix listens on IPv4 loopback
only. All non-empty sender addresses are rewritten to the chosen sender;
recipient addresses are unchanged. Existing Postfix configuration is backed up
under /var/backups before edits. Reruns update settings rather than append them.
Credentials and compiled password maps are readable by root only.

The optional test submits an email to the local Postfix queue. Successful local
submission does not prove Microsoft 365 accepted or delivered the message.
Check the recipient's inbox, Postfix queue and mail logs to confirm delivery.
HELP
}

main() {
    init_style
    if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
        usage
        return 0
    fi
    [[ $# -eq 0 ]] || die 'Unknown argument. Use --help for instructions.'
    [[ $EUID -eq 0 ]] || die 'Run this script with sudo or as root.'
    command -v apt-get >/dev/null || die 'This script requires an apt-based system.'
    trap 'on_error "$?" "$LINENO"' ERR

    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
        clear || true
    fi
    printf '\n%s Itiligent GVM/OpenVAS Email Setup\n                    %sMicrosoft 365%s\n\n' \
        "$GREYB" "$LGREENB" "$NC"

    section 'Choose the Microsoft 365 delivery method'
    printf '%s1. IP connector relay%s - static public IP, tenant connector, TCP 25.\n' "$GREYB" "$NC"
    printf '%s2. Legacy SMTP AUTH%s - mailbox password/app password, TCP 587.\n\n' "$GREYB" "$NC"
    printf 'Use --help for prerequisites and Microsoft 365 administrator setup.\n\n'
    prompt RELAY_MODE 'Choose method [1 or 2]: '

    case "$RELAY_MODE" in
        1)
            section 'Microsoft 365 IP connector relay'
            printf '%sThe inbound connector must already authorise your static, unshared public egress IP.%s\n' "$LYELLOW" "$NC"
            printf 'Use an on-premises host with outbound TCP 25 allowed.\n'
            printf 'Use a sender in an accepted Microsoft 365 domain and include the sending IP in SPF.\n'
            printf 'Microsoft does not support this relay method for third-party hosted services.\n\n'
            prompt CONFIRMED 'Are these connector and network prerequisites in place? [y/N]: '
            [[ "${CONFIRMED,,}" == y || "${CONFIRMED,,}" == yes ]] ||
                die 'Configure the Microsoft 365 IP connector first; see --help.'
            prompt RELAY_HOST 'Tenant MX endpoint (for example example-com.mail.protection.outlook.com): '
            RELAY_HOST="${RELAY_HOST,,}"
            RELAY_HOST="${RELAY_HOST%.}"
            [[ ${#RELAY_HOST} -le 253 && "$RELAY_HOST" =~ ^[a-z0-9][a-z0-9.-]*\.mail\.protection\.outlook\.com$ && "$RELAY_HOST" != *..* ]] ||
                die 'Enter the tenant MX hostname ending in .mail.protection.outlook.com, without a URL or port.'
            RELAY_PORT=25
            prompt SMTP_EMAIL 'Sender email address in your accepted Microsoft 365 domain: '
            validate_email "$SMTP_EMAIL"
            ;;
        2)
            section 'Legacy Microsoft 365 SMTP AUTH'
            printf '%sThis mode uses deprecated Basic authentication, including when using an app password.%s\n' "$LYELLOW" "$NC"
            printf 'The mailbox must be licensed and tenant/mailbox policies must permit Basic SMTP AUTH.\n'
            printf 'Security Defaults blocks this method. This script does not change tenant security policy.\n'
            printf 'Use OAuth or a supported relay method for a new deployment.\n\n'
            prompt SMTP_EMAIL 'Dedicated non-administrator mailbox email address: '
            validate_email "$SMTP_EMAIL"
            printf '%sMailbox password, or app password if permitted (input hidden): %s' "$LYELLOW" "$NC"
            IFS= read -r -s SMTP_PASSWORD || die 'Password input ended before setup was complete.'
            printf '\n'
            [[ -n "$SMTP_PASSWORD" && "$SMTP_PASSWORD" != *[[:space:]]* ]] ||
                die 'The password must be non-empty and contain no whitespace; remove app-password formatting spaces.'
            RELAY_HOST=smtp.office365.com
            RELAY_PORT=587
            ;;
        *) die 'Choose method 1 or 2.' ;;
    esac

    # Capture an existing installation before apt can change package configuration.
    section 'Installing and backing up Postfix'
    run_task 'Backing up any existing Postfix configuration' backup_postfix
    run_task 'Updating package lists' apt-get update
    run_task 'Installing Postfix and SMTP authentication dependencies' \
        env DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        postfix mailutils libsasl2-modules ca-certificates
    [[ -f "$POSTFIX_DIR/main.cf" ]] || die 'Postfix did not create main.cf; run dpkg-reconfigure postfix and retry.'
    # On a fresh installation, retain the package defaults before applying changes.
    run_task 'Saving the Postfix baseline if needed' backup_postfix

    section 'Configuring outbound email'
    # Current Postfix packages may use lmdb rather than Berkeley DB hash maps.
    MAP_TYPE=$(postconf -h default_database_type)
    [[ "$MAP_TYPE" =~ ^[a-z0-9_]+$ ]] || die 'Cannot determine the Postfix database type.'
    MAP_TYPES=$(postconf -m)
    [[ $'\n'"$MAP_TYPES"$'\n' == *$'\n'"$MAP_TYPE"$'\n'* ]] ||
        die "Postfix database type '$MAP_TYPE' is not available."
    [[ $'\n'"$MAP_TYPES"$'\n' == *$'\nregexp\n'* ]] ||
        die 'This Postfix installation needs regexp table support.'

    RELAY_TARGET="[$RELAY_HOST]:$RELAY_PORT"
    install -o root -g root -m 0600 /dev/null "$SASL_FILE"
    if [[ "$RELAY_MODE" == 2 ]]; then
        # printf is a shell builtin: the password is not placed in process arguments.
        printf '%s %s:%s\n' "$RELAY_TARGET" "$SMTP_EMAIL" "$SMTP_PASSWORD" > "$SASL_FILE"
    fi
    unset SMTP_PASSWORD
    # Building an empty map in connector mode also clears any previous credentials
    # from the active database. Protected backup copies remain in BACKUP_DIR.
    run_task 'Building the protected SMTP credential map' postmap "$MAP_TYPE:$SASL_FILE"
    for map_file in "$SASL_FILE" "$SASL_FILE".*; do
        [[ -f "$map_file" ]] || continue
        chown root:root "$map_file"
        chmod 0600 "$map_file"
    done

    # Rewrite senders only. A generic map can also rewrite recipients, which is
    # undesirable here. Exclude both empty and <> null-envelope representations.
    # This map contains no secrets and is readable by Postfix's cleanup service.
    install -o root -g root -m 0644 /dev/null "$SENDER_FILE"
    printf '/^[^<>]+$/ %s\n' "$SMTP_EMAIL" > "$SENDER_FILE"

    run_task 'Applying the Postfix relay, TLS and sender settings' postconf -e \
        "relayhost = $RELAY_TARGET" \
        'inet_interfaces = loopback-only' \
        'inet_protocols = ipv4' \
        'mynetworks = 127.0.0.0/8' \
        'smtp_tls_security_level = secure' \
        'smtp_tls_secure_cert_match = nexthop' \
        'smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt' \
        'smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1' \
        'smtp_tls_wrappermode = no' \
        'smtp_tls_policy_maps =' \
        'smtp_sasl_security_options = noanonymous' \
        'smtp_sasl_tls_security_options = noanonymous' \
        'smtp_generic_maps =' \
        'sender_canonical_classes = envelope_sender, header_sender' \
        "sender_canonical_maps = regexp:$SENDER_FILE"

    if [[ "$RELAY_MODE" == 2 ]]; then
        postconf -e 'smtp_sasl_auth_enable = yes' "smtp_sasl_password_maps = $MAP_TYPE:$SASL_FILE"
    else
        postconf -e 'smtp_sasl_auth_enable = no' 'smtp_sasl_password_maps ='
    fi

    section 'Checking and restarting Postfix'
    run_task 'Checking the Postfix configuration' postfix check
    run_task 'Restarting Postfix' service postfix restart
    run_task 'Checking Postfix is running' postfix status

    section 'Optional email delivery test'
    prompt TEST_EMAIL 'Test recipient email address (Enter to skip): '
    if [[ -n "$TEST_EMAIL" ]]; then
        validate_email "$TEST_EMAIL"
        run_task 'Submitting the test email to the local queue' submit_test_email
        printf '\n%sTest email queued locally. Confirm receipt to verify end-to-end delivery.%s\n' "$LYELLOW" "$NC"
    fi

    section 'Postfix email setup complete'
    printf 'Relay:  %s%s%s\nSender: %s%s%s\nBackup: %s%s%s\n\n' \
        "$GREYB" "$RELAY_TARGET" "$NC" "$GREYB" "$SMTP_EMAIL" "$NC" "$GREYB" "$BACKUP_DIR" "$NC"
    printf 'Inspect queued messages: sudo postqueue -p\n'
    printf 'Inspect mail logs:       sudo tail -n 80 /var/log/mail.log\n'
    printf 'If mail.log is absent:   sudo journalctl --since "10 minutes ago" --no-pager | grep -i postfix\n'
    printf '\nMail accepted into the local queue may still be deferred or rejected by Microsoft 365.\n'
}

main "$@"
