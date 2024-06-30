#!/bin/bash
#########################################################################################################################
# Greenbone Vulnerability Manager appliance https certificate update script
# David Harrop
# June 2024
# Use this script if:#
# Changing the dns name of your OpenVAS appliance
# Changing the IP adddress or your OpenVAS appliance
# Certificates have expired/about to expire
#########################################################################################################################

CERT_DOMAIN=""                        # Force a TLS certificate dns domain (defaults to hostname.dns-suffix if left blank)
CERT_COUNTRY="AU"                     # For RSA SSL cert, 2 character country code only, must not be blank
CERT_STATE="Victoria"                 # For RSA SSL cert, Optional to change, must not be blank
CERT_LOCATION="Melbourne"             # For RSA SSL cert, Optional to change, must not be blank
CERT_ORG="Itiligent"                  # For RSA SSL cert, Optional to change, must not be blank
CERT_OU="SecOps"                      # For RSA SSL cert, Optional to change, must not be blank
CERT_DAYS="3650"                      # For RSA SSL cert, number of days until self signed certificate expiry
DIR_TLS_CERT="/etc/gvm/certs"         # GVM default certificate location
DIR_TLS_KEY="/etc/gvm/private"        # GVM default certificate location
KEYSIZE=2048                          # RSA certificate encryption strength

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

# Check if user is root or sudo
if ! [[ $(id -u) = 0 ]]; then
    echo
    echo -e "${LRED}Please run this script as sudo or root${NC}" 1>&2
	echo
    exit 1
fi

echo
Clear
echo

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
# System name change prompts
    SERVER_NAME=""
    # Ensure SERVER_NAME is consistent with local host entries
if [[ -z ${SERVER_NAME} ]]; then
    echo -e "${LPURPLEB} Update Linux system HOSTNAME [Enter to keep: ${HOSTNAME}]${GREYB}"
    read -p "              Enter new HOSTNAME : " SERVER_NAME
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

    LOCAL_DOMAIN=""
    # Ensure LOCAL_DOMAIN suffix & localhost entries are consistent
if [[ -z ${LOCAL_DOMAIN} ]]; then
    echo -e "${LPURPLEB} Update Linux LOCAL DNS DOMAIN [Enter to keep: ${DOMAIN_SUFFIX}]${GREYB}"
    read -p "              Enter FULL LOCAL DOMAIN NAME: " LOCAL_DOMAIN
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

# Remove old https certificate
sudo rm -f $DIR_TLS_CERT/*.*
sudo rm -f $DIR_TLS_KEY/*.*

# Create new TLS certificates
cd ~
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

sudo tee /etc/systemd/system/gsad.service > /dev/null << EOF
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
#ExecStart=/usr/local/sbin/gsad --foreground --listen=127.0.0.1 --port=9392 --http-only
Restart=always
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
Alias=greenbone-security-assistant.service
EOF

sudo systemctl daemon-reload
sudo systemctl restart gsad
rm cert_attributes.txt

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