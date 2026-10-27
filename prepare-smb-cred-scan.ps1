#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules NetSecurity
###################################################################################
# Windows target setup for Greenbone/OpenVAS credentialed SMB and WMI scans
# David Harrop
# November 2026
#
# Requires an elevated Windows PowerShell session.
# View examples: Get-Help .\prepare-smb-cred-scan.ps1 -Examples
# View all help: Get-Help .\prepare-smb-cred-scan.ps1 -Full
###################################################################################

<#
.SYNOPSIS
Configures this Windows host for Greenbone/OpenVAS credentialed scans.

.DESCRIPTION
Starts the required services and creates inbound firewall rules for SMB,
the RPC endpoint mapper, the WMI service and IPv4 ping.

ScannerAddress accepts one or more scanner IP addresses, CIDR networks,
IP ranges, or a mixture. For multiple entries, use a PowerShell array:
-ScannerAddress "192.0.2.10","192.0.2.11"

Allowing a dedicated scanner network or reserved range lets scanner IPs
change within that scope without updating every Windows host. Every address
in the permitted scope receives the firewall allowance.

Each run replaces this script's named rules. Supply the COMPLETE allowed
source list each time; a later run replaces the previous list.

.PARAMETER ScannerAddress
Required. Allowed scanner source IP addresses, CIDR networks or IP ranges.
Examples: "192.0.2.10", "192.0.2.0/24", or "192.0.2.10-192.0.2.30".
Multiple sources must be separate array entries when invoking the script.

.PARAMETER EnableLocalAccountAdminAccess
Use when the scan authenticates with a LOCAL administrator account.
Sets LocalAccountTokenFilterPolicy to 1 for this Windows host, affecting
remote access by all local administrator accounts, not just the scan account.
Domain accounts with local administrator rights normally do not need this.
When omitted, the current registry setting is preserved.

.PARAMETER FirewallProfile
Windows TARGET network profiles on which the new rules apply.
Defaults to Domain and Private. Select Public explicitly only when required
for the target's intended network connection.

.EXAMPLE
.\prepare-smb-cred-scan.ps1 -ScannerAddress "192.0.2.10"

Allows one scanner IP address.

.EXAMPLE
.\prepare-smb-cred-scan.ps1 -ScannerAddress "192.0.2.10","192.0.2.11"

Allows two scanner IP addresses.

.EXAMPLE
.\prepare-smb-cred-scan.ps1 -ScannerAddress "192.0.2.0/24"

Allows a scanner network. Scanner IP changes inside this network do not
require changes on this Windows host.

.EXAMPLE
.\prepare-smb-cred-scan.ps1 -ScannerAddress "192.0.2.10-192.0.2.30"

Allows a reserved scanner address range.

.EXAMPLE
.\prepare-smb-cred-scan.ps1 -ScannerAddress "192.0.2.0/24","198.51.100.10"

Allows a scanner network plus one scanner on another network. Multiple
CIDR networks can also be supplied in the same way.

.EXAMPLE
.\prepare-smb-cred-scan.ps1 -ScannerAddress "192.0.2.0/24" -EnableLocalAccountAdminAccess

Allows a scanner network and enables remote local-administrator access.

.EXAMPLE
.\prepare-smb-cred-scan.ps1 -ScannerAddress "192.0.2.10" -FirewallProfile Public

Applies the new scanner rules to the target's Public network profile. Firewall rules 
default to Domain and Private profiles.

.NOTES
Replace the documentation addresses in these examples with your own.
Run the script locally on each Windows target as Administrator.

Only RemoteRegistry is set to Automatic. LanmanServer and Winmgmt are
started now while their existing startup types are preserved.

Other existing firewall rules can still permit traffic. Group Policy can
also control which local firewall rules take effect.

The scan account still needs the required ADMIN$, registry and WMI access.
#>

[CmdletBinding()]
param(
    [Parameter(
        Mandatory = $true,
        HelpMessage = 'Enter scanner IP addresses, CIDR networks or IP ranges. See Get-Help .\prepare-smb-cred-scan.ps1 -Examples.'
    )]
    [ValidateNotNullOrEmpty()]
    [string[]]$ScannerAddress,

    [Parameter(HelpMessage = 'Enable remote local-administrator access when using a local scan account.')]
    [switch]$EnableLocalAccountAdminAccess,

    [Parameter(HelpMessage = 'Select target network profiles: Domain, Private or Public. Default: Domain and Private.')]
    [ValidateSet('Domain', 'Private', 'Public')]
    [string[]]$FirewallProfile = @('Domain', 'Private')
)

$ErrorActionPreference = 'Stop'

# Set RemoteRegistry to Automatic; start all three services while preserving the other startup types.
Set-Service -Name RemoteRegistry -StartupType Automatic
Start-Service -Name RemoteRegistry
Start-Service -Name LanmanServer
Start-Service -Name Winmgmt

$Svchost = Join-Path $env:SystemRoot 'System32\svchost.exe'
$FirewallDefaults = @{
    Direction     = 'Inbound'
    Action        = 'Allow'
    Enabled       = 'True'
    Profile       = $FirewallProfile
    RemoteAddress = $ScannerAddress
    Group         = 'OpenVAS credentialed scanning'
}

# WMI uses the RPC endpoint mapper and dynamically assigned service ports.
# The WMI rule is restricted to the Winmgmt service in svchost.exe.
$ScanRules = @(
    @{ Name = 'OpenVAS-SMB-In'; Protocol = 'TCP'; LocalPort = '445' }
    @{ Name = 'OpenVAS-RPC-EndpointMapper-In'; Protocol = 'TCP'; LocalPort = '135'; Program = $Svchost }
    @{ Name = 'OpenVAS-WMI-In'; Protocol = 'TCP'; LocalPort = 'Any'; Program = $Svchost; Service = 'Winmgmt' }
    @{ Name = 'OpenVAS-ICMPv4-In'; Protocol = 'ICMPv4'; IcmpType = '8' }
)

foreach ($ScanRule in $ScanRules) {
    # Replace only this script's own named rule, so repeat runs do not duplicate it.
    Get-NetFirewallRule -Name $ScanRule.Name -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    $ScanRule.DisplayName = $ScanRule.Name
    New-NetFirewallRule @FirewallDefaults @ScanRule | Out-Null
}

if ($EnableLocalAccountAdminAccess) {
    $PolicyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path -Path $PolicyPath)) {
        New-Item -Path $PolicyPath -Force | Out-Null
    }
    New-ItemProperty -Path $PolicyPath -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Warning 'Remote UAC token filtering is disabled for local administrator accounts, not just the scan account.'
}

Write-Host 'Windows scan prerequisites configured.' -ForegroundColor Green
Write-Host ('Scanner source addresses: ' + ($ScannerAddress -join ', '))
Write-Host ('Firewall profiles: ' + ($FirewallProfile -join ', '))
Write-Host 'Validate SMB login, registry access and WMI access in an authenticated OpenVAS scan.'
Write-Host 'Full checks also require the scan account to have the necessary ADMIN$ and WMI permissions.'
