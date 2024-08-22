# Greenbone / OpenVAS Scanner Appliance Build Script

### 📦 Auto Setup Link
**(Do NOT run scripts as root, scripts will prompt for sudo)**
```bash
wget https://raw.githubusercontent.com/itiligent/Easy-OpenVAS-Installer/main/openvas-install.sh && chmod +x openvas-install.sh && ./openvas-install.sh
```

### 📦 Auto Upgrade Link
```bash
wget https://raw.githubusercontent.com/itiligent/Easy-OpenVAS-Installer/main/openvas-upgrade.sh && chmod +x openvas-upgrade.sh  && ./openvas-upgrade.sh 
```

### 📋 Prerequisites

- **Script defaults will build a full appliance with the most current OpenVAS release**
- **Script supports the following OS:**
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
  - Run script with a user account in the sudo group, do not run as root. 🛡️
- **Optional**:
  - Email reports require an O365 email-enabled account & email relay permitted from the scanner IP address
  - A private DNS entry for your appliance (helps avoid browser HTTPS errors - also requires client side certificate import, see below)

### 📖 Customising Your Build
All script customisation options are managed in the top section of this script under the `CUSTOM CONFIG SETTINGS ` section.  Both the install and upgrade scripts will check GitHub for the latest releases for each module, although specific module versions can also forced in the `OVERRIDE LATEST RELEASE AUTO SELECTION `

### 📧 Adding Email Reporting to the Community Edition
*(normally a pro version feature)*

A Postfix MTA is installed by default. Simply configure the included template script `add-email-reports-o365.sh` with your own O365 app password and mail relay configuration.

### ⬆️ Upgrading & Updating the Scanner

- A CVE feed update is scheduled by the installer once daily at a random time, and this can be manually adjusted via cron.
- To upgrade the full appliance, run  `openvas-upgrade.sh` from the link above..

### 🔒 Web Management Console HTTPS Security

The install script will automatically configure a HTTP redirect to HTTPS on port 443 and create the required certificates base on the options in the `CUSTOM CONFIG SETTINGS ` section. . Instructions for importing browser certificates into Windows and Linux clients (to avoid browser HTTPS warnings) are provided on-screen when the build script completes. If you wish you change the system's DNS name or IP address, or if certificates need to be renewed, simply run [update-certificates.sh](https://github.com/itiligent/Easy-OpenVAS-Installer/blob/main/update-certificates.sh)


### 💻 How To Run Authenticated Scans Against Windows Hosts
*(normally a pro version feature)*

To perform vulnerability scans against Windows hosts using SMB authentication, follow these steps:

1. Run the included PowerShell script [prepare-smb-cred-scan.ps1](https://github.com/itiligent/OpenVAS-Appliance-Builder/blob/main/prepare-smb-cred-scan.ps1) to make Windows systems available for scanning with SMB credentials. *(The pro version provides an equivalent .exe for mass deployment)*
2. Create a GVM service account on all Windows hosts and add this account to the local Administrators group on each host (this service account must NOT be a built-in Windows account).
3. Create a new credentials configuration object in the GVM management console reflecting the new Windows service account's details.
4. Add Windows hosts to a new scanning target, then select the new credetials object created above under "Credentials for authenticated checks" to apply these credentials to the scan.
5. Create a new scanning task for the scan target(s) above, then run or schedule it.
