#!/bin/bash

# --- Configuration ---
MARZBAN_NODE_DIR="$HOME/Marzban-node"
MARZBAN_NODE_LIB_DIR="/var/lib/marzban-node"
DOCKER_COMPOSE_FILE="$MARZBAN_NODE_DIR/docker-compose.yml"
ITSAML_PYTHON_SCRIPT_URL="https://raw.githubusercontent.com/ItsAML/MarzbanEZNode/main/curlscript.py"
ITSAML_PYTHON_SCRIPT_NAME="itsaml_curlscript_manual.py" # Unique name for clarity

# --- Helper Functions (Finglish) ---
log_info() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

log_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1"
}

log_error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
    # Do NOT exit 1 here, let the main function decide if it's fatal
}

# --- Prerequisites Check (simplified, as ItsAML's script also installs them) ---
check_minimal_prerequisites() {
    log_info "Checking minimal prerequisites (curl, git, python3, pip3)..."
    command -v curl >/dev/null || { sudo apt-get update && sudo apt-get install -y curl || log_error "Failed to install curl."; }
    command -v git >/dev/null || { sudo apt-get update && sudo apt-get install -y git || log_error "Failed to install git."; }
    command -v python3 >/dev/null || { sudo apt-get update && sudo apt-get install -y python3 || log_error "Failed to install python3."; }
    command -v pip3 >/dev/null || { sudo apt-get update && sudo apt-get install -y python3-pip || log_error "Failed to install pip3."; }
    # Ensure requests and paramiko are installed for curlscript.py
    if ! python3 -c "import requests" &> /dev/null; then
        log_info "Python 'requests' library not found. Installing..."
        pip3 install requests --break-system-packages || log_error "Failed to install 'requests' library."
    fi
    if ! python3 -c "import paramiko" &> /dev/null; then
        log_info "Python 'paramiko' library not found. Installing..."
        pip3 install paramiko --break-system-packages || log_error "Failed to install 'paramiko' library."
    fi
    log_info "Minimal prerequisites are checked."
}

# --- Main Execution Flow ---
main() {
    log_info "Starting Marzban Node setup and addition (Semi-Automated Guide)."
    log_info "This script will guide you through using ItsAML's curlscript.py."
    log_warning "Please read the prompts carefully and enter required information manually."
    
    check_minimal_prerequisites
    
    log_info "\n--- Step 1: Prepare Marzban-node Base ---"
    log_info "Cloning/Updating Marzban-node repository and creating necessary directories."
    if [ ! -d "$MARZBAN_NODE_DIR" ]; then
        git clone https://github.com/Gozargah/Marzban-node "$MARZBAN_NODE_DIR" || log_error "Failed to clone repository."
    else
        cd "$MARZBAN_NODE_DIR" && git pull || log_warning "Failed to update repository. Continuing..."
    fi
    sudo mkdir -p "$MARZBAN_NODE_LIB_DIR" || log_error "Failed to create /var/lib/marzban-node directory."
    log_info "Marzban-node base setup complete."

    log_info "\n--- Step 2: Run ItsAML's curlscript.py ---"
    log_info "This script will interactively ask for your Marzban Panel and Node details."
    log_info "It will install Docker/Docker Compose (if not present), configure ONE Marzban Node service, and add it to your panel."
    log_warning "This will OVERWRITE your current docker-compose.yml with a single node service."
    
    log_info "Downloading ItsAML's curlscript.py..."
    curl -sSL "$ITSAML_PYTHON_SCRIPT_URL" > "$MARZBAN_NODE_DIR/$ITSAML_PYTHON_SCRIPT_NAME" || log_error "Failed to download curlscript.py."
    chmod +x "$MARZBAN_NODE_DIR/$ITSAML_PYTHON_SCRIPT_NAME" || log_error "Failed to make curlscript.py executable."
    
    log_info "\nNow, executing ItsAML's curlscript.py. Please answer its questions directly (in English):"
    log_info "----------------------------------------------------------------------"
    cd "$MARZBAN_NODE_DIR" # Change to Marzban-node directory for script execution
    python3 "$ITSAML_PYTHON_SCRIPT_NAME"
    local curlscript_exit_code=$?
    log_info "----------------------------------------------------------------------"
    
    if [ "$curlscript_exit_code" -ne 0 ]; then
        log_error "ItsAML's curlscript.py failed. Please check its output above and try again."
    fi

    log_info "\n--- Step 3: Verify Node in Panel ---"
    log_info "Your new node should now be added to your Marzban Panel."
    log_info "Go to your Marzban Panel -> Node Settings to confirm its status (should be Green)."
    
    log_info "\n--- Step 4: Manually Combine docker-compose.yml (if adding more nodes) ---"
    log_warning "Remember: ItsAML's script installed only ONE node. If you have other nodes/panels to add to this server, you MUST manually edit your docker-compose.yml."
    log_info "Current docker-compose.yml content (after ItsAML's script):"
    cat "$DOCKER_COMPOSE_FILE"
    
    log_info "\nTo add MORE nodes, you need to manually edit $DOCKER_COMPOSE_FILE:"
    log_info "1. Use 'nano $DOCKER_COMPOSE_FILE' to open the file."
    log_info "2. Copy/paste the service blocks for your other nodes (e.g., marzban-node-2, marzban-node-3) below the existing one."
    log_info "3. Ensure each service has a UNIQUE name (e.g., 'marzban-node-panel1', 'marzban-node-panel2')."
    log_info "4. Make sure 'SERVICE_PORT' and 'XRAY_API_PORT' for each node are UNIQUE and NOT in use by other services on your server."
    log_info "5. Ensure the 'SSL_CLIENT_CERT_FILE' path points to the correct certificate file for each panel (e.g., /var/lib/marzban-node/ssl_client_cert_PANEL2_NAME.pem)."
    log_info "   You will need to manually get certificates for additional panels and save them to /var/lib/marzban-node/ssl_client_cert_YOUR_NODE_NAME.pem."
    log_info "6. Save changes in nano (Ctrl+X, Y, Enter)."

    log_info "\n--- Step 5: Apply Docker Compose Changes ---"
    log_info "After manually editing $DOCKER_COMPOSE_FILE (if needed), run these commands:"
    log_info "cd $MARZBAN_NODE_DIR"
    log_info "sudo docker compose down --remove-orphans"
    log_info "sudo docker compose pull"
    log_info "sudo docker compose up -d"

    log_info "\n--- All steps completed. Please verify your nodes in Marzban Panel. ---"
}

# Execute main function
main
