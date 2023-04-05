#!/bin/bash
# To install inside Docker comainters, varibles in the local shell cannot be passed through. Therefore this script 
# first dynamically collects the O365 credentials and builds a static script withe all required values, and runs it.
# To procted auth info, after the static secondary script runs it will delete itself.

# Get container settings to map outgoing emails to the SMTP account so no need to specify an exact return email in send commands 
SERVER=$(docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'uname -n')
DOMAIN_SEARCH_SUFFIX=$(docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'grep search /etc/resolv.conf | grep -v "#" | sed  's/'search[[:space:]]'//'')

clear
# Get the Office365 smtp authentication credentials
echo
read -p "Enter O365 SMTP auth enabled email : " SMTP_EMAIL
echo
read -s -p "Enter the SMTP auth account 'app password': " APP_PWD
echo
echo
read -p "Enter an email address to test that email relay is working : " TEST_EMAIL
echo
cat <<EOF > ~/add-smtp-relay-docker.sh
#!/bin/bash
# Remove some default Postifx config items that conflict with new entries
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'sed -i "/relayhost/d" /etc/postfix/main.cf'
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'sed -i "/smtp_tls_security_level=may/d" /etc/postfix/main.cf'
# For simple relay outbound only, limit Postfix to just loopback and IPv4
#docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'sed -i "s/inet_interfaces = all/inet_interfaces = loopback-only/g" /etc/postfix/main.cf'
#docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'sed -i "s/inet_protocols = all/inet_protocols = ipv4/g" /etc/postfix/main.cf'
# Add the new Office365 SMTP auth with TLS settings
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'cat <<EOF | tee -a /etc/postfix/main.cf
relayhost = [smtp.office365.com]:587
smtp_use_tls = yes
smtp_always_send_ehlo = yes
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_tls_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_generic_maps = hash:/etc/postfix/generic
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
EOF'

# Setup the password file and postmap
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'touch /etc/postfix/sasl_passwd'
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'cat <<EOF | tee -a /etc/postfix/sasl_passwd
[smtp.office365.com]:587 ${SMTP_EMAIL}:${APP_PWD}
EOF'

docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'chown root:root /etc/postfix/sasl_passwd'
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'chmod 0600 /etc/postfix/sasl_passwd'
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'postmap /etc/postfix/sasl_passwd'

# Setup the generic map file
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'touch /etc/postfix/generic'
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'cat <<EOF | tee -a /etc/postfix/generic
root@${SERVER} ${SMTP_EMAIL}
@${DOMAIN_SEARCH_SUFFIX} ${SMTP_EMAIL}
EOF'
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'chown root:root /etc/postfix/generic'
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'chmod 0600 /etc/postfix/generic'
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'postmap /etc/postfix/generic'

# Restart and test
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'service postfix restart'
docker exec greenbone-community-edition_gvmd_1 /bin/bash -c 'echo "This is a test email" | mail -s "SMTP Auth Relay Is Working" ${TEST_EMAIL} -a "FROM:${SMTP_EMAIL}"'
rm ~/add-smtp-relay-docker.sh
EOF

chmod +x ~/add-smtp-relay-docker.sh
~/add-smtp-relay-docker.sh
