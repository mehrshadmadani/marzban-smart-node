#!/bin/bash

# --- Configs ---
MARZBAN_NODE_DIR="$HOME/Marzban-node" # This is where Marzban-node repository will be cloned
MARZBAN_NODE_LIB_DIR="/var/lib/marzban-node" # This is where SSL certs will be stored
DOCKER_COMPOSE_FILE="/opt/marzban-node/docker-compose.yml" # !!! NEW: Explicitly set the docker-compose.yml path !!!

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

# Function to check if a port is in use by ANY service defined in docker-compose.yml
# This checks both environment variables (for host network mode) and 'ports' section (for port mapping)
is_port_in_use_in_compose() {
    local port_to_check="$1"
    # Check if the port is used in any SERVICE_PORT or XRAY_API_PORT in any service environment section
    if awk -v p="$port_to_check" '
        /^\s*environment:/ {in_env_block=1; next} # Start of environment block
        /^\s*volumes:/ {in_env_block=0; next} # End of environment block (or next block)
        in_env_block && /SERVICE_PORT:/ {
            gsub(/"/, "", $NF); # Remove quotes
            if ($NF == p) {found_port=1; exit}
        }
        in_env_block && /XRAY_API_PORT:/ {
            gsub(/"/, "", $NF); # Remove quotes
            if ($NF == p) {found_port=1; exit}
        }
        /^[a-zA-Z0-9_-]+:$/ {in_env_block=0} # New service block, reset
        END {exit !found_port}
    ' "$DOCKER_COMPOSE_FILE" >/dev/null 2>&1; then
        return 0 # Port found in environment variables
    fi

    # Also check ports in 'ports' section for port mapping
    # This checks lines like '- 8080:80' where 8080 is the external port
    if awk -v p="$port_to_check" '
        /^\s*ports:/ {in_ports_block=1; next} # Start of ports block
        /^\s*[a-zA-Z0-9_-]+:$/ {in_ports_block=0} # New service block, reset
        in_ports_block && /^\s*-\s*[[:digit:]]+:[[:digit:]]+/ {
            split($0, arr, ":"); # Split by :
            gsub(/[^0-9]/, "", arr[1]); # Remove non-digits from external port
            if (arr[1] == p) {exit 0} # Found
        }
        END {exit 1} # Not found
    ' "$DOCKER_COMPOSE_FILE" >/dev/null 2>&1; then
        return 0 # Port found in ports section
    fi
    return 1 # Port not found
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

# --- Prompt for Node Details and Add to Docker Compose ---
prompt_and_add_node_service_to_compose() {
    log_info "\n--- Enter details for the NEW Marzban Node Service ---"
    
    local new_service_name
    local service_port
    local api_port
    local client_cert_file_path # Path for the client certificate file

    read -p "Enter a UNIQUE name for this new node service in Docker (e.g., my-new-node-panel1): " new_service_name
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
        while is_port_in_use_in_compose "$api_port" || (command -v netstat >/dev/null && sudo netstat -tuln | grep -q ":$api_port\b") || (command -v ss >/dev/null && sudo ss -tuln | grep -q ":$api_port\b"); do
            api_port=$((api_port + 1))
        done

        log_info "Auto-assigned SERVICE_PORT: $service_port, XRAY_API_PORT: $api_port"
    else
        read -p "Enter SERVICE_PORT for this new node: " service_port
        while [[ ! "$service_port" =~ ^[0-9]+$ ]] || [ "$service_port" -lt 1 ] || is_port_in_use_in_compose "$service_port" || (command -v netstat >/dev/null && sudo netstat -tuln | grep -q ":$service_port\b") || (command -v ss >/dev/null && sudo ss -tuln | grep -q ":$api_port\b"); do
            if [[ ! "$service_port" =~ ^[0-9]+$ ]] || [ "$service_port" -lt 1 ]; then
                log_warning "Invalid port. Please enter a valid positive integer."
            else
                log_warning "Port '$service_port' is already in use by compose or system. Please choose a different port."
            fi
            read -p "Enter SERVICE_PORT for this new node: " service_port
        done

        read -p "Enter XRAY_API_PORT for this new node: " api_port
        while [[ ! "$api_port" =~ ^[0-9]+$ ]] || [ "$api_port" -lt 1 ] || is_port_in_use_in_compose "$api_port" || (command -v netstat >/dev/null && sudo netstat -tuln | grep -q ":$api_port\b") || (command -v ss >/dev/null && sudo ss -tuln | grep -q ":$api_port\b"); do
            if [[ ! "$api_port" =~ ^[0-9]+$ ]] || [ "$api_port" -lt 1 ]; then
                log_warning "Invalid port. Please enter a valid positive integer."
            else
                log_warning "Port '$api_port' is already in use by compose or system. Please choose a different port."
            fi
            read -p "Enter XRAY_API_PORT for this new node: " api_port
        done
    fi

    client_cert_file_path="${MARZBAN_NODE_LIB_DIR}/ssl_client_cert_${new_service_name}.pem"

    log_info "Please manually get the SSL Client Certificate from your Marzban Panel."
    log_info "Go to Panel -> Node Settings -> Add New Node -> 'Show Certificate' button."
    log_info "Paste the FULL certificate content (including -----BEGIN CERTIFICATE----- and -----END CERTIFICATE-----) below."
    log_info "Press Enter after each line, and Ctrl+D when you are completely finished pasting:"
    local cert_content=""
    while IFS= read -r line; do
        cert_content="$cert_content$line\n"
    done
    cert_content=$(echo -e "$cert_content" | sed '$d') # Remove last newline

    # Check if cert_content is empty or invalid
    if [ -z "$cert_content" ] || ! echo "$cert_content" | grep -q '-----BEGIN CERTIFICATE-----'; then
        log_error "No valid certificate content received. Please try again and paste the full certificate."
    fi

    # Save
