#!/bin/bash
########################################################################################
# Script to make a quick inventory of network hosts
# For Linux
# David Harrop
# August 2022
########################################################################################

clear

echo 
read -p "Enter the network address to scan ie x.x.x.x: " IP_NETWORK
echo
read -p "Enter the subnet CIDR prefix (without forward slash)/" IP_CIDR
echo 
nmap -sn $IP_NETWORK/$IP_CIDR | awk '/Nmap scan/{gsub(/[()]/,"",$NF); print $NF > "hosts.txt"}'
cat hosts.txt > $IP_NETWORK-$IP_CIDR-hosts.txt
rm hosts.txt
nano $IP_NETWORK-$IP_CIDR-hosts.txt

