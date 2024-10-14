#!/bin/bash
#########################################################################################################################
# Greenbone Vulnerability Manager appliance build script (gvmd v23.x)
# Multi-distro support for numerous Ubuntu, Debian & Raspbian variants
# David Harrop
# June 2024
#########################################################################################################################

#########################################################################################################################
# EDIT THIS SECTION ONLY: All custom settings & dependency mgmt between distros is handled in this section ##############
#########################################################################################################################

## CUSTOM CONFIG SETTINGS ##
DEFAULT_ADMIN_USER="admin"                    # Set the GVM default admin account username
DEFAULT_ADMIN_PASS="password"                 # Set the GVM default admin account password
SERVER_NAME=""                        # Preferred server hostname (installer will prompt if left blank)
LOCAL_DOMAIN=""                       # Local DNS suffix (defaults to hostname.dns-suffix if left blank)
CERT_DOMAIN=""                        # TLS certificate dns domain (defaults to hostname.dns-suffix if left blank)
CERT_COUNTRY="AU"                     # For RSA SSL cert, 2 character country code only, must not be blank
CERT_STATE="Victoria"                 # For RSA SSL cert, Optional to change, must not be blank
CERT_LOCATION="Melbourne"             # For RSA SSL cert, Optional to change, must not be blank
CERT_ORG="Itiligent"                  # For RSA SSL cert, Optional to change, must not be blank
CERT_OU="SecOps"                      # For RSA SSL cert, Optional to change, must not be blank
CERT_DAYS="3650"                      # For RSA SSL cert, number of days until self signed certificate expiry
KEYSIZE=2048                          # RSA certificate encryption strength

## OVERRIDE LATEST RELEASE AUTO SELECTION   eg. 22.9.1 or "" for latest ##
FORCE_GVM_LIBS_VERSION=""                            # see https://github.com/greenbone/gvm-libs
FORCE_GVMD_VERSION=""                                # see https://github.com/greenbone/gvmd
FORCE_PG_GVM_VERSION=""                              # see https://github.com/greenbone/pg-gvm
FORCE_GSA_VERSION=""                                 # see https://github.com/greenbone/gsa
FORCE_GSAD_VERSION=""                                # see https://github.com/greenbone/gsad
FORCE_OPENVAS_SMB_VERSION=""                         # see https://github.com/greenbone/openvas-smb
FORCE_OPENVAS_SCANNER_VERSION=""                     # see https://github.com/greenbone/openvas-scanner
FORCE_OSPD_OPENVAS_VERSION=""                        # see https://github.com/greenbone/ospd-openvas
FORCE_OPENVAS_DAEMON=$FORCE_OPENVAS_SCANNER_VERSION  # Uses same source as scanner

## POSTGRESQL PACKAGE MANAGEMENT ##
source /etc/os-release
export OFFICIAL_POSTGRESQL="false"    # True = Force official Posgresql source repo
# Or override the Postgresql version with a specific distro supplied package.
if [[ "${OFFICIAL_POSTGRESQL}" == "true" ]]; then
    export POSTGRESQL="postgresql-15 postgresql-server-dev-15"
 elif [[ "${OFFICIAL_POSTGRESQL}" != "true" && "${VERSION_CODENAME,,}" == *"bullseye"* ]]; then
    # Distro no longer contains supported Postgresql version packages, forcing official repo
    export OFFICIAL_POSTGRESQL="true"
    export POSTGRESQL="postgresql-15 postgresql-server-dev-15"
elif [[ "${OFFICIAL_POSTGRESQL}" != "true" && "${VERSION_CODENAME,,}" == *"jammy"* ]]; then
    export POSTGRESQL="postgresql postgresql-server-dev-14"
elif [[ "${OFFICIAL_POSTGRESQL}" != "true" && "${VERSION_CODENAME,,}" == *"bookworm"* ]]; then
    export POSTGRESQL="postgresql postgresql-server-dev-15"
elif [[ "${OFFICIAL_POSTGRESQL}" != "true" && ( "${VERSION_CODENAME,,}" == *"trixie"* || "${VERSION_CODENAME,,}" == *"noble"* ) ]]; then
    # Distro no longer contains supported Postgresql version packages, forcing official repo
    export OFFICIAL_POSTGRESQL="true"
    export POSTGRESQL="postgresql-15 postgresql-server-dev-15"
else
    # All other distros not listed will use supported Postgresql version from official source
    export OFFICIAL_POSTGRESQL="true"
    export POSTGRESQL="postgresql-15 postgresql-server-dev-15"
fi

## DEPENDENCY MANAGEMENT ## (Any changes here must be replicated in the upgrade script)
# common
COMMON_DEPS="sudo apt-get install --no-install-recommends --assume-yes build-essential curl cmake pkg-config python3 python3-pip gnupg wget sudo gnupg2 ufw htop git && sudo DEBIAN_FRONTEND="noninteractive" apt-get install postfix mailutils -y && sudo service postfix restart"

# gvm-libs
GVMLIBS_DEPS="sudo apt-get install -y libglib2.0-dev libgpgme-dev libgnutls28-dev uuid-dev libssh-gcrypt-dev libhiredis-dev libxml2-dev libpcap-dev libnet1-dev libpaho-mqtt-dev libldap2-dev libradcli-dev doxygen xmltoman graphviz libcjson-dev"

# gvmd
GVMD_DEPS1="sudo apt-get install -y libglib2.0-dev libgnutls28-dev libpq-dev ${POSTGRESQL} libical-dev xsltproc rsync libbsd-dev libgpgme-dev libcjson-dev"
GVMD_DEPS2="sudo apt-get install -y --no-install-recommends texlive-latex-extra texlive-fonts-recommended xmlstarlet zip rpm fakeroot dpkg nsis gnupg gpgsm wget sshpass openssh-client socat snmp python3 smbclient python3-lxml gnutls-bin xml-twig-tools"

# gsad
GSAD_DEPS="sudo apt-get install -y libmicrohttpd-dev libxml2-dev libglib2.0-dev libgnutls28-dev libbrotli-dev"

# pg-gvm
PGGVM=DEPS="sudo apt-get install -y libglib2.0-dev libical-dev ${POSTGRESQL}"

# openvas-smb
OPENVASSMB_DEPS="sudo apt-get install -y gcc-mingw-w64 libgnutls28-dev libglib2.0-dev libpopt-dev libunistring-dev heimdal-dev perl-base"

# openvas-scanner
OPENVASSCAN_DEPS="sudo apt-get install -y bison libglib2.0-dev libgnutls28-dev libgcrypt20-dev libpcap-dev libgpgme-dev libksba-dev rsync nmap libjson-glib-dev libcurl4-gnutls-dev libbsd-dev python3-impacket libsnmp-dev pandoc pnscan"

# ospd-openvas
OSPD_DEPS="sudo apt-get install -y python3 python3-pip python3-setuptools python3-packaging python3-wrapt python3-cffi python3-psutil python3-lxml python3-defusedxml python3-paramiko python3-redis python3-gnupg python3-paho-mqtt"

# greenbone-feed-sync
FEED_DEPS="sudo apt-get install -y python3 python3-pip"

# gvm-tools
GVMTOOLS_DEPS="sudo apt-get install -y python3 python3-pip python3-venv python3-setuptools python3-packaging python3-lxml python3-defusedxml python3-paramiko"

# redis
REDIS_DEPS="sudo apt-get install -y redis-server"

# openvasd (Any changes here must be replicated in the upgrade script)
if [[ "${VERSION_CODENAME,,}" == *"bullseye"* ]] || [[ "${VERSION_CODENAME,,}" == *"bookworm"* ]]; then
    OPENVASD_DEPS="curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && sudo apt-get install -y -qq pkg-config libssl-dev"
    SOURCE_CARGO_ENV=". \"$HOME/.cargo/env\""
elif [[ "${VERSION_CODENAME,,}" == *"jammy"* ]]; then
    OPENVASD_DEPS="sudo apt-get install -y -qq pkg-config libssl-dev cargo"
    SOURCE_CARGO_ENV=""
elif [[ "${VERSION_CODENAME,,}" == *"noble"* ]]; then
    OPENVASD_DEPS="sudo apt-get install -y -qq pkg-config libssl-dev rust-all"
    SOURCE_CARGO_ENV=""
else
    # Default dependencies
    OPENVASD_DEPS="curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && sudo apt-get install -y -qq pkg-config libssl-dev"
    SOURCE_CARGO_ENV=". \"$HOME/.cargo/env\""
fi

## PIP INSTALL MANAGMENT ## (Any changes here must be replicated in the upgrade script)
# Bullseye
if [[ "${VERSION_CODENAME,,}" == *"bullseye"* ]]; then
    PIP_SUDO_OSPD=""                                  # add "sudo" to ospd install cmd
    PIP_SUDO_FEED=""                                  # add "sudo" to greenbone-feed-updates install cmd
    PIP_SUDO_TOOLS=""                                 # add "sudo" to gvm-tools install cmd
    PIP_OPTIONS="--no-warn-script-location --system"  # pip install arguments
	PIP_UNINSTALL=""
# Bookworm
elif [[ "${VERSION_CODENAME,,}" == *"bookworm"* ]]; then
    PIP_SUDO_OSPD=""
    PIP_SUDO_FEED=""
    PIP_SUDO_TOOLS=""
    PIP_OPTIONS="--no-warn-script-location"
	PIP_UNINSTALL="--break-system-packages"
# Ubuntu 23.04 & 24.04
elif  [[ "${VERSION_CODENAME,,}" == *"noble"* ]]; then
    PIP_SUDO_OSPD="sudo"
    PIP_SUDO_FEED=""
    PIP_SUDO_TOOLS=""
    PIP_OPTIONS="--no-warn-script-location"
	PIP_UNINSTALL="--break-system-packages"
else
# All other distros
    PIP_SUDO_OSPD=""
    PIP_SUDO_FEED=""
    PIP_SUDO_TOOLS=""
    PIP_OPTIONS="--no-warn-script-location"
	PIP_UNINSTALL="--break-system-packages"
fi

#########################################################################################################################
# Start of script actions - NO NEED TO EDIT BELOW THIS POINT ############################################################
#########################################################################################################################

# Set colours
GREY='\033[0;37m'
GREYB='\033[1;37m'
LGREEN='\033[0;92m'
LGREENB='\033[1;92m'
LRED='\033[0;91m'
LPURPLE='\033[0;95m'
LPURPLEB='\033[1;95m'
LYELLOW='\033[0;93m'
NC='\033[0m' #No Colour

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

clear

# Script branding header
echo
echo -e "${GREYB} Itiligent GVM/OpenVAS Appliance Builder"
echo -e "                     ${LGREENB}Powered by Greenbone${GREY}"
echo
echo

# Set global variables & paths
export INSTALL_PREFIX=/usr/local
export PATH=$PATH:$INSTALL_PREFIX/sbin
export SOURCE_DIR=$HOME/source
export BUILD_DIR=$HOME/build
export INSTALL_DIR=$HOME/install

# Get the default route interface IP address as we need this for TLS certificate creation later
DEFAULT_IP=$(ip addr show $(ip route | awk '/default/ { print $5 }') | grep "inet" | head -n 1 | awk '/inet/ {print $2}' | cut -d'/' -f1)

# An intitial dns suffix is needed as a starting value for the script prompts.
get_domain_suffix() {
    echo "$1" | awk '{print $2}'
}
# Search for "search" & "domain" entries in /etc/resolv.conf
search_line=$(grep -E '^search[[:space:]]+' /etc/resolv.conf)
domain_line=$(grep -E '^domain[[:space:]]+' /etc/resolv.conf)
# Check if both "search" & "domain" lines exist
if [[ -n "$search_line" ]] && [[ -n "$domain_line" ]]; then
    # Both "search" & "domain" lines exist, extract the domain suffix from both
    search_suffix=$(get_domain_suffix "$search_line")
    domain_suffix=$(get_domain_suffix "$domain_line")
    # Print the domain suffix that appears first
    if [[ ${#search_suffix} -lt ${#domain_suffix} ]]; then
        DOMAIN_SUFFIX=$search_suffix
    else
        DOMAIN_SUFFIX=$domain_suffix
    fi
elif [[ -n "$search_line" ]]; then
    # If only "search" line exists
    DOMAIN_SUFFIX=$(get_domain_suffix "$search_line")
elif [[ -n "$domain_line" ]]; then
    # If only "domain" line exists
    DOMAIN_SUFFIX=$(get_domain_suffix "$domain_line")
else
    # If no "search" or "domain" lines found
    DOMAIN_SUFFIX="local"
fi

# GVM user setup & use this action to trigger our initial sudo prompt
sudo useradd -r -M -U -G sudo -s /usr/sbin/nologin gvm
sudo usermod -aG gvm $USER

# Fix Python externally managed errors
python_version_dir=$(python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -n 1)
py_file="/usr/lib/python${python_version_dir}/EXTERNALLY-MANAGED"
# Check if the file exists and rename it if it does
if [ -f "$py_file" ]; then
    sudo mv "$py_file" "${py_file}.old"
fi

# Clean up anything from a previously halted install
sudo systemctl stop gsad gvmd ospd-openvas openvasd &>/dev/null
yes | sudo python3 -m pip uninstall ${PIP_UNINSTALL} ospd-openvas greenbone-feed-sync gvm-tools &>/dev/null
cd ~
sudo rm -rf $SOURCE_DIR &>/dev/null
sudo rm -rf $INSTALL_DIR &>/dev/null
sudo rm -rf $BUILD_DIR &>/dev/null
sudo rm -f /etc/openvas/openvas.conf &>/dev/null
sudo rm -f /etc/redis/redis-openvas.conf &>/dev/null
sudo sed -i '/gvm/d' /etc/sudoers &>/dev/null

# Create build directories
mkdir -p $SOURCE_DIR
mkdir -p $BUILD_DIR
mkdir -p $INSTALL_DIR
echo

#########################################################################################################################
# Install menu prompts ##################################################################################################
#########################################################################################################################

# Consistent /etc/hosts & domain suffix values are needed for TLS implementation. The below approach allows the user
# to either hit enter at the prompt to keep current hostname & DNS values, or enter new values for both.

# Ensure SERVER_NAME is consistent with local host entries
if [[ -z ${SERVER_NAME} ]]; then
    echo -e "${LPURPLEB} Update Linux system HOSTNAME? [Enter to keep: ${HOSTNAME}]${GREYB}"
    read -p "              Enter Linux hostname : " SERVER_NAME
    # If hit enter making no SERVER_NAME change, assume the existing hostname as current
    if [[ "${SERVER_NAME}" = "" ]]; then
        SERVER_NAME=$HOSTNAME
    fi
    echo
    # A SERVER_NAME was derived via the prompt
    # Apply the SERVER_NAME value & remove & update any old 127.0.1.1 localhost references
    $(sudo hostnamectl set-hostname $SERVER_NAME &>/dev/null &) &>/dev/null
	sleep 1
    sudo sed -i '/127.0.1.1/d' /etc/hosts &>>/dev/null
    echo '127.0.1.1       '${SERVER_NAME}'' | sudo tee -a /etc/hosts &>>/dev/null
    $(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
else
    echo
    # A SERVER_NAME value was derived from a pre-set script variable
    # Apply the SERVER_NAME value & remove & update any old 127.0.1.1 localhost references
    $(sudo hostnamectl set-hostname $SERVER_NAME &>/dev/null &) &>/dev/null
	sleep 1
    sudo sed -i '/127.0.1.1/d' /etc/hosts &>>/dev/null
    echo '127.0.1.1       '${SERVER_NAME}'' | sudo tee -a /etc/hosts &>>/dev/null
    $(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
fi

# Ensure LOCAL_DOMAIN suffix & localhost entries are consistent
if [[ -z ${LOCAL_DOMAIN} ]]; then
    echo -e "${LPURPLEB} Update Linux LOCAL DNS SUFFIX [Enter to keep: ${SERVER_NAME}.${DOMAIN_SUFFIX}]${GREYB}"
    read -p "              Complete this local domain suffix: $SERVER_NAME." LOCAL_DOMAIN
    # If hit enter making no LOCAL_DOMAIN name change, assume the existing domain suffix as current
    if [[ "${LOCAL_DOMAIN}" = "" ]]; then
        LOCAL_DOMAIN=$DOMAIN_SUFFIX
    fi
    echo
    # A LOCAL_DOMAIN value was derived via the prompt
    # Remove any old localhost & resolv file values & update these with the new LOCAL_DOMAIN value
	$(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
	sleep 1
    sudo sed -i "/${DEFAULT_IP}/d" /etc/hosts
    sudo sed -i '/domain/d' /etc/resolv.conf
    sudo sed -i '/search/d' /etc/resolv.conf
    # Refresh the /etc/hosts file with the server name & new local domain value
    echo ''${DEFAULT_IP}'	'${SERVER_NAME}.${LOCAL_DOMAIN} ${SERVER_NAME}'' | sudo tee -a /etc/hosts &>>/dev/null
    # Refresh /etc/resolv.conf with new domain & search suffix values
    echo 'domain	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>>/dev/null
    echo 'search	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>>/dev/null
    $(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
else
    echo
    # A LOCAL_DOMIN value was derived from a pre-set script variable
    # Remove any old localhost & resolv file values & update these with the new LOCAL_DOMAIN value
	$(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
	sleep 1
    sudo sed -i "/${DEFAULT_IP}/d" /etc/hosts
    sudo sed -i '/domain/d' /etc/resolv.conf
    sudo sed -i '/search/d' /etc/resolv.conf
    # Refresh the /etc/hosts file with the server name & new local domain value
    echo ''${DEFAULT_IP}'	'${SERVER_NAME}.${LOCAL_DOMAIN} ${SERVER_NAME}'' | sudo tee -a /etc/hosts &>>/dev/null
    # Refresh /etc/resolv.conf with new domain & search suffix values
    echo 'domain	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>>/dev/null
    echo 'search	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>>/dev/null
    $(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
fi

# Now that $SERVER_NAME & $LOCAL_DOMAIN values are updated, both values are merged to create
# a local FQDN value (used in the default TLS certificate config & file name)
DEFAULT_FQDN=$SERVER_NAME.$LOCAL_DOMAIN

# If the TLS domain name is not manually overridden at the prompt, keep the default FQDN as the TLS domain name
if [ -z "${CERT_DOMAIN}" ]; then
    CERT_DOMAIN="${DEFAULT_FQDN}"
fi

echo -e "${LPURPLEB} GVM web console admin account name [Enter to use: ${DEFAULT_ADMIN_USER}]${GREYB}"
# Prompt for managment console admin acount username
  read -r -p "              Enter admin account name: " admin_user
  ADMIN_USER=${admin_user:-$DEFAULT_ADMIN_USER}

# Secure prompt for password with confirmation
  while true; do
     read -r -s -p "              Enter admin user password: " password
     echo
     read -r -s -p "              Confirm admin user password: " password_confirm
     echo
      if [ "${password}" == "${password_confirm}" ]; then
         ADMIN_PASS=${password:-$DEFAULT_ADMIN_PASS}
         break
     else
         echo "              Passwords do not match. Please try again."
         echo
     fi
done

echo
echo -e "${LGREEN}###############################################################################"
echo -e " Updating Linux OS"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Update Linux base
    sudo apt-get update &>/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -qq

    # Add the official Postgresql source repo
    if [[ "${OFFICIAL_POSTGRESQL}" == "true" ]]; then
        sudo apt-get -y install lsb-release &>/dev/null
        sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
        sudo wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo tee /etc/apt/trusted.gpg.d/apt.postgresql.org.asc >/dev/null
        sudo apt-get update -qq &>/dev/null
    fi
) &
spin
echo
echo "Linux updated successfully...."

echo
echo -e "${LGREEN}###############################################################################"
echo -e " Installing common dependencies"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $COMMON_DEPS &>/dev/null
	# Import the Greenbone Community Signing Key
    curl -f -L https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc
    gpg --import /tmp/GBCommunitySigningKey.asc
    echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust
) &
spin
echo
echo -e "Common dependencies installed successfully..."

echo
echo -e "${LGREEN}###############################################################################"
echo -e " Checking latest OpenVAS releases - edit script to manually force a version"
echo -e "###############################################################################${NC}"
echo
# Check for the latest OpenVAS release tags from GitHub
get_latest_release() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" | # Get latest release from GitHub API
        grep '"tag_name":' |                                          # Get tag line
        sed -E 's/.*"v?([^"]+)".*/\1/'                                # Extract version
}

# Determine the relevant GitHub repos
declare -A repos=(
    ["GVM_LIBS_VERSION"]="greenbone/gvm-libs"
    ["GVMD_VERSION"]="greenbone/gvmd"
    ["PG_GVM_VERSION"]="greenbone/pg-gvm"
    ["GSA_VERSION"]="greenbone/gsa"
    ["GSAD_VERSION"]="greenbone/gsad"
    ["OPENVAS_SMB_VERSION"]="greenbone/openvas-smb"
    ["OPENVAS_SCANNER_VERSION"]="greenbone/openvas-scanner"
    ["OSPD_OPENVAS_VERSION"]="greenbone/ospd-openvas"
)
echo -e " ${LGREEN}Latest OpenVAS releases will be installed by default:${NC}"
# Get latest OpenVAS versions
for version in "${!repos[@]}"; do
    latest_version=$(get_latest_release "${repos[$version]}")
    if [[ -z $latest_version ]]; then
        echo -e "${LRED}Failed to retrieve the latest version for ${repos[$version]}. Exiting.${NC}"
        exit 1
    fi
    export $version=$latest_version
    echo " $version=$latest_version"
done
# openvasd uses the same repo as scanner
export OPENVAS_DAEMON=$OPENVAS_SCANNER_VERSION
echo " OPENVAS_DAEMON=$OPENVAS_SCANNER_VERSION"

# Check for any version overrides
echo
if [[ -n $FORCE_GVM_LIBS_VERSION ]]; then
    echo -e "${LGREEN} The following package version(s) are manually forced:${NC}"
elif [[ -n $FORCE_GVMD_VERSION ]]; then
    echo -e "${LGREEN} The following package version(s) are manually forced:${NC}"
elif [[ -n $FORCE_PG_GVM_VERSION ]]; then
    echo -e "${LGREEN} The following package version(s) are manually forced:${NC}"
elif [[ -n $FORCE_GSA_VERSION ]]; then
    echo -e "${LGREEN} The following package version(s) are manually forced:${NC}"
elif [[ -n $FORCE_GSAD_VERSION ]]; then
    echo -e "${LGREEN} The following package version(s) are manually forced:${NC}"
elif [[ -n $FORCE_OPENVAS_SMB_VERSION ]]; then
    echo -e "${LGREEN} The following package version(s) are manually forced:${NC}"
elif [[ -n $FORCE_OPENVAS_SCANNER_VERSION ]]; then
    echo -e "${LGREEN} The following package version(s) are manually forced:${NC}"
elif [[ -n $FORCE_OSPD_OPENVAS_VERSION ]]; then
    echo -e "${LGREEN} The following package version(s) are manually forced:${NC}"
elif [[ -n $FORCE_OPENVAS_DAEMON ]]; then
    echo -e "${LGREEN} The following package version(s) are manually forced:${NC}"
fi

if [[ -n $FORCE_GVM_LIBS_VERSION ]]; then
  GVM_LIBS_VERSION=$FORCE_GVM_LIBS_VERSION
  echo -e "${LYELLOW} GVM_LIBS_VERSION=$FORCE_GVM_LIBS_VERSION${NC}"
fi
if [[ -n $FORCE_GVMD_VERSION ]]; then
  GVMD_VERSION=$FORCE_GVMD_VERSION
  echo -e "${LYELLOW} GVMD_VERSION=$FORCE_GVMD_VERSION${NC}"
fi
if [[ -n $FORCE_PG_GVM_VERSION ]]; then
  PG_GVM_VERSION=$FORCE_PG_GVM_VERSION
  echo -e "${LYELLOW} PG_GVM_VERSION=$FORCE_PG_GVM_VERSION${NC}"
fi
if [[ -n $FORCE_GSA_VERSION ]]; then
  GSA_VERSION=$FORCE_GSA_VERSION
  echo -e "${LYELLOW} GSA_VERSION=$FORCE_GSA_VERSION${NC}"
fi
if [[ -n $FORCE_GSAD_VERSION ]]; then
  GSAD_VERSION=$FORCE_GSAD_VERSION
  echo -e "${LYELLOW} GSAD_VERSION=$FORCE_GSAD_VERSION${NC}"
fi
if [[ -n $FORCE_OPENVAS_SMB_VERSION ]]; then
  OPENVAS_SMB_VERSION=$FORCE_OPENVAS_SMB_VERSION
  echo -e "${LYELLOW} OPENVAS_SMB_VERSION=$FORCE_OPENVAS_SMB_VERSION${NC}"
fi
if [[ -n $FORCE_OPENVAS_SCANNER_VERSION ]]; then
  OPENVAS_SCANNER_VERSION=$FORCE_OPENVAS_SCANNER_VERSION
  echo -e "${LYELLOW} OPENVAS_SCANNER_VERSION=$FORCE_OPENVAS_SCANNER_VERSION${NC}"
fi
if [[ -n $FORCE_OSPD_OPENVAS_VERSION ]]; then
  OSPD_OPENVAS_VERSION=$FORCE_OSPD_OPENVAS_VERSION
  echo -e "${LYELLOW} OSPD_OPENVAS_VERSION=$FORCE_OSPD_OPENVAS_VERSION${NC}"
fi
if [[ -n $FORCE_OPENVAS_DAEMON ]]; then
  OPENVAS_DAEMON=$FORCE_OPENVAS_DAEMON
  echo -e "${LYELLOW} OPENVAS_DAEMON=$FORCE_OPENVAS_DAEMON${NC}"
fi

echo
echo -e "${LGREEN}###############################################################################"
echo -e " Building & installing gvm-libs $GVM_LIBS_VERSION"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $GVMLIBS_DEPS &>/dev/null
) &
spin
echo "gvm-libs dependencies installed successfully..."
echo

# Download the gvm-libs sources
export GVM_LIBS_VERSION=$GVM_LIBS_VERSION
curl -f -L https://github.com/greenbone/gvm-libs/archive/refs/tags/v$GVM_LIBS_VERSION.tar.gz -o $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz
curl -f -L https://github.com/greenbone/gvm-libs/releases/download/v$GVM_LIBS_VERSION/gvm-libs-v$GVM_LIBS_VERSION.tar.gz.asc -o $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc
gpg --verify $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz

# Build gvm-libs
echo
tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz
mkdir -p $BUILD_DIR/gvm-libs && cd $BUILD_DIR/gvm-libs
cmake $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var
make -j$(nproc)

# Install gvm-libs
mkdir -p $INSTALL_DIR/gvm-libs
make DESTDIR=$INSTALL_DIR/gvm-libs install
sudo cp -rv $INSTALL_DIR/gvm-libs/* /

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Building & installing gvmd $GVMD_VERSION"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $GVMD_DEPS1 &>/dev/null
    eval $GVMD_DEPS2 &>/dev/null
) &
spin
echo "gvmd dependencies installed successfully..."
echo

# Download the gvm-libs sources
export GVM_LIBS_VERSION=$GVM_LIBS_VERSION
curl -f -L https://github.com/greenbone/gvmd/archive/refs/tags/v$GVMD_VERSION.tar.gz -o $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz
curl -f -L https://github.com/greenbone/gvmd/releases/download/v$GVMD_VERSION/gvmd-$GVMD_VERSION.tar.gz.asc -o $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz.asc
gpg --verify $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz.asc $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz

# Build gvmd
echo
tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz
mkdir -p $BUILD_DIR/gvmd && cd $BUILD_DIR/gvmd
cmake $SOURCE_DIR/gvmd-$GVMD_VERSION \
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
make -j$(nproc)

# Install gvmd
mkdir -p $INSTALL_DIR/gvmd
make DESTDIR=$INSTALL_DIR/gvmd install
sudo cp -rv $INSTALL_DIR/gvmd/* /
cat << EOF > $BUILD_DIR/gvmd.service
[Unit]
Description=Greenbone Vulnerability Manager daemon (gvmd)
After=network.target networking.service postgresql.service ospd-openvas.service
Wants=postgresql.service ospd-openvas.service
Documentation=man:gvmd(8)
ConditionKernelCommandLine=!recovery

[Service]
Type=exec
User=gvm
Group=gvm
PIDFile=/run/gvmd/gvmd.pid
RuntimeDirectory=gvmd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/sbin/gvmd --foreground --osp-vt-update=/run/ospd/ospd-openvas.sock --listen-group=gvm
Restart=always
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo cp -v $BUILD_DIR/gvmd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable gvmd

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Building & installing pg-gvm $PG_GVM_VERSION"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $PGGVM_DEPS &>/dev/null
) &
spin
echo "pg-gvm dependencies installed successfully..."
echo

# Download the pg-gvm sources
export PG_GVM_VERSION=$PG_GVM_VERSION
curl -f -L https://github.com/greenbone/pg-gvm/archive/refs/tags/v$PG_GVM_VERSION.tar.gz -o $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz
curl -f -L https://github.com/greenbone/pg-gvm/releases/download/v$PG_GVM_VERSION/pg-gvm-$PG_GVM_VERSION.tar.gz.asc -o $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz.asc
gpg --verify $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz.asc $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz

# Build pg-gvm
echo
tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz
mkdir -p $BUILD_DIR/pg-gvm && cd $BUILD_DIR/pg-gvm
cmake $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION \
  -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Install pg-gvm
mkdir -p $INSTALL_DIR/pg-gvm
make DESTDIR=$INSTALL_DIR/pg-gvm install
sudo cp -rv $INSTALL_DIR/pg-gvm/* /

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Building & installing gsa $GSA_VERSION"
echo -e "###############################################################################${NC}"
echo
    export GSA_VERSION=$GSA_VERSION
    curl -f -L https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz -o $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz
    curl -f -L https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz.asc -o $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz.asc
    gpg --verify $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz.asc $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz

    # Extract & install gsa
    echo
    mkdir -p $SOURCE_DIR/gsa-$GSA_VERSION
    tar -C $SOURCE_DIR/gsa-$GSA_VERSION -xvzf $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz
    sudo mkdir -p $INSTALL_PREFIX/share/gvm/gsad/web/
    sudo cp -rv $SOURCE_DIR/gsa-$GSA_VERSION/* $INSTALL_PREFIX/share/gvm/gsad/web/

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e "Building & installing gsad, adding certificates for https:443 console access"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $GSAD_DEPS &>/dev/null
) &
spin
echo "gsad dependencies installed successfully..."
echo

# Start TLS certificate creation - remove this for http only
DIR_TLS_CERT="/etc/gvm/certs"   # GVM default certificate location
DIR_TLS_KEY="/etc/gvm/private"  # GVM default certificate location
cd ~
sudo mkdir -p $DIR_TLS_KEY
sudo mkdir -p $DIR_TLS_CERT
sudo chmod -R 644 $DIR_TLS_CERT
cat <<EOF | tee cert_attributes.txt
[req]
distinguished_name  = req_distinguished_name
x509_extensions     = v3_req
prompt              = no
string_mask         = utf8only

[req_distinguished_name]
C                   = $CERT_COUNTRY
ST                  = $CERT_STATE
L                   = $CERT_LOCATION
O                   = $CERT_ORG
OU                  = $CERT_OU
CN                  = *.$(echo $CERT_DOMAIN | cut -d. -f2-)

[v3_req]
keyUsage            = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage    = serverAuth, clientAuth, codeSigning, emailProtection
subjectAltName      = @alt_names

[alt_names]
DNS.1               = $CERT_DOMAIN
DNS.2               = *.$(echo $CERT_DOMAIN | cut -d. -f2-)
IP.1                = $DEFAULT_IP
EOF
echo
openssl req -x509 -nodes -newkey rsa:$KEYSIZE -keyout $CERT_DOMAIN.key -out $CERT_DOMAIN.crt -days $CERT_DAYS -config cert_attributes.txt
# Now create a PFX formatted certificate for easier import to Windows hosts
sudo openssl pkcs12 -export -out $CERT_DOMAIN.pfx -inkey $CERT_DOMAIN.key -in $CERT_DOMAIN.crt -password pass:1234

# Copy new certification output files to a dedicated location & set their acccess permissions
sudo mv $CERT_DOMAIN.crt $DIR_TLS_CERT/$CERT_DOMAIN.crt
sudo mv $CERT_DOMAIN.pfx $DIR_TLS_CERT/$CERT_DOMAIN.pfx
sudo mv $CERT_DOMAIN.key $DIR_TLS_KEY/$CERT_DOMAIN.key
sudo chmod 644 -R $DIR_TLS_CERT
sudo chmod 644 -R $DIR_TLS_KEY
# End TLS certificate creation 

# Download gsad sources
echo
export GSAD_VERSION=$GSAD_VERSION
curl -f -L https://github.com/greenbone/gsad/archive/refs/tags/v$GSAD_VERSION.tar.gz -o $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz
curl -f -L https://github.com/greenbone/gsad/releases/download/v$GSAD_VERSION/gsad-$GSAD_VERSION.tar.gz.asc -o $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz.asc
gpg --verify $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz.asc $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz

# Build gsad
echo
tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz
mkdir -p $BUILD_DIR/gsad && cd $BUILD_DIR/gsad
cmake $SOURCE_DIR/gsad-$GSAD_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var \
  -DGVMD_RUN_DIR=/run/gvmd \
  -DGSAD_RUN_DIR=/run/gsad \
  -DLOGROTATE_DIR=/etc/logrotate.d
make -j$(nproc)

# Install gsad
mkdir -p $INSTALL_DIR/gsad
make DESTDIR=$INSTALL_DIR/gsad install
sudo cp -rv $INSTALL_DIR/gsad/* /
cat << EOF > $BUILD_DIR/gsad.service
[Unit]
Description=Greenbone Security Assistant daemon (gsad)
Documentation=man:gsad(8) https://www.greenbone.net
After=network.target gvmd.service
Wants=gvmd.service

[Service]
Type=exec
#User=gvm
#Group=gvm
RuntimeDirectory=gsad
RuntimeDirectoryMode=2775
PIDFile=/run/gsad/gsad.pid
ExecStart=/usr/local/sbin/gsad --listen=0.0.0.0 --foreground --drop-privileges=gvm --port=443 --rport=80 -c $DIR_TLS_CERT/$CERT_DOMAIN.crt -k $DIR_TLS_KEY/$CERT_DOMAIN.key
#ExecStart=/usr/local/sbin/gsad --foreground --listen=127.0.0.1 --port=9392 --http-only # Swap this line for http only. Change to 0.0.0.0 to bind with all interfaces
Restart=always
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
Alias=greenbone-security-assistant.service
EOF

sudo cp -v $BUILD_DIR/gsad.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable gsad

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Building & installing openvas-smb $OPENVAS_SMB_VERSION"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $OPENVASSMB_DEPS &>/dev/null
) &
spin
echo "openvas-smb dependencies installed successfully..."
echo

# Download the openvas-smb sources
export OPENVAS_SMB_VERSION=$OPENVAS_SMB_VERSION
curl -f -L https://github.com/greenbone/openvas-smb/archive/refs/tags/v$OPENVAS_SMB_VERSION.tar.gz -o $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz
curl -f -L https://github.com/greenbone/openvas-smb/releases/download/v$OPENVAS_SMB_VERSION/openvas-smb-v$OPENVAS_SMB_VERSION.tar.gz.asc -o $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz.asc
gpg --verify $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz.asc $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz

# Build openvas-smb
echo
tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz
mkdir -p $BUILD_DIR/openvas-smb && cd $BUILD_DIR/openvas-smb
cmake $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Install openvas-smb
mkdir -p $INSTALL_DIR/openvas-smb
make DESTDIR=$INSTALL_DIR/openvas-smb install
sudo cp -rv $INSTALL_DIR/openvas-smb/* /

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Building & installing openvas-scanner $OPENVAS_SCANNER_VERSION"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $OPENVASSCAN_DEPS &>/dev/null
) &
spin
echo "openvas-scanner dependencies installed successfully..."
echo

# Download openvas-scanner sources
export OPENVAS_SCANNER_VERSION=$OPENVAS_SCANNER_VERSION
curl -f -L https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_SCANNER_VERSION.tar.gz -o $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz
curl -f -L https://github.com/greenbone/openvas-scanner/releases/download/v$OPENVAS_SCANNER_VERSION/openvas-scanner-v$OPENVAS_SCANNER_VERSION.tar.gz.asc -o $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz.asc
gpg --verify $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz.asc $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz

# Build openvas-scanner
echo
tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz
mkdir -p $BUILD_DIR/openvas-scanner && cd $BUILD_DIR/openvas-scanner
cmake $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DINSTALL_OLD_SYNC_SCRIPT=OFF \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var \
  -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock \
  -DOPENVAS_RUN_DIR=/run/ospd
make -j$(nproc)

# Install openvas-scanner
mkdir -p $INSTALL_DIR/openvas-scanner
make DESTDIR=$INSTALL_DIR/openvas-scanner install
sudo cp -rv $INSTALL_DIR/openvas-scanner/* /
printf "table_driven_lsc = yes\n" | sudo tee /etc/openvas/openvas.conf
sudo printf "openvasd_server = http://127.0.0.1:3000\n" | sudo tee -a /etc/openvas/openvas.conf

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Building & installing ospd-openvas $OSPD_OPENVAS_VERSION"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $OSPD_DEPS &>/dev/null
) &
spin
echo "ospd-openvas dependencies installed successfully..."
echo

# Download ospd-openvas sources
export OSPD_OPENVAS_VERSION=$OSPD_OPENVAS_VERSION
curl -f -L https://github.com/greenbone/ospd-openvas/archive/refs/tags/v$OSPD_OPENVAS_VERSION.tar.gz -o $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz
curl -f -L https://github.com/greenbone/ospd-openvas/releases/download/v$OSPD_OPENVAS_VERSION/ospd-openvas-v$OSPD_OPENVAS_VERSION.tar.gz.asc -o $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz.asc
gpg --verify $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz.asc $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz

# Install ospd-openvas
echo
tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz
cd $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION
mkdir -p $INSTALL_DIR/ospd-openvas
${PIP_SUDO_OSPD} python3 -m pip install --root=$INSTALL_DIR/ospd-openvas ${PIP_OPTIONS} .
sudo cp -rv $INSTALL_DIR/ospd-openvas/* /
cat << EOF > $BUILD_DIR/ospd-openvas.service
[Unit]
Description=OSPd Wrapper for the OpenVAS Scanner (ospd-openvas)
Documentation=man:ospd-openvas(8) man:openvas(8)
After=network.target networking.service redis-server@openvas.service openvasd.service
Wants=redis-server@openvas.service openvasd.service
ConditionKernelCommandLine=!recovery

[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=ospd
RuntimeDirectoryMode=2775
PIDFile=/run/ospd/ospd-openvas.pid
ExecStart=/usr/local/bin/ospd-openvas --foreground --unix-socket /run/ospd/ospd-openvas.sock --pid-file /run/ospd/ospd-openvas.pid --log-file /var/log/gvm/ospd-openvas.log --lock-file-dir /var/lib/openvas --socket-mode 0o770 --notus-feed-dir /var/lib/notus/advisories
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
sudo cp -v $BUILD_DIR/ospd-openvas.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ospd-openvas

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Building & installing openvasd $OPENVAS_DAEMON"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $OPENVASD_DEPS &>/dev/null
) &
spin
eval "$SOURCE_CARGO_ENV"
echo "openvasd rust dependencies installed successfully..."
echo

# Download openvasd sources
echo
export OPENVAS_DAEMON=$OPENVAS_DAEMON
curl -f -L https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_DAEMON.tar.gz -o $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz
curl -f -L https://github.com/greenbone/openvas-scanner/releases/download/v$OPENVAS_DAEMON/openvas-scanner-v$OPENVAS_DAEMON.tar.gz.asc -o $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz.asc
gpg --verify $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz.asc $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz

# Install openvasd
echo
tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz
mkdir -p $INSTALL_DIR/openvasd/usr/local/bin
cd $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON/rust/openvasd
cargo build --release
sudo cp -v ../target/release/openvasd $INSTALL_DIR/openvasd/usr/local/bin/
cd $SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON/rust/scannerctl
cargo build --release
sudo cp -v ../target/release/scannerctl $INSTALL_DIR/openvasd/usr/local/bin/
sudo cp -rv $INSTALL_DIR/openvasd/* /
cat << EOF > $BUILD_DIR/openvasd.service
[Unit]
Description=OpenVASD
Documentation=https://github.com/greenbone/openvas-scanner/tree/main/rust/openvasd
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
RuntimeDirectory=openvasd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/bin/openvasd --mode service_notus --products /var/lib/notus/products --advisories /var/lib/notus/advisories --listening 127.0.0.1:3000
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
EOF
sudo cp -v $BUILD_DIR/openvasd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable openvasd

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Setting up greenbone-feed-sync"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $FEED_DEPS &>/dev/null
) &
spin
echo "greenbone-feed-sync dependencies installed successfully..."
echo

# Install greenbone-feed-sync
mkdir -p $INSTALL_DIR/greenbone-feed-sync
${PIP_SUDO_FEED} python3 -m pip install --root=$INSTALL_DIR/greenbone-feed-sync ${PIP_OPTIONS} greenbone-feed-sync
sudo cp -rv $INSTALL_DIR/greenbone-feed-sync/* /

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Setting up gvm-tools"
echo -e "###############################################################################${NC}"
echo
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
# Install dependencies
eval $GVMTOOLS_DEPS &>/dev/null
) &
spin
echo "gvm-tools dependencies installed successfully..."
echo

# Install gvm-tools
mkdir -p $INSTALL_DIR/gvm-tools
${PIP_SUDO_TOOLS} python3 -m pip install --root=$INSTALL_DIR/gvm-tools ${PIP_OPTIONS} gvm-tools
sudo cp -rv $INSTALL_DIR/gvm-tools/* /

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Setting up the Redis data store"
echo -e "###############################################################################${NC}"
echo 
spin() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${LPURPLE} [%c]  ${NC}" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "\b\b\b\b\b\b"
    printf "            "
    printf "\b\b\b\b\b\b"
	echo -ne "\r"
}
(
    # Install dependencies
    eval $REDIS_DEPS &>/dev/null
) &
spin
echo "redis dependencies installed successfully..."
echo

# Configure redis
sudo cp $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION/config/redis-openvas.conf /etc/redis/
sudo chown redis:redis /etc/redis/redis-openvas.conf
echo "db_address = /run/redis-openvas/redis.sock" | sudo tee -a /etc/openvas/openvas.conf
sudo systemctl start redis-server@openvas.service
sudo systemctl enable redis-server@openvas.service
sudo usermod -aG redis gvm

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Setting up Postgres db, gvm file permissions & importing feed signature."
echo -e "###############################################################################${NC}"
echo
# Setup GVM directories & permissions
sudo mkdir -p /var/lib/notus
sudo mkdir -p /run/gvmd
sudo chown -R gvm:gvm /var/lib/gvm
sudo chown -R gvm:gvm /var/lib/openvas
sudo chown -R gvm:gvm /var/lib/notus
sudo chown -R gvm:gvm /var/log/gvm
sudo chown -R gvm:gvm /run/gvmd
sudo chmod -R g+srw /var/lib/gvm
sudo chmod -R g+srw /var/lib/openvas
sudo chmod -R g+srw /var/log/gvm

# Set gvmd executable permissions
sudo chown gvm:gvm /usr/local/sbin/gvmd
sudo chmod 6750 /usr/local/sbin/gvmd

# Import the update feed's digital signature
curl -f -L https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc
export GNUPGHOME=/tmp/openvas-gnupg
mkdir -p $GNUPGHOME
gpg --import /tmp/GBCommunitySigningKey.asc
echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust
export OPENVAS_GNUPG_HOME=/etc/openvas/gnupg
sudo mkdir -p $OPENVAS_GNUPG_HOME
sudo cp -r /tmp/openvas-gnupg/* $OPENVAS_GNUPG_HOME/
sudo chown -R gvm:gvm $OPENVAS_GNUPG_HOME

# Set sudo permissions on the gvm service account
sudo sh -c "echo '%gvm ALL = NOPASSWD: /usr/local/sbin/openvas' >> /etc/sudoers"

# Set up the gvm PostgreSQL user & database
sudo -Hiu postgres createuser -DRS gvm
sudo -Hiu postgres createdb -O gvm gvmd
sudo -Hiu postgres psql gvmd -c "create role dba with superuser noinherit; grant dba to gvm;"
sudo ldconfig

# Create the GVM admin user
sudo /usr/local/sbin/gvmd --create-user=${ADMIN_USER} --password=${ADMIN_PASS}

# Set the GVM feed import owner to the GVM admin user
sudo /usr/local/sbin/gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value $(sudo /usr/local/sbin/gvmd --get-users --verbose | grep ${ADMIN_USER} | awk '{print $2}')

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
echo -e "${LGREEN}###############################################################################"
echo -e " Cleaning up build sources & setting firewall rules"
echo -e "###############################################################################${NC}"
echo
# Clean up GVM build files
cd ~
sudo rm -rf $SOURCE_DIR
sudo rm -rf $INSTALL_DIR
sudo rm -rf $BUILD_DIR
rm cert_attributes.txt
sudo rm -f /tmp/GBCommunitySigningKey.asc
sudo apt autoremove -qq -y
echo

# Update ufw rules & stop fw log chatter
sudo ufw default allow outgoing
sudo ufw default deny incoming
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
echo "y" | sudo ufw enable >/dev/null
sudo ufw logging off

echo
echo -e "${LGREEN}###############################################################################"
echo -e " Setting up a random daily cron schedule for feed updates"
echo -e "###############################################################################${NC}"
echo
# Schedule a random daily feed update time
HOUR=$(shuf -i 0-23 -n 1)
MINUTE=$(shuf -i 0-59 -n 1)
sudo crontab -l >cron_1
# Remove any previously added feed update schedules
sudo sed -i '/greenbone-feed-sync/d' cron_1
echo "${MINUTE} ${HOUR} * * * /usr/local/bin/greenbone-feed-sync" >>cron_1
sudo crontab cron_1
rm cron_1
echo -e "Feed update scheduled daily at ${HOUR}:${MINUTE}"

echo
echo -e "${LGREEN}###############################################################################"
echo -e " A feed update is required before OpenVAS can start, THIS MAY TAKE A LONG TIME"
echo -e "###############################################################################${NC}"

# Update GVM & start the services
# This must be a one-liner because lengthy feed updates cause sudo credentials to time out before the script can finish.
# Also includes a privs fix becasue gsad is started with --drop-privileges (allowing binding to port 443), this results in gsad.log
# being initially created with the wrong privs on 1st startup.
echo
sudo bash -c '/usr/local/bin/greenbone-feed-sync; systemctl start ospd-openvas; systemctl start gvmd; systemctl start gsad; systemctl start openvasd; sleep 15; systemctl stop gsad; chown -R gvm:gvm /var/log/gvm; systemctl start gsad'

# Cheap hack to display in stdout client certificate configs (where special characters normally break cut/pasteable output)
SHOWASTEXT1='$mypwd'
SHOWASTEXT2='"Cert:\LocalMachine\Root"'

# Display custom instructions for browser client certificate import
echo
printf "${LGREEN}+#############################################################################################################
${LGREEN}+ WINDOWS CLIENT SELF SIGNED SSL BROWSER CONFIG - SAVE THIS BEFORE CONTINUING!${GREY}
+
+ 1. Copy ${GREYB}$DIR_TLS_CERT/$CERT_DOMAIN.pfx${GREY} to a location accessible by Windows.
+ 2. Import the PFX file into your Windows client with the below Powershell commands (as Administrator):
\n"
echo -e "${SHOWASTEXT1} = ConvertTo-SecureString -String "1234" -Force -AsPlainText"
echo -e "Import-pfxCertificate -FilePath $CERT_DOMAIN.pfx -Password "${SHOWASTEXT1}" -CertStoreLocation "${SHOWASTEXT2}""
echo -e "(Clear your browser cache & restart your browser to test.)"
printf "${GREY}+-------------------------------------------------------------------------------------------------------------
${LGREEN}+ LINUX CLIENT SELF SIGNED SSL BROWSER CONFIG - SAVE THIS BEFORE CONTINUING!${GREY}
+
+ 1. Copy ${GREYB}$DIR_TLS_CERT/$CERT_DOMAIN.crt${GREY} to a location accessible by Linux.
+ 2. Import the CRT file into your Linux client certificate store with the below command (as sudo):
\n"
echo -e "mkdir -p \$HOME/.pki/nssdb && certutil -d \$HOME/.pki/nssdb -N"
echo -e "certutil -d sql:\$HOME/.pki/nssdb -A -t "CT,C,c" -n $CERT_DOMAIN -i $CERT_DOMAIN.crt"
printf "${LGREEN}+#############################################################################################################\n"

# Final change password message
echo
echo -e "${LGREEN}OpenVAS build complete\nManagement console = https://${CERT_DOMAIN} - admin username: ${ADMIN_USER} pass: ${ADMIN_PASS}\n${LPURPLEB}Be sure to change the admin password with:"
echo -e sudo /usr/local/sbin/gvmd --user=username --new-password=newpassword
echo -e ${NC}
