#!/bin/bash

# --- Configuration ---
MARZBAN_NODE_DIR="$HOME/Marzban-node"
MARZBAN_NODE_LIB_DIR="/var/lib/marzban-node"
DOCKER_COMPOSE_FILE="$MARZBAN_NODE_DIR/docker-compose.yml"
# We will use our custom Python script directly for API interaction
PYTHON_API_HANDLER_SCRIPT="marzban_api_handler_custom.py"

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
    # Iterate through all 'environment' sections to find SERVICE_PORT or XRAY_API_PORT
    awk -v p="$port_to_check" '
        /^\s*marzban-node-/{in_service=1; service_name=$1; next}
        /^\s*service:/ {in_service=1; service_name=$1; next} # Catch generic services too
        in_service && /^\s*environment:/ {in_env=1; next}
        in_service && in_env && /^\s*SERVICE_PORT:\s*\"?[[:digit:]]+\"?/ {
            gsub(/"/, "", $NF); # Remove quotes
            if ($NF == p) {found=1; exit}
        }
        in_service && in_env && /^\s*XRAY_API_PORT:\s*\"?[[:digit:]]+\"?/ {
            gsub(/"/, "", $NF); # Remove quotes
            if ($NF == p) {found=1; exit}
        }
        /^\s*\S.*:$/ {in_service=0; in_env=0} # End of service block
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
    log_info "Setting up custom Python API handler script."
    
    # Create the Python script for API interaction directly
    cat << EOF > "$MARZBAN_NODE_DIR/$PYTHON_API_HANDLER_SCRIPT"
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

def get_token(panel_api_base_url, username, password):
    log_py(f"Attempting to login to {panel_api_base_url}/admin/token...")
    headers = {"Content-Type": "application/json"}
    data = json.dumps({"username": username, "password": password})
    try:
        response = requests.post(f"{panel_api_base_url}/admin/token", headers=headers, data=data, verify=False)
        response.raise_for_status() # Raise an exception for HTTP errors
        return response.json().get("access_token")
    except requests.exceptions.RequestException as e:
        log_py(f"Login failed: {e}. Check API URL, username, and password.")
        return None

def get_client_cert(panel_api_base_url, token):
    log_py(f"Attempting to retrieve client certificate from {panel_api_base_url}/admin/nodes/certificate...")
    headers = {"Authorization": f"Bearer {token}"}
    try:
        response = requests.get(f"{panel_api_base_url}/admin/nodes/certificate", headers=headers, verify=False)
        response.raise_for_status()
        return response.json().get("cert")
    except requests.exceptions.RequestException as e:
        log_py(f"Failed to retrieve certificate: {e}. Check API access or Panel version.")
        return None

def add_node_to_panel(panel_api_base_url, token, node_name, node_address, service_port, api_port):
    log_py(f"Attempting to add node '{node_name}' to {panel_api_base_url}/admin/nodes...")
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {token}"}
    data = json.dumps({
        "name": node_name,
        "address": node_address,
        "port": int(service_port),
        "api_port": int(api_port),
        "usage_ratio": 1
    })
    try:
        response = requests.post(url, data=data, headers=headers, verify=False) # Use data=data for JSON body
        response.raise_for_status()
        result = response.json()
        if response.status_code in [200, 201]: # 200 for update, 201 for create
            log_py(f"Node '{node_name}' successfully added/updated.")
            return True
        else:
            log_py(f"Failed to add/update node. Status: {response.status_code}, Response: {result}")
            return False
    except requests.exceptions.RequestException as e:
        log_py(f"Failed to add/update node: {e}")
        return False

if __name__ == "__main__":
    # Arguments: <panel_protocol> <panel_domain> <panel_port> <username> <password> <node_name> <node_address> <service_port> <api_port>
    if len(sys.argv) < 10:
        log_py("Usage: python marzban_api_handler_custom.py <protocol> <domain> <port> <username> <password> <node_name> <node_address> <service_port> <api_port>")
        sys.exit(1)

    panel_protocol = sys.argv[1]
    panel_domain = sys.argv[2]
    panel_port = sys.argv[3]
    username = sys.argv[4]
    password = sys.argv[5]
    node_name = sys.argv[6]
    node_address = sys.argv[7]
    service_port = sys.argv[8]
    api_port = sys.argv[9]

    # Construct the API base URL: <scheme>://<hostname>:<port_if_not_default>/api
    panel_api_base_url = f"{panel_protocol}://{panel_domain}"
    
    # Add port only if it's not a default port for the given scheme
    if not ((panel_protocol == "http" and panel_port == "80") or \
            (panel_protocol == "https" and panel_port == "443")):
        panel_api_base_url += f":{panel_port}"
    
    panel_api_base_url += "/api" # Append the common /api endpoint suffix

    log_py(f"Constructed API Base URL for Python script: {panel_api_base_url}")

    token = get_token(panel_api_base_url, username, password)
    if not token:
        sys.exit(1)

    cert_content = get_client_cert(panel_api_base_url, token)
    if not cert_content:
        sys.exit(1)
    
    # Print cert_content to stdout so bash script can capture it. 
    # This must be the ONLY thing printed to stdout for successful capture.
    print(cert_content)

    if not add_node_to_panel(panel_api_base_url, token, node_name, node_address, service_port, api_port):
        sys.exit(1)

    sys.exit(0) # Explicitly exit with 0 on success
EOF
    
    chmod +x "$MARZBAN_NODE_DIR/$PYTHON_API_HANDLER_SCRIPT" || log_error "Failed to make Python script executable."
    log_info "Python API handler setup complete."
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
    read -p "Enter Marzban Panel Domain (e.g., your-panel.com or 1.2.3.4): " panel_domain_input
    
    read -p "Is your Marzban Panel using HTTPS (y/n)? " use_https_input
    local panel_protocol_input # http or https
    if [[ "$use_https_input" =~ ^[Yy]$ ]]; then
        panel_protocol_input="https"
    else
        panel_protocol_input="http"
    fi

    read -p "Enter Marzban Panel Port (e.g., 80, 443, 2003): " panel_port_input
    while [[ ! "$panel_port_input" =~ ^[0-9]+$ ]] || [ "$panel_port_input" -lt 1 ]; do
        log_warning "Invalid port. Please enter a valid positive integer."
        read -p "Enter Marzban Panel Port (e.g., 80, 443, 2003): " panel_port_input
    done
    
    # --- Input Panel Authentication ---
    read -p "Enter Marzban Panel Username: " panel_username
    read -s -p "Enter Marzban Panel Password: " panel_password # -s hides input
    echo # New line after password input

    # --- Node Service Details ---
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

    # --- Use Python script for API interaction ---
    log_info "Attempting to interact with Marzban Panel API via Python script..."
    log_info "Running Python script to get token, client cert, and add node..."

    # Run Python script and capture its output (stderr is redirected to stdout for logging)
    local py_output
    # Pass protocol, domain, port, username, password, node_name, node_address, service_port, api_port
    py_output=$( python3 "$MARZBAN_NODE_DIR/$PYTHON_API_HANDLER_SCRIPT" \
        "$panel_protocol_input" "$panel_domain_input" "$panel_port_input" \
        "$panel_username" "$panel_password" \
        "$new_service_name" "$node_display_address" "$service_port" "$api_port" 2>&1 )

    local py_exit_code=$?
    log_info "Python script raw output:"
    echo "$py_output" | sed 's/^/\t/' # Indent Python script output for readability

    if [ "$py_exit_code" -ne 0 ]; then
        log_error "Python script failed to interact with Marzban API. Please check panel details and logs above for errors."
    fi

    # Extract certificate content (it's the only direct print to stdout)
    local client_cert_content=$(echo "$py_output" | awk '/-----BEGIN CERTIFICATE-----/{flag=1; print $0; next} /-----END CERTIFICATE-----/{print $0; flag=0; next} flag') 
    
    # Verify cert_content is a certificate
    if [ -z "$client_cert_content" ] || ! echo "$client_cert_content" | grep -q '-----BEGIN CERTIFICATE-----'; then # Check if cert_content is empty or invalid
        log_error "Failed to retrieve a valid SSL Client Certificate from Python script output. This is critical. Check Python script logs above for errors."
    fi

    # Save Client Certificate to file
    echo -e "$client_cert_content" | sudo tee "$client_cert_file_path" >/dev/null || log_error "Failed to save certificate."
    sudo chmod 644 "$client_cert_file_path" || log_warning "Failed to change certificate permissions."
    log_info "SSL Client Certificate saved to $client_cert_file_path."

    # Append new service to docker-compose.yml
    cat << EOF >> "$DOCKER_COMPOSE_FILE"

  $new_service_name:
    image: gozargah/marzban-node:latest
    restart: always
    network_mode: host
    environment:
      SSL_CLIENT_CERT_FILE: "$client_cert_file_path"
      SERVICE_PORT: "$service_port"
      XRAY_API_PORT: "$api_port"
      SERVICE_PROTOCOL: "rest"
    volumes:
      - $MARZBAN_NODE_LIB_DIR:/var/lib/marzban-node
      - /var/lib/marzban:/var/lib/marzban
EOF

    log_info "New service '$new_service_name' added to docker-compose.yml for Docker Compose."
    log_info "Updated docker-compose.yml content:"
    cat "$DOCKER_COMPOSE_FILE"
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
