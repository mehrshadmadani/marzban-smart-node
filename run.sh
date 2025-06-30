#!/bin/bash

# --- ItsAML/MarzbanEZNode - run.sh (Modified for smart node setup) ---
# This script sets up prerequisites and executes the custom curlscript.py

# --- Helper Functions ---
log_info() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

log_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1"
}

log_error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
    exit 1
}

# Function to check if a Python library is installed
check_library() {
    python3 -c "import $1" &> /dev/null
}

# Function to install Python library via pip (trying --break-system-packages)
install_python_library_pip() {
    local lib_package="$1"
    log_info "Installing Python library: $lib_package via pip..."
    # Use --break-system-packages for system-wide pip installs on newer Ubuntus
    if ! pip3 install "$lib_package" --break-system-packages &> /dev/null; then
        log_error "Failed to install $lib_package. Please check Python/pip installation or try manually."
    fi
}

# --- Prerequisites Check ---
log_info "Checking prerequisites..."

# Check and install python3
if ! command -v python3 &> /dev/null; then
    log_warning "Python3 is not installed. Installing..."
    sudo apt update || log_error "Failed to update apt."
    sudo apt install python3 -y || log_error "Failed to install Python3."
fi

# Check and install pip3
if ! command -v pip3 &> /dev/null; then
    log_warning "pip is not installed. Installing..."
    sudo apt install python3-pip -y || {
        log_warning "Installing pip via alternative method (wget)..."
        sudo apt install wget -y || log_error "Failed to install wget for pip alternative method."
        wget -qO- https://bootstrap.pypa.io/get-pip.py | sudo python3 - || log_error "Failed to install pip."
    }
fi

# Check and install required Python libraries (requests, paramiko)
# These are used by curlscript.py
required_libraries=("requests" "paramiko") # Only names, versions are handled by pip

for lib in "${required_libraries[@]}"; do
    if ! check_library "$lib"; then
        install_python_library_pip "$lib"
    else
        log_info "$lib is already installed."
    fi
done

# Ensure urllib3 is updated/installed as it's a critical dependency for requests
log_info "Ensuring urllib3 is up-to-date..."
upgrade_library_pip "urllib3" || log_warning "Failed to upgrade urllib3. Continuing..."


log_info "All prerequisites are installed."

# --- Download and Execute curlscript.py (our custom version) ---
log_info "Downloading custom curlscript.py from your GitHub repository..."
# This URL points to the custom curlscript.py that we will define in the next step
CUSTOM_CURLSCRIPT_URL="https://raw.githubusercontent.com/mehrshadmadani/marzban-smart-node/main/smart_curlscript.py" 

# Ensure we are in the home directory to save the script
cd "$HOME" || log_error "Failed to change to home directory."

curl -sSL "$CUSTOM_CURLSCRIPT_URL" > curlscript.py || log_error "Failed to download smart_curlscript.py."
chmod +x curlscript.py || log_error "Failed to make curlscript.py executable."

log_info "Executing smart_curlscript.py. Please follow its prompts (in Finglish) and enter requested information."
log_info "----------------------------------------------------------------------"

# Execute the Python script
# It will handle all interactive prompts for Marzban Panel and Node details
python3 curlscript.py

log_info "----------------------------------------------------------------------"
log_info "Script execution finished. Please check your Marzban Panel."

# (OPTIONAL) removing script
# rm curlscript.py # Consider leaving for debugging for now

log_info "\n--- Final Note ---"
log_warning "Remember: This setup configures ONE Marzban Node service. If you need to add MORE nodes (for other panels) to this ONE server, you MUST manually combine them in docker-compose.yml."
log_info "You can find docker-compose.yml at ~/Marzban-node/docker-compose.yml"
log_info "After manual editing, run: 'cd ~/Marzban-node && sudo docker compose down --remove-orphans && sudo docker compose pull && sudo docker compose up -d' to apply changes."
log_info "\nAll steps completed. Good luck!"
