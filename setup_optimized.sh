#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
WEBRTC_RELEASE_URL="https://github.com/TzuHuanTai/RaspberryPi-WebRTC/releases/download/v1.0.7/pi-webrtc-v1.0.7_raspios-bookworm-arm64.tar.gz"
WEBRTC_ARCHIVE_NAME="pi_webrtc.tar.gz"
S4V_DIR="/etc/s4v"
NGINX_CONFIG_FILE="nginx.conf"
SYSTEMD_SERVICE_FILE="s4v-camera.service"

# --- Helper Functions ---
echo_info() {
    echo "[INFO] $1"
}

echo_warn() {
    echo "[WARN] $1"
}

echo_error() {
    echo "[ERROR] $1" >&2
}

# Function to check if the script is run as root (sudo)
check_sudo() {
    if [ "${EUID}" -ne 0 ]; then
        echo_error "Please run as root (sudo)."
        exit 1
    fi
    echo_info "Running with root privileges."
}

# Function to check if the OS is Raspberry Pi OS 64-bit
check_os() {
    if ! grep -q "Raspberry Pi" /etc/rpi-issue 2>/dev/null; then
        echo_error "This script is intended for Raspberry Pi OS only."
        exit 1
    fi
    if ! uname -m | grep -q "aarch64"; then
        echo_error "This script is intended for Raspberry Pi OS 64-bit only."
        exit 1
    fi
    echo_info "Raspberry Pi OS 64-bit detected."
}

# Function to check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Function to install packages if they are not already installed
install_packages() {
    PACKAGES_TO_INSTALL=()
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            PACKAGES_TO_INSTALL+=("$pkg")
        else
            echo_info "Package '$pkg' is already installed."
        fi
    done
    if [ ${#PACKAGES_TO_INSTALL[@]} -ne 0 ]; then
        echo_info "Installing missing packages: ${PACKAGES_TO_INSTALL[*]}..."
        apt install -y "${PACKAGES_TO_INSTALL[@]}"
    else
        echo_info "All required packages are already installed."
    fi
}

# --- Main Script Execution ---
echo_info "Starting S4V Camera Setup Script..."

check_sudo
check_os

# Check for essential commands
essential_commands=("wget" "tar" "openssl" "systemctl" "apt" "grep" "uname" "dpkg" "mkdir" "rm" "cp" "hostname")
for cmd in "${essential_commands[@]}"; do
    if ! command_exists "$cmd"; then
        echo_error "Essential command '$cmd' not found. Please install it and try again."
        exit 1
    fi
done
echo_info "All essential commands are available."

# Update and upgrade packages
echo_info "Updating package lists..."
apt update
echo_info "Upgrading installed packages (this may take a while)..."
apt upgrade -y

# Install required packages
echo_info "Installing/checking necessary packages for S4V Camera..."
CORE_PACKAGES=("wget" "libcamera-apps" "libmosquitto1" "pulseaudio" "libavformat59" "libswscale6" "nginx" "openssl")
# Note: libcamera0.5 might be obsolete or part of libcamera-apps in newer RPi OS versions.
# Using libcamera-apps as it's more standard for camera access.
# If libcamera0.5 is strictly needed and different, it should be verified.
install_packages "${CORE_PACKAGES[@]}"

# Handle Nginx installation and configuration
echo_info "Configuring Nginx..."
NGINX_CONFIG_PATH="/etc/nginx/nginx.conf"
NGINX_CONFIG_BACKUP_PATH="/etc/nginx/nginx.conf.backup.$(date +%F-%T)"

if [ ! -f "${NGINX_CONFIG_FILE}" ]; then
    echo_error "Nginx configuration file '${NGINX_CONFIG_FILE}' not found in the current directory. Make sure it's present."
    exit 1
fi

if [ -f "${NGINX_CONFIG_PATH}" ]; then
    echo_warn "Existing Nginx configuration found at ${NGINX_CONFIG_PATH}."
    read -p "Do you want to override it? A backup will be created. (y/n): " yn_nginx
    case $yn_nginx in
        [Yy]* ) 
            echo_info "Backing up existing Nginx configuration to ${NGINX_CONFIG_BACKUP_PATH}"
            cp "${NGINX_CONFIG_PATH}" "${NGINX_CONFIG_BACKUP_PATH}"
            echo_info "Copying new Nginx configuration..."
            cp "${NGINX_CONFIG_FILE}" "${NGINX_CONFIG_PATH}"
            ;;
        [Nn]* ) 
            echo_info "Skipping Nginx configuration override. Please ensure it's configured मानव रूप से for s4v-camera."
            ;;
        * ) 
            echo_warn "Invalid input. Skipping Nginx configuration override."
            ;;
    esac
else
    echo_info "Copying new Nginx configuration..."
    cp "${NGINX_CONFIG_FILE}" "${NGINX_CONFIG_PATH}"
fi

# Create /etc/s4v directory if it doesn't exist
if [ ! -d "${S4V_DIR}" ]; then
    echo_info "Creating directory ${S4V_DIR}..."
    mkdir -p "${S4V_DIR}"
else
    echo_info "Directory ${S4V_DIR} already exists."
fi

# Download and extract WebRTC package
WEBRTC_TARGET_PATH="${S4V_DIR}/${WEBRTC_ARCHIVE_NAME}"
echo_info "Downloading WebRTC package from ${WEBRTC_RELEASE_URL}..."
wget -O "${WEBRTC_TARGET_PATH}" "${WEBRTC_RELEASE_URL}"

echo_info "Extracting WebRTC package to ${S4V_DIR}..."
tar -xzf "${WEBRTC_TARGET_PATH}" -C "${S4V_DIR}"

echo_info "Cleaning up downloaded WebRTC archive..."
rm "${WEBRTC_TARGET_PATH}"

# Generate SSL certificate and key if they don't exist
SSL_KEY_PATH="${S4V_DIR}/server.key"
SSL_CERT_PATH="${S4V_DIR}/server.crt"

if [ -f "${SSL_KEY_PATH}" ] && [ -f "${SSL_CERT_PATH}" ]; then
    echo_info "SSL certificate and key already exist. Skipping generation."
else
    echo_info "Generating SSL certificate and key (valid for 100 years)..."
    current_hostname=$(hostname)
    openssl req -x509 -newkey rsa:4096 -nodes -keyout "${SSL_KEY_PATH}" -out "${SSL_CERT_PATH}" \
        -sha256 -days 36500 \
        -subj "/C=VN/ST=HN/O=S4V/OU=NRC/CN=${current_hostname}.local" \
        -addext "subjectAltName = DNS:${current_hostname}.local"
    echo_info "SSL certificate and key generated."
fi

# Create and enable systemd service
if [ ! -f "${SYSTEMD_SERVICE_FILE}" ]; then
    echo_error "Systemd service file '${SYSTEMD_SERVICE_FILE}' not found in the current directory. Make sure it's present."
    exit 1
fi

SYSTEMD_SERVICE_PATH="/etc/systemd/system/${SYSTEMD_SERVICE_FILE}"
echo_info "Copying systemd service file to ${SYSTEMD_SERVICE_PATH}..."
cp "${SYSTEMD_SERVICE_FILE}" "${SYSTEMD_SERVICE_PATH}"

echo_info "Reloading systemd daemon..."
systemctl daemon-reload

echo_info "Enabling s4v-camera service to start on boot..."
systemctl enable "${SYSTEMD_SERVICE_FILE}"

echo_info "Starting s4v-camera service..."
systemctl start "${SYSTEMD_SERVICE_FILE}"

# Restart Nginx
echo_info "Restarting Nginx service..."
systemctl restart nginx

# Verify services status
echo_info "Verifying service statuses..."
if systemctl is-active --quiet "${SYSTEMD_SERVICE_FILE}"; then
    echo_info "s4v-camera service is active and running."
else
    echo_warn "s4v-camera service may not be running correctly. Check with 'systemctl status ${SYSTEMD_SERVICE_FILE}' and 'journalctl -u ${SYSTEMD_SERVICE_FILE}'."
fi

if systemctl is-active --quiet nginx; then
    echo_info "Nginx service is active and running."
else
    echo_warn "Nginx service may not be running correctly. Check with 'systemctl status nginx' and 'journalctl -u nginx'."
fi

echo_info "S4V Camera Setup Script finished."
echo_info "You should be able to access the camera at https://$(hostname).local"

exit 0

