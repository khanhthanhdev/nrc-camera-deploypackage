#!/bin/bash

# Function to check if the script is run as root (sudo)
check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (sudo)."
        exit 1
    fi
}

# Function to check if the OS is Raspberry Pi OS 64-bit
check_os() {
    if ! grep -q "Raspberry Pi" /etc/rpi-issue; then
        echo "This script is intended for Raspberry Pi OS only."
        exit 1
    fi
    if ! uname -m | grep -q "aarch64"; then
        echo "This script is intended for Raspberry Pi OS 64-bit only."
        exit 1
    fi
}

# Main script execution starts here
check_sudo
check_os

# Update and upgrade packages
echo "Updating and upgrading packages..."
apt update && apt upgrade -y

# Install required packages
echo "Installing necessary packages..."
apt install wget libcamera0.5 libmosquitto1 pulseaudio libavformat59 libswscale6 -y

# Check if nginx is installed and handle accordingly
if command -v nginx &>/dev/null; then
    echo "Nginx is already installed."
    while true; do
        read -p "Do you want to override the existing Nginx configuration? (y/n): " yn
        case $yn in
            [Yy]* ) break;;
            [Nn]* ) echo "Aborting installation."; exit;;
            * ) echo "Please answer yes or no.";;
        esac
    done
else
    apt install nginx -y
fi

# Create /etc/s4v directory and download the tar.gz file
mkdir -p /etc/s4v
wget https://github.com/TzuHuanTai/RaspberryPi-WebRTC/releases/download/v1.0.7/pi-webrtc-v1.0.7_raspios-bookworm-arm64.tar.gz -O /etc/s4v/pi_webrtc.tar.gz

# Extract the tar.gz file and clean up
tar -xzf /etc/s4v/pi_webrtc.tar.gz -C /etc/s4v
rm /etc/s4v/pi_webrtc.tar.gz

# Generate SSL certificate and key
hostname=$(hostname)
openssl req -x509 -newkey rsa:4096 -nodes -keyout /etc/s4v/server.key -out /etc/s4v/server.crt -sha256 -days 36500 -subj "/C=VN/ST=HN/O=S4V/OU=NRC/CN=$hostname.local" -addext "subjectAltName = DNS:$hostname.local"

# Create and enable systemd service
cp s4v-camera.service /etc/systemd/system/
systemctl enable s4v-camera.service
systemctl start s4v-camera.service

# Copy nginx configuration file
cp nginx.conf /etc/nginx/nginx.conf
systemctl restart nginx
