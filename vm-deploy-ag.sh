#!/bin/env bash

# Check if all required arguments are provided
if [ "$#" -ne 7 ]; then
    echo "Usage: $0 <primary_dns> <static_ip> <gateway> <hostname> <username> <password> <root_password>"
    exit 1
fi

PRIMARY_DNS="$1"
STATIC_IP="$2"
GATEWAY="$3"
HOSTNAME="$4"
USERNAME="$5"
PASSWORD="$6"
ROOT_PASSWORD="$7"

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
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$PRIMARY_DNS, 8.8.8.8, 8.8.4.4, 1.1.1.1]
EOF
    echo "Static IP and gateway configured in Netplan."
}

# Function to apply Netplan configuration
apply_netplan() {
    # set correct netplan conf permissions (600)
    chmod 600 /etc/netplan/*.yaml
    if ! netplan generate; then
        echo "Error: netplan generate failed. Exiting."
        exit 1
    fi
    netplan apply
    echo "Netplan applied successfully."
}

# Function to update hostname
update_hostname() {
    hostnamectl sethostname "$HOSTNAME"
    echo "$HOSTNAME" > /etc/hostname
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
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw --force enable
    echo "UFW configured: All incoming denied except SSH (port 22)."
}
# Function to remove console kernel logging now and on reboot
silence_console() {
    dmesg -n 1
    echo "kernel.printk = 1 4 1 7" >> /etc/sysctl.d/90-no-kernel-log-in-console.conf
    echo "Console kernel logging silenced"
}

# Function to harden SSH configuration
configure_ssh() {
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
AuthenticationMethods publickey,password
PubkeyAuthentication no
PasswordAuthentication yes
PermitRootLogin no
EOF
    systemctl restart sshd
    echo "SSH hardened: Only password authentication allowed. Change this when all keys have been added."
}

# Function to change root password
change_root_password() {
    # Check if the user is root
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: You must be root to change the root password." >&2
        return 1
    fi

    # Change the root password using chpasswd
    echo "root:$ROOT_PASSWORD" | chpasswd
    echo "Root password changed successfully."
}

# Execute all functions in order
set_dns
set_static_ip
apply_netplan
update_hostname
update_and_upgrade
install_packages
create_user
configure_ufw
silence_console
configure_ssh
change_root_password

echo "Script completed successfully. You can now SSH in as $USERNAME and use ssh-copy-id."
