#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
WEBRTC_RELEASE_URL="https://github.com/b4iterdev/nrc-webrtc-player/releases/latest/download/release.zip"
WEBRTC_ARCHIVE_NAME="release.zip"
S4V_DIR="/etc/s4v"
NGINX_CONFIG_FILENAME="nginx.conf"
SYSTEMD_SERVICE_FILENAME="s4v-camera.service"
CLONED_REPO_DIR="nrc-camera-deploypackage" # Subdirectory where config files might be after cloning
NGINX_HTML_DIR="/usr/share/nginx/html"
CONFIG_TXT_PATH="/boot/firmware/config.txt"
CMDLINE_TXT_PATH="/boot/firmware/cmdline.txt"

# --- Helper Functions ---
RED=\'\033[0;31m\'
GREEN=\'\033[0;32m\'
YELLOW=\'\033[1;33m\'
BLUE=\'\033[0;34m\'
NC=\'\033[0m\' # No Color

echo_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

echo_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

echo_error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

echo_step() {
    echo -e "${BLUE}[STEP] $1${NC}"
}

# Function to ask for user confirmation
confirm_action() {
    while true; do
        read -p "${YELLOW}$1 (y/n): ${NC}" yn
        case $yn in
            [Yy]* ) return 0;; # Yes
            [Nn]* ) return 1;; # No
            * ) echo -e "${RED}Please answer yes (y) or no (n).${NC}";;
        esac
    done
}

# Function to check if the script is run as root (sudo)
check_sudo() {
    echo_info "Checking for root privileges..."
    if [ "${EUID}" -ne 0 ]; then
        echo_error "This script needs to be run with root privileges. Please use 'sudo ./setup_optimized_v4.sh'."
        exit 1
    fi
    echo_info "Root privileges confirmed."
}

# Function to check if the OS is Raspberry Pi OS 64-bit
check_os() {
    echo_info "Checking operating system compatibility..."
    if ! grep -q "Raspberry Pi" /etc/rpi-issue 2>/dev/null; then
        echo_error "This script is intended for Raspberry Pi OS only."
        exit 1
    fi
    if ! uname -m | grep -q "aarch64"; then
        echo_error "This script is intended for Raspberry Pi OS 64-bit only."
        exit 1
    fi
    echo_info "Raspberry Pi OS 64-bit detected. Compatibility OK."
}

# Function to check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Function to find a configuration file
# Searches in the current directory first, then in the specified subdirectory
find_config_file() {
    local filename="$1"
    local subdir="$2"
    
    if [ -f "./${filename}" ]; then
        echo "./${filename}"
    elif [ -d "./${subdir}" ] && [ -f "./${subdir}/${filename}" ]; then
        echo "./${subdir}/${filename}"
    else
        echo ""
    fi
}

# Function to install packages if they are not already installed
install_packages() {
    PACKAGES_TO_INSTALL=()
    echo_info "Checking for required system packages..."
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            PACKAGES_TO_INSTALL+=("$pkg")
        else
            echo_info "Package '$pkg' is already installed."
        fi
    done
    if [ ${#PACKAGES_TO_INSTALL[@]} -ne 0 ]; then
        echo_info "The following packages will be installed: ${PACKAGES_TO_INSTALL[*]}"
        if confirm_action "Do you want to proceed with the installation?"; then
            apt install -y "${PACKAGES_TO_INSTALL[@]}"
            echo_info "Packages installed successfully."
        else
            echo_error "User aborted package installation. Exiting."
            exit 1
        fi
    else
        echo_info "All required system packages are already installed."
    fi
}

# Function to configure USB Serial Gadget
configure_usb_serial_gadget() {
    echo_step "Configuring USB Serial Gadget..."
    
    # Configure config.txt
    echo_info "Checking and updating ${CONFIG_TXT_PATH}..."
    if grep -q "^dtoverlay=dwc2" "${CONFIG_TXT_PATH}"; then
        echo_info "USB Serial Gadget (dtoverlay=dwc2) already configured in ${CONFIG_TXT_PATH}."
    else
        echo_info "Adding dtoverlay=dwc2 to ${CONFIG_TXT_PATH}..."
        if confirm_action "Do you want to add USB Serial Gadget configuration to ${CONFIG_TXT_PATH}?"; then
            # Create backup
            cp "${CONFIG_TXT_PATH}" "${CONFIG_TXT_PATH}.backup.$(date +%F-%H%M%S)"
            
            # Check if [all] section exists
            if grep -q "^\[all\]" "${CONFIG_TXT_PATH}"; then
                # Add after [all] section
                sed -i '/^\[all\]/a dtoverlay=dwc2,dr_mode=peripheral' "${CONFIG_TXT_PATH}"
            else
                # Add to end of file
                echo -e "\n[all]\ndtoverlay=dwc2,dr_mode=peripheral" >> "${CONFIG_TXT_PATH}"
            fi
            echo_info "USB Serial Gadget configuration added to ${CONFIG_TXT_PATH}."
        else
            echo_warn "Skipping USB Serial Gadget configuration in ${CONFIG_TXT_PATH}."
        fi
    fi
    
    # Configure cmdline.txt
    echo_info "Checking and updating ${CMDLINE_TXT_PATH}..."
    if grep -q "modules-load=dwc2,g_serial" "${CMDLINE_TXT_PATH}"; then
        echo_info "USB Serial Gadget modules already configured in ${CMDLINE_TXT_PATH}."
    else
        echo_info "Adding modules-load=dwc2,g_serial to ${CMDLINE_TXT_PATH}..."
        if confirm_action "Do you want to add USB Serial Gadget modules to ${CMDLINE_TXT_PATH}?"; then
            # Create backup
            cp "${CMDLINE_TXT_PATH}" "${CMDLINE_TXT_PATH}.backup.$(date +%F-%H%M%S)"
            
            # Add after rootwait
            sed -i 's/rootwait/rootwait modules-load=dwc2,g_serial/' "${CMDLINE_TXT_PATH}"
            echo_info "USB Serial Gadget modules added to ${CMDLINE_TXT_PATH}."
        else
            echo_warn "Skipping USB Serial Gadget modules configuration in ${CMDLINE_TXT_PATH}."
        fi
    fi
    
    # Enable getty service
    echo_info "Enabling getty service for USB Serial Gadget..."
    systemctl enable getty@ttyGS0.service
    echo_info "Getty service enabled for USB Serial Gadget."
    
    echo_info "USB Serial Gadget configuration completed."
}

# --- Main Script Execution ---
echo_info "=================================================="
echo_info " S4V Camera Setup Script - v4 (Auto-detect Config)"
echo_info "=================================================="
echo_info "This script will guide you through the installation of the S4V Camera software."

check_sudo
check_os

# Check for essential commands
echo_step "Checking for essential system commands..."
essential_commands=("wget" "unzip" "openssl" "systemctl" "apt" "grep" "uname" "dpkg" "mkdir" "rm" "cp" "hostname" "sed")
missing_commands=0
for cmd in "${essential_commands[@]}"; do
    if ! command_exists "$cmd"; then
        echo_error "Essential command '$cmd' not found. This script cannot continue without it."
        missing_commands=$((missing_commands + 1))
    fi
done
if [ "$missing_commands" -ne 0 ]; then
    echo_error "Please install the missing commands and try again. For 'unzip', you can use 'sudo apt install unzip'."
    exit 1
fi
echo_info "All essential commands are available."

# Update and upgrade packages
echo_step "Updating system packages..."
echo_info "Updating package lists from repositories..."
apt update
echo_info "Upgrading installed packages. This may take a while..."
if confirm_action "Do you want to upgrade all system packages now? (Recommended)"; then
    apt upgrade -y
    echo_info "System packages upgraded."
else
    echo_warn "Skipping system package upgrade. This might lead to compatibility issues."
fi

# Install required packages
echo_step "Installing required packages..."
CORE_PACKAGES=("wget" "unzip" "libcamera-apps" "libmosquitto1" "pulseaudio" "libavformat59" "libswscale6" "nginx" "openssl")
install_packages "${CORE_PACKAGES[@]}"

# Find configuration files
echo_step "Locating configuration files..."
FOUND_NGINX_CONFIG_FILE=$(find_config_file "${NGINX_CONFIG_FILENAME}" "${CLONED_REPO_DIR}")
FOUND_SYSTEMD_SERVICE_FILE=$(find_config_file "${SYSTEMD_SERVICE_FILENAME}" "${CLONED_REPO_DIR}")

if [ -z "${FOUND_NGINX_CONFIG_FILE}" ]; then
    echo_error "Nginx configuration file ('${NGINX_CONFIG_FILENAME}') not found in the current directory or subdirectory '${CLONED_REPO_DIR}'."
    echo_error "Please make sure the file exists and the script is run from the correct location."
    exit 1
else
    echo_info "Found Nginx configuration file at: ${FOUND_NGINX_CONFIG_FILE}"
fi

if [ -z "${FOUND_SYSTEMD_SERVICE_FILE}" ]; then
    echo_error "Systemd service file ('${SYSTEMD_SERVICE_FILENAME}') not found in the current directory or subdirectory '${CLONED_REPO_DIR}'."
    echo_error "Please make sure the file exists and the script is run from the correct location."
    exit 1
else
    echo_info "Found Systemd service file at: ${FOUND_SYSTEMD_SERVICE_FILE}"
fi

# Handle Nginx installation and configuration
echo_step "Configuring Nginx Web Server..."
NGINX_CONFIG_PATH="/etc/nginx/nginx.conf"
NGINX_CONFIG_BACKUP_PATH="/etc/nginx/nginx.conf.backup.$(date +%F-%H%M%S)"

if [ -f "${NGINX_CONFIG_PATH}" ]; then
    echo_warn "An existing Nginx configuration file was found at '${NGINX_CONFIG_PATH}'."
    if confirm_action "Do you want to replace it with '${FOUND_NGINX_CONFIG_FILE}'? A backup of the current file will be created."; then
        echo_info "Backing up existing Nginx configuration to '${NGINX_CONFIG_BACKUP_PATH}'..."
        cp "${NGINX_CONFIG_PATH}" "${NGINX_CONFIG_BACKUP_PATH}"
        echo_info "Copying new Nginx configuration from '${FOUND_NGINX_CONFIG_FILE}' to '${NGINX_CONFIG_PATH}'..."
        cp "${FOUND_NGINX_CONFIG_FILE}" "${NGINX_CONFIG_PATH}"
        echo_info "Nginx configuration updated."
    else
        echo_warn "Skipping Nginx configuration override. Please ensure Nginx is manually configured for the S4V Camera."
    fi
else
    echo_info "No existing Nginx configuration found. Copying '${FOUND_NGINX_CONFIG_FILE}' to '${NGINX_CONFIG_PATH}'..."
    cp "${FOUND_NGINX_CONFIG_FILE}" "${NGINX_CONFIG_PATH}"
    echo_info "Nginx configuration file copied."
fi

# Create /etc/s4v directory if it doesn't exist
echo_step "Preparing S4V Camera directory..."
if [ ! -d "${S4V_DIR}" ]; then
    echo_info "Creating S4V application directory at '${S4V_DIR}'..."
    mkdir -p "${S4V_DIR}"
else
    echo_info "S4V application directory '${S4V_DIR}' already exists."
fi

# Download and extract WebRTC package from latest release
echo_step "Downloading and installing latest WebRTC package..."
echo_info "Downloading latest S4V WebRTC package from ${WEBRTC_RELEASE_URL}..."
wget -O "${WEBRTC_ARCHIVE_NAME}" "${WEBRTC_RELEASE_URL}"
echo_info "Download complete."

echo_info "Extracting WebRTC package..."
# Create a temporary directory for extraction
mkdir -p release_temp
unzip -o "${WEBRTC_ARCHIVE_NAME}" -d release_temp
echo_info "Extraction complete."

# Copy browser files to Nginx html directory
echo_info "Copying web files to Nginx directory..."
if [ -d "release_temp/browser" ]; then
    if [ -d "${NGINX_HTML_DIR}" ]; then
        echo_info "Copying browser files to ${NGINX_HTML_DIR}..."
        cp -r release_temp/browser/* "${NGINX_HTML_DIR}/"
        echo_info "Browser files copied successfully."
    else
        echo_error "Nginx HTML directory '${NGINX_HTML_DIR}' not found. Creating it..."
        mkdir -p "${NGINX_HTML_DIR}"
        cp -r release_temp/browser/* "${NGINX_HTML_DIR}/"
        echo_info "Browser files copied successfully to newly created directory."
    fi
else
    echo_error "Browser directory not found in the extracted package. Skipping web files installation."
fi

# Copy other necessary files to S4V directory
echo_info "Copying necessary files to S4V directory..."
if [ -d "release_temp" ]; then
    # Avoid copying the browser directory again if it exists
    find release_temp -mindepth 1 -maxdepth 1 ! -name 'browser' -exec cp -r {} "${S4V_DIR}/" \;
    echo_info "Files copied to S4V directory."
else
    echo_error "Extracted directory not found. Skipping S4V directory update."
fi

# Clean up
echo_info "Cleaning up temporary files..."
rm -f "${WEBRTC_ARCHIVE_NAME}"
rm -rf release_temp
echo_info "Temporary files cleaned up."

# Generate SSL certificate and key if they don't exist
SSL_KEY_PATH="${S4V_DIR}/server.key"
SSL_CERT_PATH="${S4V_DIR}/server.crt"
echo_step "Setting up SSL certificate..."

if [ -f "${SSL_KEY_PATH}" ] && [ -f "${SSL_CERT_PATH}" ]; then
    echo_info "SSL certificate and key already exist at '${S4V_DIR}'. Skipping generation."
else
    echo_info "Generating new SSL certificate and key (self-signed, valid for 100 years)..."
    current_hostname=$(hostname)
    openssl req -x509 -newkey rsa:4096 -nodes -keyout "${SSL_KEY_PATH}" -out "${SSL_CERT_PATH}" \
        -sha256 -days 36500 \
        -subj "/C=VN/ST=HN/O=S4V/OU=NRC/CN=${current_hostname}.local" \
        -addext "subjectAltName = DNS:${current_hostname}.local,IP:127.0.0.1"
    echo_info "SSL certificate and key generated successfully in '${S4V_DIR}'."
fi

# Create and enable systemd service
SYSTEMD_SERVICE_PATH="/etc/systemd/system/${SYSTEMD_SERVICE_FILENAME}"
echo_step "Setting up S4V Camera system service..."

if [ -f "${SYSTEMD_SERVICE_PATH}" ]; then
    echo_warn "An existing systemd service file was found at '${SYSTEMD_SERVICE_PATH}'."
    if confirm_action "Do you want to replace it with '${FOUND_SYSTEMD_SERVICE_FILE}'? A backup will be created."; then
        echo_info "Backing up existing systemd service file..."
        cp "${SYSTEMD_SERVICE_PATH}" "${SYSTEMD_SERVICE_PATH}.backup.$(date +%F-%H%M%S)"
        echo_info "Copying new systemd service file from '${FOUND_SYSTEMD_SERVICE_FILE}' to '${SYSTEMD_SERVICE_PATH}'..."
        cp "${FOUND_SYSTEMD_SERVICE_FILE}" "${SYSTEMD_SERVICE_PATH}"
        echo_info "Systemd service file updated."
    else
        echo_warn "Skipping systemd service file override. The existing service file will be used."
    fi
else
    echo_info "Copying new systemd service file from '${FOUND_SYSTEMD_SERVICE_FILE}' to '${SYSTEMD_SERVICE_PATH}'..."
    cp "${FOUND_SYSTEMD_SERVICE_FILE}" "${SYSTEMD_SERVICE_PATH}"
    echo_info "Systemd service file copied."
fi

echo_info "Reloading systemd daemon to recognize new/changed service file..."
systemctl daemon-reload

echo_info "Enabling s4v-camera service to start automatically on boot..."
systemctl enable "${SYSTEMD_SERVICE_FILENAME}"

echo_info "Starting s4v-camera service..."
systemctl start "${SYSTEMD_SERVICE_FILENAME}"

# Configure USB Serial Gadget
if confirm_action "Do you want to configure USB Serial Gadget for direct connection via USB?"; then
    configure_usb_serial_gadget
else
    echo_warn "Skipping USB Serial Gadget configuration."
fi

# Restart Nginx
echo_step "Restarting Nginx service to apply changes..."
systemctl restart nginx

# Verify services status
echo_step "Verifying service statuses..."
CAMERA_SERVICE_ACTIVE=false
NGINX_SERVICE_ACTIVE=false

if systemctl is-active --quiet "${SYSTEMD_SERVICE_FILENAME}"; then
    echo_info "S4V Camera service (${SYSTEMD_SERVICE_FILENAME}) is active and running."
    CAMERA_SERVICE_ACTIVE=true
else
    echo_warn "S4V Camera service (${SYSTEMD_SERVICE_FILENAME}) may not be running correctly."
    echo_warn "Check with: sudo systemctl status ${SYSTEMD_SERVICE_FILENAME}  OR  sudo journalctl -u ${SYSTEMD_SERVICE_FILENAME}"
fi

if systemctl is-active --quiet nginx; then
    echo_info "Nginx service is active and running."
    NGINX_SERVICE_ACTIVE=true
else
    echo_warn "Nginx service may not be running correctly."
    echo_warn "Check with: sudo systemctl status nginx  OR  sudo journalctl -u nginx"
fi

echo_info "--------------------------------------------------"
if [ "${CAMERA_SERVICE_ACTIVE}" = true ] && [ "${NGINX_SERVICE_ACTIVE}" = true ]; then
    echo_info "S4V Camera Setup Script finished successfully!"
    echo_info "You should now be able to access the camera stream at:"
    echo_info "  https://$(hostname).local"
    echo_warn "Note: You will likely see a browser warning due to the self-signed SSL certificate. This is expected."
    
    if grep -q "dtoverlay=dwc2" "${CONFIG_TXT_PATH}" && grep -q "modules-load=dwc2,g_serial" "${CMDLINE_TXT_PATH}"; then
        echo_info "USB Serial Gadget has been configured. After reboot, you can connect directly via USB."
        echo_info "To apply USB Serial Gadget changes, a reboot is required."
        if confirm_action "Do you want to reboot now?"; then
            echo_info "Rebooting system..."
            reboot
        else
            echo_warn "Please reboot manually later to apply USB Serial Gadget changes."
        fi
    fi
else
    echo_error "S4V Camera Setup Script finished, but one or more services are not running correctly."
    echo_error "Please review the messages above and check the service logs for details."
fi
echo_info "=================================================="

exit 0

