#!/bin/env bash

# Check if all required arguments are provided
if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <primary_dns> <static_ip> <gateway> <username> <password>"
    exit 1
fi

PRIMARY_DNS="$1"
STATIC_IP="$2"
GATEWAY="$3"
USERNAME="$4"
PASSWORD="$5"

# Function to set DNS in resolv.conf
set_dns() {
    cat > /etc/resolv.conf <<EOF
nameserver $PRIMARY_DNS
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF
    echo "DNS configured in /etc/resolv.conf."
}

# Function to set static IP and gateway via Netplan
set_static_ip() {
    # Assuming the Netplan file is at /etc/netplan/01-netcfg.yaml
    # Adjust the interface name (e.g., ens3, eth0) as needed
    cat > /etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      addresses: [$STATIC_IP/24]
      gateway4: $GATEWAY
      nameservers:
        addresses: [$PRIMARY_DNS, 8.8.8.8, 8.8.4.4, 1.1.1.1]
EOF
    echo "Static IP and gateway configured in Netplan."
}

# Function to apply Netplan configuration
apply_netplan() {
    if ! netplan generate; then
        echo "Error: netplan generate failed. Exiting."
        exit 1
    fi
    netplan apply
    echo "Netplan applied successfully."
}

# Function to update and upgrade packages
update_and_upgrade() {
    apt update && apt upgrade -y
    echo "System updated and upgraded."
}

# Function to install required packages
install_packages() {
    apt install -y ssh vim git ufw net-tools nmap sudo locales kbd console-setup netplan.io
    echo "Required packages installed."
}

# Function to create a new user and add to sudoers
create_user() {
    adduser --disabled-password --gecos "" "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd
    usermod -aG sudo "$USERNAME"
    echo "User $USERNAME created and added to sudoers."
}

# Function to configure UFW
configure_ufw() {
    ufw default deny incoming
    ufw default deny outgoing
    ufw allow 22/tcp
    ufw --force enable
    echo "UFW configured: All incoming/outgoing denied except SSH (port 22)."
}

# Function to harden SSH configuration
configure_ssh() {
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
AuthenticationMethods publickey,password
PubkeyAuthentication yes
PasswordAuthentication yes
PermitRootLogin no
EOF
    systemctl restart sshd
    echo "SSH hardened: Only publickey and password authentication allowed."
}

# Execute all functions in order
set_dns
set_static_ip
apply_netplan
update_and_upgrade
install_packages
create_user
configure_ufw
configure_ssh

echo "Script completed successfully. You can now SSH in as $USERNAME and use ssh-copy-id."
