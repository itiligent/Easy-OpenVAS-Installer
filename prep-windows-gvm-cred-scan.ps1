###################################################################################
# Windows client setup script for GVM Community Edition credential scans 
# David Harrop
# August 2022
################################################################################### 

# Requires: 
# Set-ExecutionPolicy Unrestricted -Scope CurrentUser
# Then set it back with:
# Set-ExecutionPolicy RemoteSigned -Scope CurrentUser


# Turn On Remote Registry
Set-Service -Name RemoteRegistry -StartupType Automatic
Set-Service -Name RemoteRegistry -Status Running -PassThru


# Turn on firewall rules for Windows ports
netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes

# Set Registry token 
If (!(Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System")) {
	New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" | Out-Null
}
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "LocalAccountTokenFilterPolicy" -Type DWord -Value 1

