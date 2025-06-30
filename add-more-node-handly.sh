#!/bin/bash

# --- Configs ---
MARZBAN_NODE_DIR="$HOME/Marzban-node"
MARZBAN_NODE_LIB_DIR="/var/lib/marzban-node"
DOCKER_COMPOSE_FILE="$MARZBAN_NODE_DIR/docker-compose.yml"

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

# Check if a port is already in use in docker-compose.yml
is_port_in_use() {
    local port_to_check="$1"
    # Search for SERVICE_PORT and XRAY_API_PORT in existing services
    grep -E "SERVICE_PORT: \"$port_to_check\"|XRAY_API_PORT: \"$port_to_check\"" "$DOCKER_COMPOSE_FILE" >/dev/null
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

# --- Marzban-node Setup ---
setup_marzban_node() {
    log_info "Setting up Marzban-node..."

    if [ ! -d "$MARZBAN_NODE_DIR" ]; then
        log_info "Cloning Marzban-node repository..."
        git clone https://github.com/Gozargah/Marzban-node "$MARZBAN_NODE_DIR" || log_error "Failed to clone repository."
    else
        log_info "Marzban-node repository already exists. Updating it..."
        cd "$MARZBAN_NODE_DIR" && git pull || log_warning "Failed to update repository. Continuing..."
    fi

    if [ ! -d "$MARZBAN_NODE_LIB_DIR" ]; then
        log_info "Creating directory $MARZBAN_NODE_LIB_DIR..."
        sudo mkdir -p "$MARZBAN_NODE_LIB_DIR" || log_error "Failed to create directory."
    fi

    log_info "Marzban-node setup complete."
}

# --- Add New Node Service to existing docker-compose.yml ---
add_new_node_service() {
    log_info "Adding new Marzban Node service..."

    local new_service_name
    local service_port
    local api_port
    local client_cert_file

    read -p "Enter a unique name for the new node service (e.g., marzban-node-2): " new_service_name
    while grep -q "services:\s*$new_service_name:" "$DOCKER_COMPOSE_FILE" 2>/dev/null; do
        log_warning "Service name '$new_service_name' already exists in docker-compose.yml. Please choose a different name."
        read -p "Enter a unique name for the new node service: " new_service_name
    done

    read -p "Enter SERVICE_PORT for this new node: " service_port
    while [[ ! "$service_port" =~ ^[0-9]+$ ]] || [ "$service_port" -lt 1 ] || is_port_in_use "$service_port"; do
        if [[ ! "$service_port" =~ ^[0-9]+$ ]] || [ "$service_port" -lt 1 ]; then
            log_warning "Invalid port. Please enter a valid positive integer."
        else
            log_warning "Port '$service_port' is already in use by another service in docker-compose.yml. Please choose a different port."
        fi
        read -p "Enter SERVICE_PORT for this new node: " service_port
    done

    read -p "Enter XRAY_API_PORT for this new node: " api_port
    while [[ ! "$api_port" =~ ^[0-9]+$ ]] || [ "$api_port" -lt 1 ] || is_port_in_use "$api_port"; do
        if [[ ! "$api_port" =~ ^[0-9]+$ ]] || [ "$api_port" -lt 1 ]; then
            log_warning "Invalid port. Please enter a valid positive integer."
        else
            log_warning "Port '$api_port' is already in use by another service in docker-compose.yml. Please choose a different port."
        fi
        read -p "Enter XRAY_API_PORT for this new node: " api_port
    done

    client_cert_file="${MARZBAN_NODE_LIB_DIR}/ssl_client_cert_${new_service_name}.pem"
    log_info "Please paste the full SSL Client Certificate content for this new panel (from Marzban panel, 'Show Certificate' section). After pasting, press Ctrl+D:"
    
    # Read certificate content from stdin and save to file
    local cert_content
    cert_content=$(cat)
    echo "$cert_content" | sudo tee "$client_cert_file" >/dev/null || log_error "Failed to save certificate."
    sudo chmod 644 "$client_cert_file" || log_warning "Failed to change certificate permissions."
    log_info "Certificate saved to $client_cert_file."

    # Append new service to docker-compose.yml
    cat << EOF >> "$DOCKER_COMPOSE_FILE"

  $new_service_name:
    image: gozargah/marzban-node:latest
    restart: always
    network_mode: host
    environment:
      SSL_CLIENT_CERT_FILE: "$client_cert_file"
      SERVICE_PORT: "$service_port"
      XRAY_API_PORT: "$api_port"
      SERVICE_PROTOCOL: "rest"
    volumes:
      - $MARZBAN_NODE_LIB_DIR:/var/lib/marzban-node
      - /var/lib/marzban:/var/lib/marzban
EOF

    log_info "New service '$new_service_name' added to docker-compose.yml."
    log_info "Updated docker-compose.yml content:"
    cat "$DOCKER_COMPOSE_FILE"
}

# --- Main Logic ---
main() {
    log_info "Starting Marzban Node setup/addition script."
    
    check_prerequisites
    setup_marzban_node

    if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
        log_warning "docker-compose.yml not found. Creating initial setup for first node..."
        # Create initial dummy services: part that will be replaced by user input
        cat << EOF > "$DOCKER_COMPOSE_FILE"
services:
  dummy-node: # This will be replaced by the first actual node
    image: gozargah/marzban-node:latest
    restart: always
    network_mode: host
    environment:
      SERVICE_PORT: "1" # Dummy port
      XRAY_API_PORT: "2" # Dummy port
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/dummy_cert.pem"
      SERVICE_PROTOCOL: "rest"
    volumes:
      - /var/lib/marzban-node:/var/lib/marzban-node
      - /var/lib/marzban:/var/lib/marzban
EOF
        # Remove the dummy service later by replacing the file with only the new services
        # For simplicity of current request, we just append. User will be notified if dummy exists.
        log_warning "Initial docker-compose.yml created. Please run the script again to add your first real node."
        log_info "Run 'sudo rm $DOCKER_COMPOSE_FILE' if you want to start from scratch."
    fi

    add_new_node_service

    log_info "Applying Docker Compose changes..."
    cd "$MARZBAN_NODE_DIR" || log_error "Failed to enter Marzban-node directory."
    
    # Use --remove-orphans to clean up old services, like the initial 'marzban-node' or 'dummy-node'
    sudo docker compose down --remove-orphans || log_warning "Failed to stop/remove old containers. Continuing..."
    sudo docker compose pull || log_warning "Failed to pull Docker images. Continuing..."
    sudo docker compose up -d || log_error "Failed to start Docker Compose."

    log_info "Marzban Node(s) successfully deployed/updated."

    log_info "\n--- Next Steps for each Marzban Panel: ---"
    log_info "1. Go to your Marzban panel."
    log_info "2. Navigate to 'Node Settings'."
    log_info "3. Click on 'Add New Marzban Node' (for new panels)."
    log_info "4. In 'Name', choose a descriptive name for the node (e.g., 'Hetzner-Node-Panel2')."
    log_info "5. In 'Address', enter the Node server's IP address (this server)."
    log_info "6. Set 'Port' and 'API Port' exactly as you entered in this script."
    log_info "   Example: If you entered SERVICE_PORT as 61000 and XRAY_API_PORT as 60001, use these."
    log_info "7. Enable 'Add this node as a new host for every inbound' or manually configure in 'Host Settings'."
    log_info "8. Click 'Add Node' or 'Update Node'."
    log_info "9. **IMPORTANT:** Ensure that your Inbound Ports across different Marzban Panels do NOT conflict on this node."
    log_info "\nAll steps completed successfully."
}

# Execute main function
main
