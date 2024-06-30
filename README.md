# Greenbone Vulnerability Scanner Appliance Build Script

## 📦 Auto Setup Link (latest gvmd v23.x)
**(Do NOT run installer or upgrade scripts as sudo or root, scripts will prompt for sudo)**
```bash
wget https://raw.githubusercontent.com/itiligent/OpenVAS-Appliance-Builder/main/openvas-builder.sh && chmod +x openvas-builder.sh && ./openvas-builder.sh
```

### 📦 Auto Upgrade Link
```bash
wget https://raw.githubusercontent.com/itiligent/OpenVAS-Appliance-Builder/main/openvas-upgrade.sh && chmod +x openvas-upgrade.sh  && ./openvas-upgrade.sh 
```

## 📋 Prerequisites

- **Script defaults are set to build a full appliance with the latest OpenVAS releases for the following OS**:
  - Ubuntu 22.04 LTS (Jammy) |  23.04 (Lunar) | 24.04 LTS (Noble) 
  - Debian 11.x (Buster) | 12.x (Bookworm) 
  - Raspbian (Buster | Bookworm)
- **Required Packages**:
  - curl & sudo 
- **Hardware Requirements**:
  - Minimum 8GB RAM
  - Minimum 80GB Storage
- **Network Requirements**:
  - IPv6 enabled
  - Avoid multiple NICs
- **Permissions**:
  - You must use a user account in the sudo group to run the script, do not run as root. 🛡️
- **Optional**:
  - Email reports require an O365 email-enabled account & email relay permitted from the scanner IP address
  - A private DNS entry for your appliance (helps avoid browser HTTPS errors - also requires client side certificate import, see below)

## 📖 Instructions
All custom configuration options for multi-distro support and HTTPs are managed in the top section of this script (shown below).  Both install and upgrade scripts check GitHub for the latest release versions to install, or specific versions can also be forced.
```
## CUSTOM CONFIG SETTINGS ##
ADMIN_USER="admin"
ADMIN_PASS="password"
SERVER_NAME=""
LOCAL_DOMAIN=""
CERT_DOMAIN=""
CERT_COUNTRY="AU"
CERT_STATE="Victoria"
CERT_LOCATION="Melbourne"
CERT_ORG="Itiligent"
CERT_OU="SecOps"
CERT_DAYS="3650"
KEYSIZE=2048

## POSTGRESQL PACKAGE MANAGEMENT ##
 - This section manages distro specfic PostgresSQL package selection logic
   (can be further expanded to support any distro flavour)

## DEPENDENCY MANAGEMENT ##
 - This section manages debian based dependency installation commands for each GVM module
   (can be further expanded to support any distro flavour))

## PIP INSTALL MANAGMENT ##
 - This section manages pip install command variations between distros & Python versions
  (can be further expanded to support any distro flavour)

## OVERRIDE LATEST RELEASE AUTO DOWNLOAD ##
This section allows forcing a specifc OpenVAS component version in case of issues
```` 

## 📧 Adding Email Reporting to the Community Edition
*(normally a pro version feature)*

A Postfix MTA is installed by default. Simply configure the included template script `add-email-reports-o365.sh` with your own O365 app password and mail relay configuration.

## ⬆️ Upgrading & Updating the Scanner

- A CVE feed update is scheduled by the installer once daily at a random time and this can be manually adjusted via cron.
- To upgrade the full appliance, run  `openvas-upgrade.sh` from the link above..

## 🔒 Web Management Console HTTPS Security

The OpenVAS web console is automatically configured for HTTP redirect to HTTPS on port 443. Instructions for importing browser certificates into Windows and Linux clients to avoid browser HTTPS warnings are provided on-screen when the build script completes. If you wish you change the system's DNS name/IP address, or if certificates need to be renewed simply run [update-certificates.sh](https://github.com/itiligent/OpenVAS-Appliance-Builder/blob/main/update-certificates.sh)


## 💻 Authenticated Vulnerability Scans Against Windows Hosts
*(normally a pro version feature)*

To perform vulnerability scans against Windows hosts using SMB authentication, follow these steps:

1. Run the included PowerShell script [prepare-smb-cred-scan.ps1](https://github.com/itiligent/OpenVAS-Appliance-Builder/blob/main/prepare-smb-cred-scan.ps1) to make Windows systems available for scanning with SMB credentials. *(The pro version provides an equivalent .exe for mass deployment)*
2. Create a GVM service account on all Windows hosts to be scanned, adding this account to the local Administrators group on each host (account must NOT be a built-in Windows account).
3. Create a new credentials configuration in the management console reflecting the new Windows service account's details.
4. Add Windows hosts to a new scanning target, then select the new credetials under "Credentials for authenticated checks" to apply these credentials to the scan.
5. Create a new scanning task for the scan target(s) above, then run (or schedule) the new scanning task.