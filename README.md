# Greenbone Vulnerability Manager Appliance

##  GVM (Docker Community Edition) with self signed SSL Nginx reverse proxy and GVM pro version email reporting

## Auto download & setup link
	wget https://raw.githubusercontent.com/itiligent/GVM-Setup/main/setup-gvm.sh && chmod +x setup-gvm.sh && ./setup-gvm.sh

## Prerequisites:

	Recent flavours of Ubuntu / Debian / Raspian 
 	Min 8GB RAM, 80GB HDD
	Private DNS entries matching the server IP address (needed for SSL) 
	Email relay permitted from the appliance's IP address  
		
## Setup script menu prompts...

	Prompt 1: [enter sudo password:]			(Script must NOT be started as sudo) 	
	Prompt 2: [enter new HOSTNAME:]				(Enter to keep existing)
	Prompt 3: [Select GVM version:*] 			(Enter for default currently 22.4) 	
	Prompt 4: [Enter SMTP test email address:] 		(verify correct email relay for reports feature - enter to skip)	
	Prompt 5: [Protect GVM behind Nginx rev proxy?:]	(Default y)	
	Prompt 6: [Enter proxy local DNS name:] 		(Defaults to current hostname)	
	Prompt 7: [Add self signed SSL certs to Nginx?:] 	(Default n) Hostname must be in local DNS for SSL
	Prompt 8: [Enter sudo password to continue:] 		(Docker quirk that install needs to switch user context) 

	If SSL is selected, newly created Windows & Linux browser certs $site.crt, $site.key & $site.pfx are saved to 
	$DOWNLOAD_DIR with the exact custom commands for the import of the client certificates being generated on screen (and is also
	logged for later reference.)

	* For current versions see https://greenbone.github.io/docs/latest/index.html

## Adding email reporting
This setup extends Docker with a default Postfix install that provides a base for email reporting functionality (similar to that with GVM Pro appliances). Run the included $/DOWNLOAD_DIR/add-smtp-relay-o365.sh to complete the SMTP relay with Microsoft365 email integration. This scripted configuration uses SMTP with TLS auth, and requires a Microsoft365 email account with an app password configured for it. (Make sure this is a non admin user!).

## To update GVM containers

	$DOWNLOAD_DIR/update-gvm.sh 
	(Setup creates a weekly GVM update task at a randomly selected day & time. 

## Vulnerability scanning with Windows SMB authentication  

1. Run the included powershell script on all Windows hosts to be scanned with SMB credentials. 
2. Create a GVM service account on all Windows hosts to be scanned, add this account to the local administrators group.  (This service account must NOT be a built-in Windows account)

3. Configure a new credentials object in the GVM management console that reflects the new Windows service account(s). The included powershell script must be run to configure necessary local settings for scanning.


## Docker firewall tricks 
Blocking http access to GVM's console (tcp 9392) and forcing SSL reverse proxy access is not quite straightforward...

### Problem: 

Linux's UFW firewall can’t actually filter Docker container networks because Docker's default behaviour bypasses the Linux firewall.  (Docker's internal networks and IPchains are all processed BEFORE the Linux UFW firewall and this is a default feature!) Many sysadmins make the mistake of relying on the Linux firewall for their Docker systems, leaving containers open to the world. Docker's main answer to this issue is quite unsophisticated and typically requires blocking all interfaces (! 127.0.0.1), or to only publish containers to 127.0.0.1 and reverse proxy these. Complex systems that have a dozen or so containers and a myriad of network interdependencies, just like GVM, are broken with this blunt approach.  

### Solution:

With GVM we need granular control over Docker's IP chains at the port & protocol level, but a quirk with Docker and GVM is that the original source/destination ports we need to manage are further hidden behind Docker's internal dynamic NAT.

The included setup script solves this issue by delicately intercepting only GVM's console port traffic on TCP 9293 between the Docker NAT layer and the system's default route inteface. To do this, conntrack directives are used to unmangle Docker's NAT table to discover the correct dynamic port traffic to block. This approach is very light touch and should not interfere with whatever else is going on under the bonnet with both GVM and Docker.  To make this firewall rule persistent through reboots, the installer script further creates a systemd service that must wait for Docker to start its IP chains before inserting the rule. (Iptable rule persistence with Docker can't reliably be gained through the normal "iptables-save" Linux package approach. This is due to the very dynamic nature of Docker's network stack.)
  
	#!/bin/bash
	# Block HTTP access to the GVM console on default http port 9392
	DEFAULT_ROUTE_IF=$(ip route show to default | grep -Eo "dev\s*[[:alnum:]]+" | sed 's/dev\s//g')
	sudo iptables -I DOCKER-USER -i $DEFAULT_ROUTE_IF -p tcp -m conntrack --ctorigdstport 9392 -j DROP



