#!/bin/bash

# --- Configuration ---
MARZBAN_NODE_DIR="$HOME/Marzban-node"
MARZBAN_NODE_LIB_DIR="/var/lib/marzban-node"
DOCKER_COMPOSE_FILE="$MARZBAN_NODE_DIR/docker-compose.yml"
PYTHON_API_HANDLER_SCRIPT="marzban_api_handler_custom.py" # Our custom Python script

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

# Function to check if a Python library is installed (system-wide)
check_python_library() {
    python3 -c "import $1" &> /dev/null
}

# Function to install Python library via pip (system-wide)
install_python_library_pip() {
    local lib_package="$1"
    log_info "Installing Python library: $lib_package via pip..."
    if ! pip3 install "$lib_package" --break-system-packages &> /dev/null; then
        log_error "Failed to install $lib_package. Please check Python/pip installation."
    fi
}

# Function to check if a port is in use by ANY service defined in docker-compose.yml
is_port_in_use_in_compose() {
    local port_to_check="$1"
    # Check if the port is used in any SERVICE_PORT or XRAY_API_PORT in any service environment section
    awk -v p="$port_to_check" '
        /^\s*-/ {in_ports_block=1; next} # Lines starting with - in ports section
        /^\s*ports:/ {in_ports_block=1; next} # Explicit ports block
        /^\s*environment:/ {in_env_block=1; next} # Environment block
        /^[a-zA-Z0-9_-]+:$/ {in_ports_block=0; in_env_block=0} # New service block

        in_ports_block {
            split($0, arr, ":"); # Split by : for port mapping
            # Check the external port (before colon)
            gsub(/ /, "", arr[1]); # Remove quotes
            if (arr[1] == p) {found=1; exit}
        }
        in_env_block {
            if ($1 == "SERVICE_PORT:" || $1 == "XRAY_API_PORT:") {
                gsub(/"/, "", $NF); # Remove quotes
                if ($NF == p) {found=1; exit}
            }
        }
        END {exit !found}
    ' "$DOCKER_COMPOSE_FILE" >/dev/null 2>&1
}


# Function to get a random unused port (checks system and compose)
get_random_free_port() {
    local start_port=61000
    local end_port=65000
    local port_found=""

    for ((port=start_port; port<=end_port; port++)); do
        local port_in_use_system=false
        # Check if port is open on system (using ss as netstat might not be installed)
        if command -v netstat >/dev/null; then
            if sudo netstat -tuln | grep -q ":$port\b"; then
                port_in_use_system=true
            fi
        elif command -v ss >/dev/null; then
            if sudo ss -tuln | grep -q ":$port\b"; then
                port_in_use_system=true
            fi
        fi

        if [ "$port_in_use_system" = false ]; then
            if ! is_port_in_use_in_compose "$port"; then
                echo "$port"
                return 0
            fi
        fi
    done
    return 1 # No free port found
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
    # net-tools is for netstat. ss is usually part of iproute2 (preinstalled).
    if ! command -v netstat >/dev/null && ! command -v ss >/dev/null; then
        missing_pkgs+=("net-tools") # Recommend net-tools if neither found for port check
    fi

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
    
    # Install requests needed by our custom Python script
    if ! check_python_library "requests"; then
        log_info "Python 'requests' library not found. Installing..."
        install_python_library_pip "requests"
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

# --- Custom Python API Handler Setup ---
setup_custom_python_api_handler() {
    log_info "Setting up custom Python API handler script for Marzban interaction."
    
    # Create the Python script for API interaction directly
    cat << 'EOF' > "$MARZBAN_NODE_DIR/$PYTHON_API_HANDLER_SCRIPT"
import requests
import json
import sys
import os
import urllib.parse # For URL parsing

# Disable urllib3 warnings about unverified HTTPS requests (for self-signed certs)
requests.packages.urllib3.disable_warnings(requests.packages.urllib3.exceptions.InsecureRequestWarning)

def log_py(message):
    # This function logs to stderr so it doesn't interfere with stdout output (certificate)
    print(f"[PY_LOG] {message}", file=sys.stderr)

def get_token(panel_protocol, panel_domain, panel_port, username, password):
    # Construct URL for /api/admin/token
    panel_api_url = f"{panel_protocol}://{panel_domain}"
    if not ((panel_protocol == "http" and panel_port == "80") or (panel_protocol == "https" and panel_port == "443")):
        panel_api_url += f":{panel_port}"
    panel_api_url += "/api/admin/token" # Marzban's standard API token endpoint

    log_py(f"Attempting to login to {panel_api_url}...")
    headers = {"Content-Type": "application/json"}
    data = json.dumps({"username": username, "password": password})
    try:
        response = requests.post(url=panel_api_url, data=data, headers=headers, verify=False)
        response.raise_for_status() # Raise an exception for HTTP errors
        return response.json().get("access_token")
    except requests.exceptions.RequestException as e:
        log_py(f"Login failed: {e}. Check Panel URL, username, and password.")
        return None

def get_client_cert(panel_protocol, panel_domain, panel_port, token):
    # Construct URL for /api/admin/nodes/certificate
    panel_api_url = f"{panel_protocol}://{panel_domain}"
    if not ((panel_protocol == "http" and panel_port == "80") or (panel_protocol == "https" and panel_port == "443")):
        panel_api_url += f":{panel_port}"
    panel_api_url += "/api/admin/nodes/certificate" # Marzban's standard API endpoint for node cert

    log_py(f"Attempting to retrieve client certificate from {panel_api_url}...")
    headers = {"Authorization": f"Bearer {token}"}
    try:
        response = requests.get(url=panel_api_url, headers=headers, verify=False)
        response.raise_for_status()
        cert = response.json()
        return cert.get("certificate") # Using .get() for safety
    except requests.exceptions.RequestException as e:
        log_py(f"Failed to retrieve certificate: {e}. Check API access or Panel version.")
        return None

def add_node_to_panel(panel_protocol, panel_domain, panel_port, token, node_name, node_address, service_port, api_port, add_as_new_host):
    # Construct URL for /api/admin/nodes
    panel_api_url = f"{panel_protocol}://{panel_domain}"
    if not ((panel_protocol == "http" and panel_port == "80") or (panel_protocol == "https" and panel_port == "443")):
        panel_api_url += f":{panel_port}"
    panel_api_url += "/api/admin/nodes" # Marzban's standard API endpoint for adding nodes

    log_py(f"Attempting to add node '{node_name}' to {panel_api_url}...")
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}"
    }
    node_information = {
        "name": node_name,
        "address": node_address,
        "port": int(service_port),
        "api_port": int(api_port),
        "add_as_new_host": add_as_new_host, # Pass boolean directly
        "usage_coefficient": 1
    }
    data = json.dumps(node_information)
    
    try:
        response = requests.post(url=panel_api_url, data=data, headers=headers, verify=False)
        response.raise_for_status()
        result = response.json()
        if response.status_code in [200, 201]: # 200 for update, 201 for create
            log_py(f"Node '{node_name}' successfully added/updated to panel.")
            return True
        else:
            log_py(f"Failed to add/update node. Status: {response.status_code}, Response: {result}")
            return False
    except requests.exceptions.RequestException as e:
        log_py(f"Failed to add/update node to panel: {e}")
        return False

if __name__ == "__main__":
    # Arguments: <panel_domain> <panel_port> <panel_protocol_bool_str> <username> <password> <node_name> <node_address> <service_port> <api_port> <add_as_new_host_bool_str>
    if len(sys.argv) < 11:
        log_py("Usage: python marzban_api_handler_custom.py <domain> <port> <https_bool> <username> <password> <node_name> <node_address> <service_port> <api_port> <add_as_new_host_bool_str>")
        sys.exit(1)

    panel_domain = sys.argv[1]
    panel_port = sys.argv[2]
    https_enabled = sys.argv[3].lower() == 'true' # Convert string "True"/"False" to boolean True/False
    username = sys.argv[4]
    password = sys.argv[5]
    node_name = sys.argv[6]
    node_address = sys.argv[7]
    service_port = sys.argv[8]
    api_port = sys.argv[9]
    add_as_new_host = sys.argv[10].lower() == 'true' # Convert string "True"/"False" to boolean True/False

    panel_protocol = "https" if https_enabled else "http"

    token = get_token(panel_domain, panel_port, https_enabled, username, password)
    if not token:
        sys.exit(1)

    cert_content = get_client_cert(panel_domain, panel_port, https_enabled, token)
    if not cert_content:
        sys.exit(1)
    
    # Print cert_content to stdout as the ONLY thing for Bash to capture for cert file
    print(cert_content)

    if not add_node_to_panel(panel_domain, panel_port, https_enabled, token, node_name, node_address, service_port, api_port, add_as_new_host):
        sys.exit(1)

    sys.exit(0) # Explicitly exit with 0 on success
EOF
    
    chmod +x "$MARZBAN_NODE_DIR/$PYTHON_API_HANDLER_SCRIPT" || log_error "Failed to make Python script executable."
    log_info "Python API handler setup complete."
}

# --- Main Execution Flow ---
main() {
    log_info "Starting Marzban Node deployment/addition script (Smart Mode)."
    
    check_prerequisites
    setup_marzban_node_base
    setup_custom_python_api_handler # Setup Python and custom API script

    # --- Initial docker-compose.yml creation if not exists ---
    if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
        log_warning "docker-compose.yml not found. Creating a new, empty docker-compose.yml with 'services:' header."
        echo "services:" > "$DOCKER_COMPOSE_FILE"
        log_info "Empty docker-compose.yml created. Now proceeding to add your first node service."
    fi

    add_new_node_to_system # Call the function that handles adding node to Docker and Panel

    log_info "Applying Docker Compose changes..."
    cd "$MARZBAN_NODE_DIR" || log_error "Failed to enter Marzban-node directory."
    
    # Use --remove-orphans to clean up old services that are no longer defined in the updated compose file
    sudo docker compose down --remove-orphans || log_warning "Failed to stop/remove old containers. Continuing..."
    sudo docker compose pull || log_warning "Failed to pull Docker images. Continuing..."
    sudo docker compose up -d || log_error "Failed to start Docker Compose."

    log_info "Marzban Node(s) successfully deployed/updated."

    log_info "\n--- Final Check ---"
    log_info "Please go to your Marzban Panel -> Node Settings to confirm the new node's status (should be Green)."
    log_info "Also, remember: In Host Network mode, all inbound ports are exposed. Ensure your Inbound Ports across different Marzban Panels do NOT conflict on this node."
    log_info "\nAll automated steps completed successfully."
}

# Execute main function
main
