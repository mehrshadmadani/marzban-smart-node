#!/bin/bash

# --- Configuration ---
MARZBAN_NODE_DIR="$HOME/Marzban-node"
MARZBAN_NODE_LIB_DIR="/var/lib/marzban-node"
DOCKER_COMPOSE_FILE="$MARZBAN_NODE_DIR/docker-compose.yml"
# We will download the original curlscript.py from ItsAML/MarzbanEZNode
ITSAML_PYTHON_SCRIPT_URL="https://raw.githubusercontent.com/ItsAML/MarzbanEZNode/main/curlscript.py"
ITSAML_PYTHON_SCRIPT_NAME="itsaml_marzban_api_handler.py" # Renamed for clarity and uniqueness in our repo

# --- Helper Functions (Finglish) ---
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
check_python_library() {
    python3 -c "import $1" &> /dev/null
}

# Function to install Python library via pip (trying --break-system-packages)
install_python_library_pip() {
    local lib_package="$1"
    log_info "Installing Python library: $lib_package via pip..."
    if ! pip3 install "$lib_package" &> /dev/null; then
        log_warning "Pip install failed. Trying with --break-system-packages..."
        pip3 install "$lib_package" --break-system-packages || log_error "Failed to install $lib_package. Please check Python/pip installation."
    fi
}

# Function to check if a port is in use in the existing docker-compose.yml
is_port_in_use_in_compose() {
    local port_to_check="$1"
    grep -qE "SERVICE_PORT: \"$port_to_check\"|XRAY_API_PORT: \"$port_to_check\"" "$DOCKER_COMPOSE_FILE"
}

# Function to get a random unused port (checks system and compose)
get_random_free_port() {
    local start_port=61000
    local end_port=65000
    local port

    for ((port=start_port; port<=end_port; port++)); do
        if command -v netstat >/dev/null; then
            if ! sudo netstat -tuln | grep -q ":$port\b"; then
                if ! is_port_in_use_in_compose "$port"; then
                    echo "$port"
                    return 0
                fi
            fi
        elif command -v ss >/dev/null; then
            if ! sudo ss -tuln | grep -q ":$port\b"; then
                if ! is_port_in_use_in_compose "$port"; then
                    echo "$port"
                    return 0
                fi
            fi
        else
            log_warning "Neither netstat nor ss found. Cannot reliably check for free ports. Proceeding with compose-only check."
            if ! is_port_in_use_in_compose "$port"; then
                echo "$port"
                return 0
            fi
        fi
    done
    return 1
}

# --- Prerequisites Check ---
check_prerequisites() {
    log_info "Checking prerequisites..."
    local missing_pkgs=()

    command -v curl >/dev/null || missing_pkgs+=("curl")
    command -v socat >/dev/null || missing_pkgs+=("socat")
    command -v git >/dev/null || missing_pkgs+=("git")
    command -v docker >/dev/null || missing_pkgs+=("docker")
    command -v docker-compose >/dev/null || missing_pkgs+=("docker-compose")
    command -v python3 >/dev/null || missing_pkgs+=("python3")
    command -v pip3 >/dev/null || missing_pkgs+=("python3-pip") # pip is usually part of python3-pip apt package
    command -v netstat >/dev/null || missing_pkgs+=("net-tools") # For netstat command

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_warning "Missing packages: ${missing_pkgs[*]}. Installing them..."
        sudo apt-get update || log_error "Failed to update apt-get."
        sudo apt-get install -y "${missing_pkgs[@]}" || log_error "Failed to install prerequisites."
    fi

    if ! command -v docker >/dev/null; then
        log_info "Docker is not installed. Installing Docker..."
        curl -fsSL https://get.docker.com | sh || log_error "Failed to install Docker."
        sudo systemctl start docker
        sudo systemctl enable docker
    fi

    if ! command -v docker-compose >/dev/null; then
        log_info "docker-compose is not installed. Installing docker-compose..."
        sudo apt-get install -y docker-compose || log_error "Failed to install docker-compose."
    fi

    # Install requests and paramiko needed by ItsAML's curlscript.py
    if ! python3 -c "import requests" &> /dev/null; then
        log_info "Python 'requests' library not found. Installing..."
        pip3 install requests --break-system-packages || log_error "Failed to install 'requests' library."
    fi
    if ! python3 -c "import paramiko" &> /dev/null; then
        log_info "Python 'paramiko' library not found. Installing..."
        pip3 install paramiko --break-system-packages || log_error "Failed to install 'paramiko' library."
    fi

    log_info "All prerequisites are installed."
}

# --- Marzban-node Base Setup ---
setup_marzban_node_base() {
    log_info "Setting up Marzban-node base files..."

    if [ ! -d "$MARZBAN_NODE_DIR" ]; then
        log_info "Cloning Marzban-node repository..."
        git clone https://github.com/Gozargah/Marzban-node "$MARZBAN_NODE_DIR" || log_error "Failed to clone repository."
    else
        log_info "Marzban-node repository already exists. Updating it..."
        cd "$MARZBAN_NODE_DIR" && git pull || log_warning "Failed to update repository. Continuing..."
    fi

    if [ ! -d "$MARZBAN_NODE_LIB_DIR" ]; then
        log_info "Creating directory $MARZBAN_NODE_LIB_DIR for SSL certs and node data..."
        sudo mkdir -p "$MARZBAN_NODE_LIB_DIR" || log_error "Failed to create directory."
    fi

    log_info "Marzban-node base setup complete."
}

# --- Main Logic to Add Node ---
add_new_node_to_system() {
    log_info "Adding new Marzban Node service to Docker Compose and Panel..."

    local new_service_name
    local service_port
    local api_port
    local client_cert_file_path
    local panel_domain_input # Panel domain (e.g., your-panel.com or 1.2.3.4)
    local use_https_input # y/n
    local panel_port_input   # Panel port (e.g., 80, 443, 2003)
    local panel_username
    local panel_password
    local node_display_address
    local use_auto_ports

    log_info "\n--- Enter details for the NEW Marzban Node and Panel connection ---"

    # --- Collect Panel Connection Details for ItsAML's script ---
    # These questions directly map to ItsAML's curlscript.py inputs
    read -p "Please Enter Your Marzban Domain/IP: " panel_domain_input
    read -p "Please Enter Your Marzban Port: " panel_port_input

    read -p "Are You using HTTPS/SSL? (y/n): " use_https_input
    local itsaml_https_flag # "True" or "False" as string for Python
    if [[ "$use_https_input" =~ ^[Yy]$ ]]; then
        itsaml_https_flag="True"
    else
        itsaml_https_flag="False"
    fi

    read -p "Please Enter Your Marzban Username: " panel_username
    read -s -p "Please Enter Your Marzban Password: " panel_password # -s hides input
    echo # New line after password input

    # --- Node Service Details for Docker Compose ---
    read -p "Enter a UNIQUE name for this new node service in Docker (e.g., my-new-node): " new_service_name
    while grep -q "services:\s*$new_service_name:" "$DOCKER_COMPOSE_FILE" 2>/dev/null; do
        log_warning "Service name '$new_service_name' already exists in docker-compose.yml. Please choose a different name."
        read -p "Enter a unique name for this new node service: " new_service_name
    done

    read -p "Do you want to auto-assign SERVICE_PORT and XRAY_API_PORT (y/n)? (e.g., 61000, 61001): " use_auto_ports
    if [[ "$use_auto_ports" =~ ^[Yy]$ ]]; then
        service_port=$(get_random_free_port)
        if [ -z "$service_port" ]; then
            log_error "Could not find any free SERVICE_PORT automatically. Please try again manually or free up ports."
        fi
        api_port=$((service_port + 1)) # Try next sequential port
        while is_port_in_use_in_compose "$api_port" || sudo netstat -tuln | grep -q ":$api_port\b"; do
            api_port=$((api_port + 1))
        done

        log_info "Auto-assigned SERVICE_PORT: $service_port, XRAY_API_PORT: $api_port"
    else
        read -p "Enter SERVICE_PORT for this new node: " service_port
        while [[ ! "$service_port" =~ ^[0-9]+$ ]] || [ "$service_port" -lt 1 ] || is_port_in_use_in_compose "$service_port" || sudo netstat -tuln | grep -q ":$service_port\b"; do
            if [[ ! "$service_port" =~ ^[0-9]+$ ]] || [ "$service_port" -lt 1 ]; then
                log_warning "Invalid port. Please enter a valid positive integer."
            else
                log_warning "Port '$service_port' is already in use or used by another service in docker-compose.yml. Please choose a different port."
            fi
            read -p "Enter SERVICE_PORT for this new node: " service_port
        done

        read -p "Enter XRAY_API_PORT for this new node: " api_port
        while [[ ! "$api_port" =~ ^[0-9]+$ ]] || [ "$api_port" -lt 1 ] || is_port_in_use_in_compose "$api_port" || sudo netstat -tuln | grep -q ":$api_port\b"; do
            if [[ ! "$api_port" =~ ^[0-9]+$ ]] || [ "$api_port" -lt 1 ]; then
                log_warning "Invalid port. Please enter a valid positive integer."
            else
                log_warning "Port '$api_port' is already in use or used by another service in docker-compose.yml. Please choose a different port."
            fi
            read -p "Enter XRAY_API_PORT for this new node: " api_port
        done
    fi

    # Get Node's own public IP for Panel Address (optional, user can provide domain)
    local public_ip=$(curl -s api.ipify.org)
    read -p "Enter Node's Address for Marzban Panel (your node's public IP or a domain, e.g., $public_ip or node.yourdomain.com): " node_display_address
    node_display_address=${node_display_address:-$public_ip} # Use public IP as default

    client_cert_file_path="${MARZBAN_NODE_LIB_DIR}/ssl_client_cert_${new_service_name}.pem"

    # --- Execute ItsAML's curlscript.py ---
    log_info "Downloading ItsAML's curlscript.py for API interaction..."
    curl -sSL "$ITSAML_PYTHON_SCRIPT_URL" > "$MARZBAN_NODE_DIR/$ITSAML_PYTHON_SCRIPT_NAME" || log_error "Failed to download $ITSAML_PYTHON_SCRIPT_NAME."
    chmod +x "$MARZBAN_NODE_DIR/$ITSAML_PYTHON_SCRIPT_NAME" || log_warning "Failed to make $ITSAML_PYTHON_SCRIPT_NAME executable."

    log_info "Running ItsAML's curlscript.py to get client cert and add node to panel via its own SSH calls..."
    log_warning "Please ensure you manually input SSH password for the Node Server when prompted by curlscript.py"

    # We are using 'expect' to provide interactive input to curlscript.py
    # This is the most reliable way to automate interactive scripts in Bash.
    # This requires 'expect' to be installed: sudo apt-get install expect
    if ! command -v expect >/dev/null; then
        log_error "The 'expect' command is not installed. Please install it using 'sudo apt-get install expect' and rerun the script."
    fi

    # Create a temporary expect script
    local expect_script="$MARZBAN_NODE_DIR/expect_script.exp"

    # Get SSH password from user
    local node_ssh_password
    read -s -p "Please Enter your Node Server's SSH password (for ItsAML's script internal SSH connection): " node_ssh_password
    echo # Newline

    # Populate the expect script with answers to curlscript.py prompts
    cat << EOF_EXPECT > "$expect_script"
    #!/usr/bin/expect -f
    set timeout 300 ;# Timeout in seconds

    # Run the Python script
    spawn python3 "$MARZBAN_NODE_DIR/$ITSAML_PYTHON_SCRIPT_NAME"

    # Expect prompts and send answers
    expect "Please Enter Your Marzban Domain
