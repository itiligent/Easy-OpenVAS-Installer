# Greenbone OpenVAS Scanner Build & Upgrade Scripts

## November 2026 - Major Build Update

The installation and upgrade scripts have been heavily restructured to support many recent Greenbone/OpenVAS changes, including new native dependencies, Rust/Cargo components, and isolated Python environments.



## 📦 Auto install link
```bash
wget https://raw.githubusercontent.com/itiligent/Easy-OpenVAS-Installer/main/openvas-install.sh && chmod +x openvas-install.sh && ./openvas-install.sh
```
---

## 📦 Auto upgrade link (November 2026 update builds | migrated builds only)
```bash
wget https://raw.githubusercontent.com/itiligent/Easy-OpenVAS-Installer/main/openvas-upgrade.sh && chmod +x openvas-upgrade.sh  && ./openvas-upgrade.sh 
```


> [!CAUTION]
> For existing installations (pre-November 2026 update) installed with earlier build scripts, you must first run [this one-time migration script](https://github.com/itiligent/Easy-OpenVAS-Installer/blob/main/openvas-migrate-legacy-build.sh) with the `--migrate-legacy` argument to update older builds to the new structure. After this you may use the above auto supgrade script for ongoing updates.
---

### 📋 Prerequisites

#### Script defaults will build OpenVAS from latest GithHub release source
- **Supported OS:**
  - **Debian 13 Stable | Ubuntu 24.x LTS** | **Raspbian Bookworm**
- **Required packages**:
  - curl & sudo 
- **Hardware**:
  - Minimum 8GB RAM
  - Minimum 80GB Storage
- **Network**:
  - IPv6 default must be left enabled
  - Avoid multiple NICs
- **Permissions**:
  - Run script as a user with sudoer rights, do not run as root. 🛡️
- **Optional**:
  - Smoother HTTPs console access: Requires a private DNS entry & browser certificate import 
  - Windows credentialed scans: Requires local Windows configuration via the included PowerShell.
  - Email PDF scan reports require either:
    - An O365 email-enabled account with app password auth permitted
    - An Exchange online inbound connector
  
---

## 📖  Controlling The Build Version
Both the install and upgrade scripts will check GitHub for the latest release of each module. Specific package versions can be forced by editing the `FORCE PACKAGE VERSIONS` section at the top of each script. 

- _**If forcing specific packages, you must run the edited script manually and not from the auto-link above.**_

---

## 📖 Dependency management

Greenbone regularly make dependecy changes which can be challenging to track.

To simplify keeping the install and upgrade scripts updated and alinged, they now dynamically download the most current dependencies from this repo file [openvas-dependencies](https://github.com/itiligent/Easy-OpenVAS-Installer/blob/main/openvas-dependencies) at runtime.

To override | update the current repo dependency download:

1. Remove all of the script’s contents between `# BEGIN SHARED DEPENDENCIES` and `# END SHARED DEPENDENCIES` comments.
2. Open the dependency file linked above and paste its contents between the  `# BEGIN SHARED DEPENDENCIES` and `# END SHARED DEPENDENCIES` section. 
3. Edit the pasted dependendies directly in the script as needed before running. 

## ⬆️ Upgrading & Updating OpenVAS

- A CVE feed update is scheduled by the installer once daily at a random time. This can be adjusted via cron.
- To upgrade all OpenVAS packages to the lastest releases run  `openvas-upgrade.sh` from the link above, or edited the script to upgrade to specific versions.

- _**If forcing specific packages, you must run the edited script manually and not from the auto-link above.**_

---

## 🔒 HTTPS Web Console Access 

The install script automatically configures an HTTP redirect to port 443 and creates TLS certificates based on options in the `CUSTOM CONFIG SETTINGS` section. 

Instructions for importing browser certificates into Windows and Linux clients (to avoid browser HTTPS warnings) are provided on-screen when the install script completes. 

If you wish you change the scanner's DNS name, IP address, or to renew certificates, run `update-certificates.sh`

---

## 💻 Authenticated Scans Against Windows Hosts

To scan Windows hosts using SMB authentication:  

1. Use the PowerShell script `prepare-smb-cred-scan.ps1` to set up Windows systems for SMB credential scanning.  
2. Create a GVM service account, add it to the local Administrators group on each host (ensure it is not a built-in Windows account).  
3. In the management console, configure a new credentials object with the above service account details.  
4. Add Windows hosts to a new scan target and assign the credentials object under _**Credentials for authenticated checks.**_  
5. Create and run or schedule a scan task for the target(s).  

---

## 📧 Adding Email Reporting To Community Edition
*(Normally a pro version feature)*

The install script adds the Postfix MTA to enable OpenVAS email reporting capabilities. Configure the included template script `add-email-reports-o365.sh` with your own O365 app password & mail relay configuration.

---
