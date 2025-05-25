#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# Source 1: UI/Server components
B4ITERDEV_RELEASE_URL="https://github.com/b4iterdev/nrc-webrtc-player/releases/latest/download/release.zip"
B4ITERDEV_ARCHIVE_NAME="release.zip"

# Source 2: pi_webrtc executable
TZUHUANTAI_RELEASE_URL="https://github.com/TzuHuanTai/RaspberryPi-WebRTC/releases/download/v1.0.7/pi-webrtc-v1.0.7_raspios-bookworm-arm64.tar.gz"
TZUHUANTAI_ARCHIVE_NAME="pi-webrtc.tar.gz"
# Note: The executable in the archive is named 'pi-webrtc', but we will rename it to 'pi_webrtc' for consistency
# with the likely service file configuration.
EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE="pi-webrtc"
FINAL_EXECUTABLE_NAME="pi_webrtc"

# Common paths and filenames
S4V_DIR="/etc/s4v"
NGINX_CONFIG_FILENAME="nginx.conf"
SYSTEMD_SERVICE_FILENAME="s4v-camera.service"
CLONED_REPO_DIR="nrc-camera-deploypackage" # Subdirectory where config files might be after cloning
NGINX_HTML_DIR="/usr/share/nginx/html"
CONFIG_TXT_PATH="/boot/firmware/config.txt"
CMDLINE_TXT_PATH="/boot/firmware/cmdline.txt"

# Temporary directories
B4ITERDEV_TEMP_DIR="release_temp_b4iterdev"
TZUHUANTAI_TEMP_DIR="release_temp_tzuhuantai"

# --- Helper Functions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

check_sudo() {
    echo_info "Checking for root privileges..."
    if [ "${EUID}" -ne 0 ]; then
        echo_error "This script needs to be run with root privileges. Please use \'sudo ./setup_optimized_v6.sh\'."
        exit 1
    fi
    echo_info "Root privileges confirmed."
}

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

command_exists() {
    command -v "$1" &>/dev/null
}

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

install_packages() {
    PACKAGES_TO_INSTALL=()
    echo_info "Checking for required system packages..."
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            PACKAGES_TO_INSTALL+=("$pkg")
        else
            echo_info "Package \t'$pkg\t' is already installed."
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

configure_usb_serial_gadget() {
    echo_step "Configuring USB Serial Gadget..."
    
    # Configure config.txt
    echo_info "Checking and updating ${CONFIG_TXT_PATH}..."
    if grep -q "^dtoverlay=dwc2" "${CONFIG_TXT_PATH}"; then
        echo_info "USB Serial Gadget (dtoverlay=dwc2) already configured in ${CONFIG_TXT_PATH}."
    else
        echo_info "Adding dtoverlay=dwc2 to ${CONFIG_TXT_PATH}..."
        if confirm_action "Do you want to add USB Serial Gadget configuration to ${CONFIG_TXT_PATH}?"; then
            cp "${CONFIG_TXT_PATH}" "${CONFIG_TXT_PATH}.backup.$(date +%F-%H%M%S)"
            if grep -q "^\[all\]" "${CONFIG_TXT_PATH}"; then
                sed -i \'/^\[all\]/a dtoverlay=dwc2,dr_mode=peripheral\' "${CONFIG_TXT_PATH}"
            else
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
            cp "${CMDLINE_TXT_PATH}" "${CMDLINE_TXT_PATH}.backup.$(date +%F-%H%M%S)"
            sed -i \'s/rootwait/rootwait modules-load=dwc2,g_serial/\' "${CMDLINE_TXT_PATH}"
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
echo_info " S4V Camera Setup Script - v6 (Fix Naming)"
echo_info "=================================================="
echo_info "This script will install components from b4iterdev (UI/Server) and TzuHuanTai (pi-webrtc executable, renamed to pi_webrtc)."

check_sudo
check_os

# Check for essential commands
echo_step "Checking for essential system commands..."
essential_commands=("wget" "unzip" "tar" "openssl" "systemctl" "apt" "grep" "uname" "dpkg" "mkdir" "rm" "cp" "mv" "hostname" "sed") # Added mv
missing_commands=0
for cmd in "${essential_commands[@]}"; do
    if ! command_exists "$cmd"; then
        echo_error "Essential command \t'$cmd\' not found. This script cannot continue without it."
        missing_commands=$((missing_commands + 1))
    fi
done
if [ "$missing_commands" -ne 0 ]; then
    echo_error "Please install the missing commands and try again. For \'unzip\', \'tar\', \'mv\', use \'sudo apt install unzip tar coreutils\'."
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
CORE_PACKAGES=("wget" "unzip" "tar" "libcamera-apps" "libmosquitto1" "pulseaudio" "libavformat59" "libswscale6" "nginx" "openssl")
install_packages "${CORE_PACKAGES[@]}"

# Find configuration files
echo_step "Locating configuration files..."
FOUND_NGINX_CONFIG_FILE=$(find_config_file "${NGINX_CONFIG_FILENAME}" "${CLONED_REPO_DIR}")
FOUND_SYSTEMD_SERVICE_FILE=$(find_config_file "${SYSTEMD_SERVICE_FILENAME}" "${CLONED_REPO_DIR}")

if [ -z "${FOUND_NGINX_CONFIG_FILE}" ]; then
    echo_error "Nginx configuration file (\t'${NGINX_CONFIG_FILENAME}\t') not found in the current directory or subdirectory \t'${CLONED_REPO_DIR}\t'."
    echo_error "Please make sure the file exists and the script is run from the correct location."
    exit 1
else
    echo_info "Found Nginx configuration file at: ${FOUND_NGINX_CONFIG_FILE}"
fi

if [ -z "${FOUND_SYSTEMD_SERVICE_FILE}" ]; then
    echo_error "Systemd service file (\t'${SYSTEMD_SERVICE_FILENAME}\t') not found in the current directory or subdirectory \t'${CLONED_REPO_DIR}\t'."
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
    echo_warn "An existing Nginx configuration file was found at \t'${NGINX_CONFIG_PATH}\t'."
    if confirm_action "Do you want to replace it with \t'${FOUND_NGINX_CONFIG_FILE}\t'? A backup of the current file will be created."; then
        echo_info "Backing up existing Nginx configuration to \t'${NGINX_CONFIG_BACKUP_PATH}\t'..."
        cp "${NGINX_CONFIG_PATH}" "${NGINX_CONFIG_BACKUP_PATH}"
        echo_info "Copying new Nginx configuration from \t'${FOUND_NGINX_CONFIG_FILE}\t' to \t'${NGINX_CONFIG_PATH}\t'..."
        cp "${FOUND_NGINX_CONFIG_FILE}" "${NGINX_CONFIG_PATH}"
        echo_info "Nginx configuration updated."
    else
        echo_warn "Skipping Nginx configuration override. Please ensure Nginx is manually configured for the S4V Camera."
    fi
else
    echo_info "No existing Nginx configuration found. Copying \t'${FOUND_NGINX_CONFIG_FILE}\t' to \t'${NGINX_CONFIG_PATH}\t'..."
    cp "${FOUND_NGINX_CONFIG_FILE}" "${NGINX_CONFIG_PATH}"
    echo_info "Nginx configuration file copied."
fi

# Create /etc/s4v directory if it doesn't exist
echo_step "Preparing S4V Camera directory..."
if [ ! -d "${S4V_DIR}" ]; then
    echo_info "Creating S4V application directory at \t'${S4V_DIR}\t'..."
    mkdir -p "${S4V_DIR}"
else
    echo_info "S4V application directory \t'${S4V_DIR}\t' already exists."
fi

# Download and install UI/Server components (b4iterdev)
echo_step "Downloading and installing UI/Server components (b4iterdev)..."
echo_info "Downloading latest UI/Server package from ${B4ITERDEV_RELEASE_URL}..."
wget -O "${B4ITERDEV_ARCHIVE_NAME}" "${B4ITERDEV_RELEASE_URL}"
echo_info "Download complete."

echo_info "Extracting UI/Server package..."
mkdir -p "${B4ITERDEV_TEMP_DIR}"
unzip -o "${B4ITERDEV_ARCHIVE_NAME}" -d "${B4ITERDEV_TEMP_DIR}"
echo_info "Extraction complete."

# Copy browser files to Nginx html directory
echo_info "Copying web files to Nginx directory..."
if [ -d "${B4ITERDEV_TEMP_DIR}/browser" ]; then
    if [ -d "${NGINX_HTML_DIR}" ]; then
        echo_info "Copying browser files to ${NGINX_HTML_DIR}..."
        cp -r "${B4ITERDEV_TEMP_DIR}/browser/"* "${NGINX_HTML_DIR}/"
        echo_info "Browser files copied successfully."
    else
        echo_error "Nginx HTML directory \t'${NGINX_HTML_DIR}\t' not found. Creating it..."
        mkdir -p "${NGINX_HTML_DIR}"
        cp -r "${B4ITERDEV_TEMP_DIR}/browser/"* "${NGINX_HTML_DIR}/"
        echo_info "Browser files copied successfully to newly created directory."
    fi
else
    echo_warn "Browser directory not found in the b4iterdev package. Skipping web files installation."
fi

# Copy other necessary files from b4iterdev to S4V directory
echo_info "Copying other necessary files from b4iterdev package to S4V directory..."
if [ -d "${B4ITERDEV_TEMP_DIR}" ]; then
    # Copy everything except the browser directory
    find "${B4ITERDEV_TEMP_DIR}" -mindepth 1 -maxdepth 1 ! -name 'browser' -exec cp -r {} "${S4V_DIR}/" \;
    echo_info "Files copied to S4V directory."
else
    echo_error "Extracted b4iterdev directory not found. Skipping S4V directory update for this package."
fi

# Download and install pi_webrtc executable (TzuHuanTai)
echo_step "Downloading and installing pi_webrtc executable (TzuHuanTai)..."
echo_info "Downloading pi_webrtc package from ${TZUHUANTAI_RELEASE_URL}..."
wget -O "${TZUHUANTAI_ARCHIVE_NAME}" "${TZUHUANTAI_RELEASE_URL}"
echo_info "Download complete."

echo_info "Extracting pi_webrtc package..."
mkdir -p "${TZUHUANTAI_TEMP_DIR}"
tar -xzf "${TZUHUANTAI_ARCHIVE_NAME}" -C "${TZUHUANTAI_TEMP_DIR}" # Don't strip components, keep original name
echo_info "Extraction complete."

# Find, rename (if needed), and copy pi_webrtc executable
FOUND_EXECUTABLE_PATH=""
if [ -f "${TZUHUANTAI_TEMP_DIR}/${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}" ]; then
    FOUND_EXECUTABLE_PATH="${TZUHUANTAI_TEMP_DIR}/${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}"
    echo_info "Found executable as '${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}' at: ${FOUND_EXECUTABLE_PATH}"
    # Rename pi-webrtc to pi_webrtc
    if [ "${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}" != "${FINAL_EXECUTABLE_NAME}" ]; then
        echo_info "Renaming '${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}' to '${FINAL_EXECUTABLE_NAME}'..."
        mv "${FOUND_EXECUTABLE_PATH}" "${TZUHUANTAI_TEMP_DIR}/${FINAL_EXECUTABLE_NAME}"
        FOUND_EXECUTABLE_PATH="${TZUHUANTAI_TEMP_DIR}/${FINAL_EXECUTABLE_NAME}"
        echo_info "Renamed successfully."
    fi
elif [ -f "${TZUHUANTAI_TEMP_DIR}/${FINAL_EXECUTABLE_NAME}" ]; then
    # If it's already named pi_webrtc
    FOUND_EXECUTABLE_PATH="${TZUHUANTAI_TEMP_DIR}/${FINAL_EXECUTABLE_NAME}"
    echo_info "Found executable as '${FINAL_EXECUTABLE_NAME}' at: ${FOUND_EXECUTABLE_PATH}"
else
    # Try finding recursively just in case structure changed
    FOUND_EXECUTABLE_PATH=$(find "${TZUHUANTAI_TEMP_DIR}" -name "${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}" -type f -executable -print -quit)
    if [ -n "${FOUND_EXECUTABLE_PATH}" ]; then
         echo_info "Found executable as '${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}' recursively at: ${FOUND_EXECUTABLE_PATH}"
         if [ "${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}" != "${FINAL_EXECUTABLE_NAME}" ]; then
            echo_info "Renaming '${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}' to '${FINAL_EXECUTABLE_NAME}'..."
            NEW_PATH=$(dirname "${FOUND_EXECUTABLE_PATH}")"/${FINAL_EXECUTABLE_NAME}"
            mv "${FOUND_EXECUTABLE_PATH}" "${NEW_PATH}"
            FOUND_EXECUTABLE_PATH="${NEW_PATH}"
            echo_info "Renamed successfully."
         fi
    else
        # Check if it was already named pi_webrtc recursively
        FOUND_EXECUTABLE_PATH=$(find "${TZUHUANTAI_TEMP_DIR}" -name "${FINAL_EXECUTABLE_NAME}" -type f -executable -print -quit)
        if [ -n "${FOUND_EXECUTABLE_PATH}" ]; then
            echo_info "Found executable as '${FINAL_EXECUTABLE_NAME}' recursively at: ${FOUND_EXECUTABLE_PATH}"
        fi
    fi
fi

# Copy the final executable if found
if [ -n "${FOUND_EXECUTABLE_PATH}" ] && [ -f "${FOUND_EXECUTABLE_PATH}" ]; then
    echo_info "Copying ${FINAL_EXECUTABLE_NAME} to ${S4V_DIR}/ ..."
    cp "${FOUND_EXECUTABLE_PATH}" "${S4V_DIR}/${FINAL_EXECUTABLE_NAME}"
    chmod +x "${S4V_DIR}/${FINAL_EXECUTABLE_NAME}" # Ensure it's executable
    echo_info "${FINAL_EXECUTABLE_NAME} installed successfully to ${S4V_DIR}/${FINAL_EXECUTABLE_NAME}."
else
    echo_error "Could not find the executable ('${EXPECTED_EXECUTABLE_NAME_IN_ARCHIVE}' or '${FINAL_EXECUTABLE_NAME}') within the extracted TzuHuanTai package."
    echo_error "Please check the package structure or the TZUHUANTAI_RELEASE_URL."
    echo_error "Installation cannot proceed without the main executable."
    exit 1 # This is critical
fi

# Clean up temporary files
echo_step "Cleaning up temporary files..."
rm -f "${B4ITERDEV_ARCHIVE_NAME}"
rm -rf "${B4ITERDEV_TEMP_DIR}"
rm -f "${TZUHUANTAI_ARCHIVE_NAME}"
rm -rf "${TZUHUANTAI_TEMP_DIR}"
echo_info "Temporary files cleaned up."

# Generate SSL certificate and key if they don't exist
SSL_KEY_PATH="${S4V_DIR}/server.key"
SSL_CERT_PATH="${S4V_DIR}/server.crt"
echo_step "Setting up SSL certificate..."

if [ -f "${SSL_KEY_PATH}" ] && [ -f "${SSL_CERT_PATH}" ]; then
    echo_info "SSL certificate and key already exist at \t'${S4V_DIR}\t'. Skipping generation."
else
    echo_info "Generating new SSL certificate and key (self-signed, valid for 100 years)..."
    current_hostname=$(hostname)
    openssl req -x509 -newkey rsa:4096 -nodes -keyout "${SSL_KEY_PATH}" -out "${SSL_CERT_PATH}" \
        -sha256 -days 36500 \
        -subj "/C=VN/ST=HN/O=S4V/OU=NRC/CN=${current_hostname}.local" \
        -addext "subjectAltName = DNS:${current_hostname}.local,IP:127.0.0.1"
    echo_info "SSL certificate and key generated successfully in \t'${S4V_DIR}\t'."
fi

# Create and enable systemd service
SYSTEMD_SERVICE_PATH="/etc/systemd/system/${SYSTEMD_SERVICE_FILENAME}"
echo_step "Setting up S4V Camera system service..."

# Verify the service file uses the correct executable name
echo_info "Verifying service file ('${FOUND_SYSTEMD_SERVICE_FILE}') uses '${S4V_DIR}/${FINAL_EXECUTABLE_NAME}'..."
if ! grep -q "ExecStart=${S4V_DIR}/${FINAL_EXECUTABLE_NAME}" "${FOUND_SYSTEMD_SERVICE_FILE}"; then
    echo_warn "The provided service file '${FOUND_SYSTEMD_SERVICE_FILE}' does not seem to call '${S4V_DIR}/${FINAL_EXECUTABLE_NAME}'."
    echo_warn "Please ensure the 'ExecStart' line in '${SYSTEMD_SERVICE_FILENAME}' points to the correct executable: ${S4V_DIR}/${FINAL_EXECUTABLE_NAME}"
    if ! confirm_action "Continue installation despite potential service file mismatch?"; then
        echo_error "User aborted due to service file mismatch concern. Please check '${SYSTEMD_SERVICE_FILENAME}'."
        exit 1
    fi
fi

if [ -f "${SYSTEMD_SERVICE_PATH}" ]; then
    echo_warn "An existing systemd service file was found at \t'${SYSTEMD_SERVICE_PATH}\t'."
    if confirm_action "Do you want to replace it with \t'${FOUND_SYSTEMD_SERVICE_FILE}\t'? A backup will be created."; then
        echo_info "Backing up existing systemd service file..."
        cp "${SYSTEMD_SERVICE_PATH}" "${SYSTEMD_SERVICE_PATH}.backup.$(date +%F-%H%M%S)"
        echo_info "Copying new systemd service file from \t'${FOUND_SYSTEMD_SERVICE_FILE}\t' to \t'${SYSTEMD_SERVICE_PATH}\t'..."
        cp "${FOUND_SYSTEMD_SERVICE_FILE}" "${SYSTEMD_SERVICE_PATH}"
        echo_info "Systemd service file updated."
    else
        echo_warn "Skipping systemd service file override. The existing service file will be used."
    fi
else
    echo_info "Copying new systemd service file from \t'${FOUND_SYSTEMD_SERVICE_FILE}\t' to \t'${SYSTEMD_SERVICE_PATH}\t'..."
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

