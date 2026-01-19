# Greenbone OpenVAS Scanner Build & Upgrade Scripts

#### Note: Script dependencies last updated Januray 2026. From time to time these need updating. Please post an issue for dependency error(s).  

### 📦 Auto install link
(Do NOT run script as root, it will prompt for sudo)
```bash
wget https://raw.githubusercontent.com/itiligent/Easy-OpenVAS-Installer/main/openvas-install.sh && chmod +x openvas-install.sh && ./openvas-install.sh
```

### 📦 Auto upgrade link
```bash
wget https://raw.githubusercontent.com/itiligent/Easy-OpenVAS-Installer/main/openvas-upgrade.sh && chmod +x openvas-upgrade.sh  && ./openvas-upgrade.sh 
```

##### 💻 Note: On low power systems cached sudo credentials may timeout and re-prompt

---

### 📋 Prerequisites

#### Script defaults will build OpenVAS from latest GithHub release source
- **Supported OS:**
  - **Debian 12 & 13 Stable | Ubuntu 24.x LTS** | Raspbian Bookworm
- **Required packages**:
  - curl & sudo 
- **Hardware**:
  - Minimum 8GB RAM
  - Minimum 80GB Storage
- **Network**:
  - IPv6 must be enabled
  - Avoid multiple NICs
- **Permissions**:
  - Run script as a user with sudo rights, do not run as root. 🛡️
- **Optional**:
  - A private DNS entry for HTTPs console access
  - Email PDF scan reports.
    - Requires an O365 email-enabled account & email relay permitted from the scanner'S IP address
  
---

### 📖  Controlling The Build Version
Both the install and upgrade scripts will check GitHub for the latest release of each module. Specific package versions can be forced by editing the `FORCE PACKAGE VERSIONS` section at the top of each script. 

- _**If forcing specific packages, you must run the edited script manually and not from the auto-link above.**_

---

### 📧 Adding Email Reporting To Community Edition
*(Normally a pro version feature)*

The install script adds the Postfix MTA to enable OpenVAS email reporting capabilities. Configure the included template script `add-email-reports-o365.sh` with your own O365 app password & mail relay configuration.

---

### ⬆️ Upgrading & Updating OpenVAS

- A CVE feed update is scheduled by the installer once daily at a random time. This can be adjusted via cron.
- To upgrade all OpenVAS packages to the lastest releases run  `openvas-upgrade.sh` from the link above, or edited the script to upgrade to specific versions.

- _**If forcing specific packages, you must run the edited script manually and not from the auto-link above.**_


---

### 🔒 HTTPS Web Console Access 

The install script automatically configures an HTTP redirect to port 443 and creates TLS certificates based on options in the `CUSTOM CONFIG SETTINGS` section. 

Instructions for importing browser certificates into Windows and Linux clients (to avoid browser HTTPS warnings) are provided on-screen when the install script completes. 

If you wish you change the scanner's DNS name, IP address, or to renew certificates, run `update-certificates.sh`

---

### 💻 Authenticated Scans Against Windows Hosts

To scan Windows hosts using SMB authentication:  

1. Use the PowerShell script `prepare-smb-cred-scan.ps1` to set up Windows systems for SMB credential scanning.  
2. Create a GVM service account, add it to the local Administrators group on each host (ensure it is not a built-in Windows account).  
3. In the management console, configure a new credentials object with the above service account details.  
4. Add Windows hosts to a new scan target and assign the credentials object under _**Credentials for authenticated checks.**_  
5. Create and run or schedule a scan task for the target(s).  

