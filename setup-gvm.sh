#!/bin/bash
#######################################################################################################################
# GVM appliance setup script
# For Ubuntu / Debian / Raspian
# David Harrop
# April 2023
#######################################################################################################################

#######################################################################################################################
# Initial enviromment setup ###########################################################################################
#######################################################################################################################

clear

# Prepare text output colours
GREY='\033[0;37m'
DGREY='\033[0;90m'
GREYB='\033[1;37m'
RED='\033[0;31m'
LRED='\033[0;91m'
GREEN='\033[0;32m'
LGREEN='\033[0;92m'
YELLOW='\033[0;33m'
LYELLOW='\033[0;93m'
BLUE='\033[0;34m'
LBLUE='\033[0;94m'
CYAN='\033[0;36m'
LCYAN='\033[0;96m'
MAGENTA='\033[0;35m'
LMAGENTA='\033[0;95m'
NC='\033[0m' #No Colour

#Setup download and temp directory paths
USER_HOME_DIR=$(eval echo ~${SUDO_USER})
DOWNLOAD_DIR=$USER_HOME_DIR/gvm-docker
TMP_DIR=$DOWNLOAD_DIR/tmp
source /etc/os-release
OS_FLAVOUR=$ID
OS_VERSION=$VERSION

# Announce the script we're running
echo
echo -e "${GREYB}Itiligent GVM/OpenVAS Appliance Setup."
echo -e "                 ${LGREEN}Powered by Greenbone"
echo

# Setup directory locations
mkdir -p $DOWNLOAD_DIR
mkdir -p $TMP_DIR

# Install log Location
LOG_LOCATION="${DOWNLOAD_DIR}/gvm_setup.log"

# Greenbone's docker install script download links
GVM_SCRIPT="setup-and-start-greenbone-community-edition.sh"
GVM_SOURCE_LINK="https://greenbone.github.io/docs/latest/_static/"

# Default GVM url
GVM_URL="http://localhost:9392"

# Get the default route interface IP
DEFAULT_IP=$(ip addr show $(ip route | awk '/default/ { print $5 }') | grep "inet" | head -n 1 | awk '/inet/ {print $2}' | cut -d'/' -f1)

# Get the default search suffix for use as a starting domain default prompt value
DOMAIN_SEARCH_SUFFIX=$(grep search /etc/resolv.conf | grep -v "#" | sed  's/'search[[:space:]]'//')

# Non interactive silent setup options - add true/false or specific values
SERVER_NAME=""					# Preferred server hostname
LOCAL_DOMAIN=""					# Local DNS space in use
GVM_VERSION=""					# See https://greenbone.github.io/docs/latest/index.html for release info
GVM_DEFAULT_VERSION="22.4"		# Set a default GVM version to install if none is entered when prompted
INSTALL_NGINX=""				# Install and configure GVM behind Nginx reverse proxy (http port 80 only)
PROXY_SITE=""					# Local DNS name for reverse proxy and self signed ssl certificates
SELF_SIGNED=""					# Add self signed SSL support to Nginx (Let's Encrypt not available)
CERT_COUNTRY="AU"				# 2 coutry charater code only, must not be blank
CERT_STATE="Victoria"			# Optional to change, must not be blank
CERT_LOCATION="Melbourne"		# Optional to change, must not be blank
CERT_ORG="Itiligent"			# Optional to change, must not be blank
CERT_OU="I.T."					# Optional to change, must not be blank
CERT_DAYS="3650"				# Number of days until self signed certificate expiry

# Display status of script customisations at start of install
echo
echo -e "${GREY}Enabled non-interactive presets are listed below, blank entries will prompt."
echo -e "${DGREY}Server host name\t= ${GREY}${SERVER_NAME}"
echo -e "${DGREY}Local DNS Domain\t= ${GREY}${LOCAL_DOMAIN}"
echo -e "${DGREY}GVM version \t\t= ${GREY}${GVM_VERSION}"
echo -e "${DGREY}Add Nginx reverse proxy\t= ${GREY}${INSTALL_NGINX}${GREY}"
echo -e "${DGREY}Reverse proxy DNS name\t= ${GREY}${PROXY_SITE}"
echo -e "${DGREY}Add self signed SSL\t= ${GREY}${SELF_SIGNED}${GREY}"
echo -e "${DGREY}Self signed cert days\t= ${DGREY}${CERT_DAYS}${GREY}"
echo -e "${DGREY}Self signed country\t= ${DGREY}${CERT_COUNTRY}${GREY}"
echo -e "${DGREY}Self signed state\t= ${DGREY}${CERT_STATE}${GREY}"
echo -e "${DGREY}Self signed location\t= ${DGREY}${CERT_LOCATION}${GREY}"
echo -e "${DGREY}Self signed ORG\t\t= ${DGREY}${CERT_ORG}${GREY}"
echo -e "${DGREY}Self signed OU\t\t= ${DGREY}${CERT_OU}${GREY}"

echo
echo -e "${LYELLOW}Ctrl+Z now to exit if you wish to pre-set any above options before continuing."
echo -e "${LYELLOW}After editing this script, run it a again with ./setup-gvm.sh (not as sudo)."

# Now prompt for sudo and set dir permissions so both sudo and non sudo functions can access tmp setup files
echo -e "${LGREEN}"
sudo chmod -R 770 $TMP_DIR
sudo chown -R $SUDO_USER:root $TMP_DIR

# We need a default hostname available to apply even if we do not want to change the hostname. This approach allows the
# user to simply hit enter at the prompt without this creating a blank entry into the /etc/hosts file.
# Hostnames and matching DNS entries are essential for implementing SSL succesfully.
echo
if [[ -z ${SERVER_NAME} ]]; then
	echo -e "${LYELLOW}Update Linux system HOSTNAME [Enter to keep: ${HOSTNAME}]${LGREEN}"
	read -p "                        Enter new HOSTNAME : " SERVER_NAME
	if [[ "${SERVER_NAME}" = "" ]]; then
		SERVER_NAME=$HOSTNAME
		fi
		echo
		sudo hostnamectl set-hostname $SERVER_NAME &>> ${LOG_LOCATION}
		sudo sed -i '/127.0.1.1/d' /etc/hosts &>> ${LOG_LOCATION}
		echo '127.0.1.1       '${SERVER_NAME}'' | sudo tee -a /etc/hosts &>> ${LOG_LOCATION}
		sudo systemctl restart systemd-hostnamed &>> ${LOG_LOCATION}
	else
		echo
		sudo hostnamectl set-hostname $SERVER_NAME &>> ${LOG_LOCATION}
		sudo sed -i '/127.0.1.1/d' /etc/hosts &>> ${LOG_LOCATION}
		echo '127.0.1.1       '${SERVER_NAME}'' | sudo tee -a /etc/hosts &>> ${LOG_LOCATION}
		sudo systemctl restart systemd-hostnamed &>> ${LOG_LOCATION}
	fi

echo
if [[ -z ${LOCAL_DOMAIN} ]]; then
	echo -e "${LYELLOW}Update Linux LOCAL DNS DOMAIN [Enter to keep: .${DOMAIN_SEARCH_SUFFIX}]${LGREEN}"
	read -p "                        Enter LOCAL DOMAIN NAME: " LOCAL_DOMAIN
	if [[ "${LOCAL_DOMAIN}" = "" ]]; then
		LOCAL_DOMAIN=$DOMAIN_SEARCH_SUFFIX
		fi
		echo
		sudo sed -i "/${DEFAULT_IP}/d" /etc/hosts
		sudo sed -i '/domain/d' /etc/resolv.conf
		sudo sed -i '/search/d' /etc/resolv.conf
		# Update the /etc/hosts file with the new domain values 
		echo ''${DEFAULT_IP}'	'${SERVER_NAME}.${LOCAL_DOMAIN}	${SERVER_NAME}'' | sudo tee -a /etc/hosts &>> ${LOG_LOCATION}
		#Update resolv.conf with new domain and search suffix values
		echo 'domain	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>> ${LOG_LOCATION}
		echo 'search	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>> ${LOG_LOCATION}
		sudo systemctl restart systemd-hostnamed &>> ${LOG_LOCATION}
	else
		echo
		sudo sed -i "/${DEFAULT_IP}/d" /etc/hosts
		sudo sed -i '/domain/d' /etc/resolv.conf
		sudo sed -i '/search/d' /etc/resolv.conf
		# Update the /etc/hosts file with the new domain values 
		echo ''${DEFAULT_IP}'	'${SERVER_NAME}.${LOCAL_DOMAIN}	${SERVER_NAME}'' | sudo tee -a /etc/hosts &>> ${LOG_LOCATION}
		#Update resolv.conf with new domain and search suffix values
		echo 'domain	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>> ${LOG_LOCATION}
		echo 'search	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>> ${LOG_LOCATION}
		sudo systemctl restart systemd-hostnamed &>> ${LOG_LOCATION}
	fi

# After updateing the hostname and domain names, we can now use a refreshed value for the local FQDN.
DEFAULT_FQDN=$SERVER_NAME.$LOCAL_DOMAIN


#######################################################################################################################
# Begin install menu prompts ##########################################################################################
#######################################################################################################################

# We needs to select select a version of GVM to install 
echo -e "${LGREEN}"
if [[ -z ${GVM_VERSION} ]]; then
	while true; do
	read -p "GVM VERSION: Select the GVM version [Default ${GVM_DEFAULT_VERSION}]: " GVM_VERSION
	[ "${GVM_VERSION}" = "" ] || [ "${GVM_VERSION}" != "" ] && break
	done
fi

# If a GVM_VERSION is not given, lets assume a the default version
if [ -z ${GVM_VERSION} ]; then
GVM_VERSION="${GVM_DEFAULT_VERSION}"
fi

# Prompt for Guacamole front end reverse proxy option
if [[ -z ${INSTALL_NGINX} ]]; then
	echo
	echo -e -n "${LGREEN}REVERSE PROXY: Protect GVM behind Nginx (y/n)? [default y]: ${GREY}"
	read PROMPT
	if [[ ${PROMPT} =~ ^[Nn]$ ]]; then
	INSTALL_NGINX=false
	else
	INSTALL_NGINX=true
	fi
fi

# We must assign a DNS name for the new proxy site
if [[ -z ${PROXY_SITE} ]] && [[ "${INSTALL_NGINX}" = true ]]; then
	while true; do
	read -p "REVERSE PROXY: Enter proxy local DNS name [Enter to use ${DEFAULT_FQDN}]: " PROXY_SITE
	[ "${PROXY_SITE}" = "" ] || [ "${PROXY_SITE}" != "" ] && break
	# rather than allow any default, alternately force user to enter an explicit name instead
	# [ "${PROXY_SITE}" != "" ] && break
	# echo -e "${RED}You must enter a proxy site DNS name. Please try again.${GREY}" 1>&2
	done
fi

# If no proxy site dns name is given, lets assume a default FQDN
if [ -z ${PROXY_SITE} ]; then
PROXY_SITE="${DEFAULT_FQDN}"
fi

# Prompt for self signed SSL reverse proxy option
if [[ -z ${SELF_SIGNED} ]] && [[ "${INSTALL_NGINX}" = true ]]; then
	# Prompt the user to see if they would like to install self signed SSL support for Nginx, default of no
	echo -e -n "${GREY}REVERSE PROXY: Add self signed SSL support to Nginx? (y/n)? [default n] : "
	read PROMPT
	if [[ ${PROMPT} =~ ^[Yy]$ ]]; then
	SELF_SIGNED=true
	else
	SELF_SIGNED=false
	fi
fi

# Prompt to assign the self sign SSL certficate a custom expiry date, uncomment to force a manual entry
#if [ "${SELF_SIGNED}" = true ]; then
#	read - p "PROXY: Enter number of days till SSL certificate expires [default 3650]: " CERT_DAYS
#fi

# If no self sign SSL certificate expiry given, lets assume a generous 10 year default certificate expiry
if [ -z ${CERT_DAYS} ]; then
	CERT_DAYS="3650"
fi


#######################################################################################################################
# Start global setup actions  #########################################################################################
#######################################################################################################################

clear

# Download config scripts and setup items (snapshot version from github)...
cd $DOWNLOAD_DIR
echo
echo -e "${GREY}Downloading setup files...${DGREY}"
wget -q --show-progress ${GVM_SOURCE_LINK}/${GVM_SCRIPT} -O ${GVM_SCRIPT}
wget -q --show-progress https://raw.githubusercontent.com/itiligent/GVM-Setup/main/add-smtp-relay-o365.sh -O add-smtp-relay-o365.sh
wget -q --show-progress https://raw.githubusercontent.com/itiligent/GVM-Setup/main/prep-windows-gvm-cred-scan.ps1 -O prep-windows-gvm-cred-scan.ps1

# Make all scripts executable
chmod u+x *.sh

# Don't do annoying prompts during apt installs
echo
echo -e "${GREY}Updating base Linux OS from apt..."
export DEBIAN_FRONTEND=noninteractive &>> ${LOG_LOCATION}
# Update everything first
sudo apt-get update &>> ${LOG_LOCATION}
sudo apt-get upgrade -y &>> ${LOG_LOCATION}
sudo apt-get install ufw htop unattended-upgrades -y &>> ${LOG_LOCATION}
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
fi

# Install prerequisites for Docker 
echo
echo -e "${GREY}Installing and setting up Docker, this may take a minute..."
PATH=$PATH:~/.local/bin:
sudo apt install curl docker.io python3 python3-pip -y &>> ${LOG_LOCATION}
python3 -m pip install --user docker-compose &>> ${LOG_LOCATION}
clear
echo
echo -e "${LYELLOW}Please re-enter sudo password for ${USER} to continue setup...${LGREEN}"
sudo usermod -aG docker $USER &>> ${LOG_LOCATION}

# Some tweaks must be made to the GVM proprietary install script to suit our chosen options..
	# Remove the download_dir variable from the Greenbone installer script so we can redirect to our own paths
	sed -i '/DOWNLOAD_DIR=\$/ d' $DOWNLOAD_DIR/${GVM_SCRIPT}
		# Remove the password change prompt in the script as this breaks things
		sed -i '/read/,+2 d' $DOWNLOAD_DIR/${GVM_SCRIPT}
			#Clear screen after pull and up for a neater output
			sed -i -e "/greenbone-community-edition pull/a clear" $DOWNLOAD_DIR/${GVM_SCRIPT}
			sed -i -e "/greenbone-community-edition up/a clear" $DOWNLOAD_DIR/${GVM_SCRIPT}
			# We add this to top of the GVM script for Ubuntu compatibility
			sed -i '2i PATH=$PATH:~/.local/bin:' $DOWNLOAD_DIR/${GVM_SCRIPT}

# Now we run the GVM install script. This must run as sudo but we must also keep to the current user enviromment for docker 
su -s /bin/bash -c ''DOWNLOAD_DIR=$DOWNLOAD_DIR' ./setup-and-start-greenbone-community-edition.sh '$GVM_VERSION'' -m $USER | tee -a &>> ${LOG_LOCATION}

# Create a script for adding postfix (email alerts) and nsis (windows smb credential support) into the gvmd container
echo
echo -e "${GREY}Extending gvmd container to support SMTP email reporting..."
cat <<EOF > $DOWNLOAD_DIR/add-email.sh
#!/bin/bash
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c "apt-get update"
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'DEBIAN_FRONTEND="noninteractive" apt-get install postfix -y' 
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c "apt-get install nano nsis libsasl2-modules mailutils -y"
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c "service postfix restart" 
EOF

if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
fi
chmod u+x $DOWNLOAD_DIR/add-email.sh
sudo $DOWNLOAD_DIR/add-email.sh &>> ${LOG_LOCATION}

# Script to restart postfix if down
cat <<"EOF" > $DOWNLOAD_DIR/mail-up.sh
#!/bin/bash
# check to see if postifx is still running inside docker
MAILUP=$(docker top greenbone-community-edition_gvmd_1 | grep postfix)
if [[ $MAILUP == "" ]]; then
    docker exec greenbone-community-edition_gvmd_1 /bin/bash -c "service postfix restart";
fi
EOF
sudo chmod u+x $DOWNLOAD_DIR/mail-up.sh

# Schedule checks on postifx service
crontab -l > cron_1
	# Remove existing entries to allow multiple runs
	sed -i '/# start postfix/d' cron_1
	sed -i '/# check hourly/d' cron_1
	# Setup cron to keep mail relay started
	echo "@reboot sleep 120 && ${DOWNLOAD_DIR}/mail-up.sh # start postfix 3 mins after reboot" >> cron_1
	echo "0 1-23 * * * ${DOWNLOAD_DIR}/mail-up.sh # check hourly to see if postfix is still running" >> cron_1
# Overwrite the cron settings and cleanup
crontab cron_1
rm cron_1

# Create an update script for gvm and schedule it to run
echo
echo -e "${GREY}Configuring weekly automatic updates for GVM..."
cat <<EOF > $DOWNLOAD_DIR/update-gvm.sh
#!/bin/bash
DOWNLOAD_DIR='$DOWNLOAD_DIR'
GVM_VERSION='$GVM_VERSION'
GVM_SOURCE_LINK='$GVM_SOURCE_LINK'
echo "Updating docker compose file for Greenbone Community Containers \$GVM_VERSION"
wget \$GVM_SOURCE_LINKdocker-compose-\$GVM_VERSION.yml -O \$DOWNLOAD_DIR/docker-compose-\$GVM_VERSION.yml
echo
echo "Pulling Greenbone Community Containers \$GVM_VERSION"
docker-compose -f \$DOWNLOAD_DIR/docker-compose-\$GVM_VERSION.yml -p greenbone-community-edition pull
echo
echo "Starting Greenbone Community Containers \$GVM_VERSION"
docker-compose -f \$DOWNLOAD_DIR/docker-compose-\$GVM_VERSION.yml -p greenbone-community-edition up -d
$DOWNLOAD_DIR/add-email.sh
echo
EOF
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi
chmod u+x $DOWNLOAD_DIR/update-gvm.sh

# Add a GVM update schedule into cron 
crontab -l > cron_2
# Remove existing entry to allow multiple runs
	sed -i '/# update gvm/d' cron_2
	sed -i '/# PATH/d' cron_2
	# Randomly choose a weekely update schedule
	HOUR=$(shuf -i 0-23 -n 1)
	MINUTE=$(shuf -i 0-59 -n 1)
	DAY=$(shuf -i 0-6 -n 1)
	echo PATH=$PATH >> cron_2
	echo "${MINUTE} ${HOUR} * * ${DAY} ${DOWNLOAD_DIR}/update-gvm.sh # update gvm" >> cron_2
# Overwrite the cron settings and cleanup
crontab cron_2
rm cron_2

# Bring GVM containers up on reboot
crontab -l > cron_3
	# Remove existing entries to allow multiple runs
	sed -i '/# greenbone-community-edition up/d' cron_3
	# Setup cron to keep mail relay started
	echo "@reboot sleep 60 && docker-compose -f $DOWNLOAD_DIR/docker-compose-$GVM_VERSION.yml -p greenbone-community-edition up -d # Docker up at boot " >> cron_3
	# Overwrite the cron settings and cleanup
crontab cron_3
rm cron_3

# Create a script to build a firewall rule inside Docker (to defeat stupid docker fw defaults )
echo -e "${GREY}Blocking Docker's network from bypassing the Linux firewall..."
DEFAULT_ROUTE_IF=$(ip route show to default | grep -Eo "dev\s*[[:alnum:]]+" | sed 's/dev\s//g')
cat <<"EOF" > $DOWNLOAD_DIR/docker-fwrule.sh 
#!/bin/bash
# Block HTTP access to the GVM console on default http port 9392
DEFAULT_ROUTE_IF=$(ip route show to default | grep -Eo "dev\s*[[:alnum:]]+" | sed 's/dev\s//g')
sudo iptables -I DOCKER-USER -i $DEFAULT_ROUTE_IF -p tcp -m conntrack --ctorigdstport 9392 -j DROP
EOF
sudo chmod +x $DOWNLOAD_DIR/docker-fwrule.sh
# We need to run the rule manually first time, as the service only executes after a Docker launch
sudo $DOWNLOAD_DIR/docker-fwrule.sh 

# Create a service to add a rule after docker starts at each subsequent reboot
cat <<EOF | sudo tee /etc/systemd/system/docker-fwrule.service > /dev/null 2>&1
[Unit]
Description=must load this rule after docker starts
After=docker.service
BindsTo=docker.service
ReloadPropagatedFrom=docker.service

[Service]
Type=oneshot
ExecStart=$DOWNLOAD_DIR/docker-fwrule.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable docker-fwrule.service > /dev/null 2>&1
sudo systemctl start docker-fwrule.service
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi

#######################################################################################################################
# Start optional setup actions   ######################################################################################
#######################################################################################################################

### Nginx base config #################################################################################################
if [ "${INSTALL_NGINX}" = true ]; then

echo
echo -e "${LGREEN}Installing Nginx...${DGREY}"
echo

# Install Nginx
sudo apt-get install nginx -qq -y &>> ${LOG_LOCATION}

echo -e "${GREY}Configuring Nginx as a reverse proxy for Greenbone's front end...${DGREY}"
# Configure /etc/nginx/sites-available/(local dns site name)
cat <<EOF | sudo tee /etc/nginx/sites-available/$PROXY_SITE
server {
    listen 80 default_server;
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;
    server_name $GVM_URL;
    location / {
        proxy_pass $GVM_URL;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        access_log off;
    }
}
EOF
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi

# Symlink from sites-available to sites-enabled
sudo ln -s /etc/nginx/sites-available/$PROXY_SITE /etc/nginx/sites-enabled/

# Make sure default Nginx site is unlinked
sudo unlink /etc/nginx/sites-enabled/default

# Update general ufw rules so force traffic via reverse proxy. Only Nginx and SSH will be available over the network.
echo -e "${GREY}Updating firewall rules to allow only SSH and tcp 80/443..."
sudo ufw default allow outgoing > /dev/null 2>&1
sudo ufw default deny incoming > /dev/null 2>&1
sudo ufw allow OpenSSH > /dev/null 2>&1
sudo ufw allow 80/tcp > /dev/null 2>&1
sudo ufw allow 443/tcp > /dev/null 2>&1
echo "y" | sudo ufw enable > /dev/null 2>&1
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi

# Reload everything
echo -e "${GREY}Restaring Ngnix..."
sudo systemctl restart nginx
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi
fi


### Nginx SSL config ##################################################################################################
if [ "${SELF_SIGNED}" = true ]; then

echo
echo
echo -e "${LGREEN}Setting up self signed SSL certificates for Nginx...${GREY}"
echo

# Hack to assist with displaying "$" symbols and " ' quotes in a (cut/pasteable) bash screen output format for Nginx configs
SHOWASTEXT1='$mypwd'
SHOWASTEXT2='"Cert:\LocalMachine\Root"'

# Discover all IPv4 interfaces addresses to bind to new SSL certficates
	echo -e "${GREY}Discovering the default route interface and DNS names to bind with the new SSL certificate..."
	# Dump interface info and copy this output to a temp file
	DUMP_IPS=$(ip -o addr show up primary scope global | while read -r num dev fam addr rest; do echo ${addr%/*}; done)
	echo $DUMP_IPS > $TMP_DIR/dump_ips.txt

	# Filter out anything but numerical characters, then add output to a temporary list
	grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" $TMP_DIR/dump_ips.txt > $TMP_DIR/ip_list.txt

	# Separate each row in the temporary ip_list.txt file and further split each single row into a separate new temp file for each individual IP address found
	sed -n '1p' $TMP_DIR/ip_list.txt > $TMP_DIR/1st_ip.txt
	#sed -n '2p' $TMP_DIR/ip_list.txt > $TMP_DIR/2nd_ip.txt # uncomment for 2nd interface
	#sed -n '3p' $TMP_DIR/ip_list.txt > $TMP_DIR/3rd_ip.txt # uncomment for 3rd interface etc

	# Assign each individual IP address temp file a discreet variable for use in the certificate parameters setup
	IP1=$(cat $TMP_DIR/1st_ip.txt)
	#IP2=$(cat $TMP_DIR/2nd_ip.txt) # uncomment for 2nd interface
	#IP3=$(cat $TMP_DIR/3rd_ip.txt) # uncomment for 3rd interface etc
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi

echo -e "${GREY}New self signed SSL certificate attributes are shown below...${DGREY}"
# Display the new SSL cert parameters. Prompt for change if required
cat <<EOF | tee -a $TMP_DIR/cert_attributes.txt
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
CN                  = $PROXY_SITE

[v3_req]
keyUsage            = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage    = serverAuth, clientAuth, codeSigning, emailProtection
subjectAltName      = @alt_names

[alt_names]
DNS.1               = $PROXY_SITE
IP.1                = $IP1
EOF
# Add IP.2 & IP.3 into the above cat <<EOF as needed.
#IP.2                = $IP3
#IP.3                = $IP3
# Additional DNS names can also be manually added into the above cat <<EOF as needed.
#DNS.2               =
#DNS.3               =

# Setup SSL certificate variables
SSLNAME=$PROXY_SITE
SSLDAYS=$CERT_DAYS

# Set default certificate file destinations. These can be adapted for any other SSL application.
DIR_SSL_CERT="/etc/nginx/ssl/cert"
DIR_SSL_KEY="/etc/nginx/ssl/private"

# Make directories to place SSL Certificate if they don't exist
if [[ ! -d $DIR_SSL_KEY ]]; then
	sudo mkdir -p $DIR_SSL_KEY
fi

if [[ ! -d $DIR_SSL_CERT ]]; then
	sudo mkdir -p $DIR_SSL_CERT
fi

echo
echo "{$GREY}Creating a new Nginx SSL Certificate ..."
openssl req -x509 -nodes -newkey rsa:2048 -keyout $SSLNAME.key -out $SSLNAME.crt -days $SSLDAYS -config $TMP_DIR/cert_attributes.txt
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi

# Place SSL Certificate within defined path
	sudo cp $SSLNAME.key $DIR_SSL_KEY/$SSLNAME.key
	sudo cp $SSLNAME.crt $DIR_SSL_CERT/$SSLNAME.crt

# Create a PFX formatted key for easier import to Windows hosts and change permissions to enable copying elsewhere
	echo -e "${GREY}Creating client certificates for Windows & Linux...${GREY}"
	sudo openssl pkcs12 -export -out $SSLNAME.pfx -inkey $SSLNAME.key -in $SSLNAME.crt -password pass:1234
	sudo chmod 0774 $SSLNAME.pfx
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi

# Backup the current Nginx config before update
cp /etc/nginx/sites-enabled/${PROXY_SITE} $DOWNLOAD_DIR/${PROXY_SITE}-nginx.bak
echo -e "${GREY}Backing up previous Nginx proxy to $DOWNLOAD_DIR/$PROXY_SITE-nginx.bak"
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi

# Update Nginx config to accept the new certificates
echo -e "${GREY}Configuring Nginx proxy to use self signed SSL certificates and setting up automatic HTTP to HTTPS redirect...${DGREY}"
#cat > /etc/nginx/sites-available/$PROXY_SITE <<EOL | > /dev/null
cat <<EOF | sudo tee /etc/nginx/sites-available/$PROXY_SITE
server {
    #listen 80 default_server;
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;
    server_name $PROXY_SITE;
    location / {
        proxy_pass $GVM_URL;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        access_log off;
    }
    listen 443 ssl;
    ssl_certificate      /etc/nginx/ssl/cert/$SSLNAME.crt;
    ssl_certificate_key  /etc/nginx/ssl/private/$SSLNAME.key;
    ssl_session_cache shared:SSL:1m;
    ssl_session_timeout  5m;
}
server {
    return 301 https://\$host\$request_uri;
    listen 80 default_server;
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;
    server_name $PROXY_SITE;
    location / {
        proxy_pass $GVM_URL;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        access_log off;
    }
}
EOF
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
	else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi

printf "${GREY}+-------------------------------------------------------------------------------------------------------------
${LGREEN}+ WINDOWS CLIENT SELF SIGNED SSL BROWSER CONFIG - SAVE THIS BEFORE CONTINUING!${GREY}
+
+ 1. In ${DOWNLOAD_DIR} is a new Windows friendly version of the new certificate ${LYELLOW}$SSLNAME.pfx${GREY}
+ 2. Copy this .pfx file to a location accessible by Windows.
+ 3. Import the PFX file into your Windows client with the below Powershell commands (as Administrator):
\n"
echo -e "${SHOWASTEXT1} = ConvertTo-SecureString -String "1234" -Force -AsPlainText"
echo -e "Import-pfxCertificate -FilePath $SSLNAME.pfx -Password "${SHOWASTEXT1}" -CertStoreLocation "${SHOWASTEXT2}""
echo -e "(Clear your browser cache and restart your browser to test.)"
printf "${GREY}+-------------------------------------------------------------------------------------------------------------
${LGREEN}+ LINUX CLIENT SELF SIGNED SSL BROWSER CONFIG - SAVE THIS BEFORE CONTINUING!${GREY}
+
+ 1. In ${DOWNLOAD_DIR} is a new Linux native OpenSSL certificate ${LYELLOW}$SSLNAME.crt${GREY}
+ 2. Copy this file to a location accessible by Linux.
+ 3. Import the CRT file into your Linux client certificate store with the below command (as sudo):
\n"
echo -e "certutil -d sql:$HOME/.pki/nssdb -A -t "CT,C,c" -n $SSLNAME -i $SSLNAME.crt"
echo -e "(If certutil is not installed, run apt-get install libnss3-tools)"
printf "+-------------------------------------------------------------------------------------------------------------\n"
echo
echo -e "${LYELLOW}The above SSL browser config instructions are also saved in ${LGREEN}$LOG_LOCATION${GREY}"
echo

# Reload Nginx
echo -e "${GREY}Restaring Ngnix..."
sudo systemctl restart nginx
if [ $? -ne 0 ]; then
	echo -e "${RED}Failed. See ${LOG_LOCATION}${GREY}" 1>&2
	exit 1
else
	echo -e "${LGREEN}OK${GREY}"
	echo
fi
fi

### End Nginx configs #################################################################################################

 #Final tidy up
mv $USER_HOME_DIR/setup-gvm.sh $DOWNLOAD_DIR
sudo rm -R $TMP_DIR

# Final message dealing with either proxy url on default ports of 80/443 or with standalone GVM on 9392
if [ "${INSTALL_NGINX}" = true ]; then
echo -e "${LGREEN}GVM installation complete\n- Visit: http://${PROXY_SITE}\n- Default login (user/pass): admin/admin\n${LYELLOW}***Be sure to change the password***${GREY}"
else
echo -e "${LGREEN}GVM installation complete\n- Visit: http://${PROXY_SITE}:9392\n- Default login (user/pass): admin/admin\n${LYELLOW}***Be sure to change the password***${GREY}"
fi

# Refresh groups so further manual docker commands from within the current terminal will not fail
exec newgrp docker
echo -e ${NC}
