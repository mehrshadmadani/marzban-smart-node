import logging
import json
import requests
import sys
import os
import paramiko # Imported for SSH client, though main SSH part removed, Paramiko is in requirements.

# --- Configuration (These are now hardcoded values/defaults as per itsAML's curlscript) ---
# These values are what curlscript.py generally uses or expects
DEFAULT_SERVICE_PORT = 62050
DEFAULT_API_PORT = 62051
DEFAULT_NODE_NAME_SUFFIX = "github.com/itsAML" # Suffix for node name in Marzban Panel

# Configure logging
# Logs will go to stderr so they don't interfere with stdout output (like certificate)
logging.basicConfig(level=logging.INFO, stream=sys.stderr, format='[PY_LOG] %(levelname)s: %(message)s')

# Create a reusable session
session = requests.Session()

def get_access_token(domain, port, https, username, password):
    use_protocol = 'https' if https else 'http'
    # ItsAML's script uses /api/admin/token for login
    url = f'{use_protocol}://{domain}:{port}/api/admin/token' 
    data = {
        'username': username,
        'password': password
    }

    try:
        response = session.post(url, data=data, verify=False) # verify=False for self-signed certs
        response.raise_for_status()
        access_token = response.json()['access_token']
        logging.info(".:Logged in Successfully:.")
        return access_token
    except requests.exceptions.RequestException as e:
        logging.error(f'Error occurred while obtaining access token: {e}')
        return None

def get_cert(domain, port, https, access_token):
    use_protocol = 'https' if https else 'http'
    # ItsAML's script uses /api/node/settings for cert
    url = f'{use_protocol}://{domain}:{port}/api/node/settings' 
    headers = {
        'accept': 'application/json',
        'Authorization': f'Bearer {access_token}'
    }

    try:
        response = session.get(url, headers=headers, verify=False)
        response.raise_for_status()
        cert = response.json()
        return cert["certificate"]
    except requests.exceptions.RequestException as e:
        logging.error(f'Error occurred while retrieving certificate: {e}')
        return None

def add_node_to_panel(domain, port, https, access_token, node_name, node_address, service_port, api_port, add_as_new_host):
    use_protocol = 'https' if https else 'http'
    # ItsAML's script uses /api/node for adding node
    url = f'{use_protocol}://{domain}:{port}/api/node' 
    node_information = {
        "name": node_name, # Dynamic name from user input
        "address": node_address,
        "port": int(service_port),
        "api_port": int(api_port),
        "add_as_new_host": True if add_as_new_host else False,
        "usage_coefficient": 1
    }
    node_json_information = json.dumps(node_information)
    headers = {
        'accept': 'application/json',
        'Authorization': f'Bearer {access_token}',
        'Content-Type': 'application/json'
    }

    try:
        response = session.post(url, data=node_json_information, headers=headers, verify=False)
        response.raise_for_status()
        logging.info("Node Added Successfully to Panel.")
        return True
    except requests.exceptions.RequestException as e:
        logging.error(f'Error occurred while adding node to panel: {e}')
        return False

def run_ssh_commands_on_node(server_ip, server_port, server_user, server_password, cert_content):
    # This function will mimic the SSH commands that ItsAML's script originally ran
    # But we will use fixed paths relative to home directory for Marzban-node and cert.

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        logging.info(f"Connecting to node server {server_ip} via SSH...")
        client.connect(server_ip, port=int(server_port), username=server_user, password=server_password, timeout=10)
        logging.info("SSH connection established.")

        commands = [
            'sudo ufw disable', # Disable firewall (optional but common in scripts)
            'curl -fsSL https://get.docker.com | sh', # Install Docker
            f'[ -d {os.path.expanduser("~")}/Marzban-node ] && sudo rm -rf {os.path.expanduser("~")}/Marzban-node', # Remove old Marzban-node dir
            f'git clone https://github.com/Gozargah/Marzban-node {os.path.expanduser("~")}/Marzban-node', # Clone Marzban-node
            # The following command sequence in ItsAML's original script
            # cd Marzban-node && docker compose up -d && docker compose down && rm docker-compose.yml
            # is for initial setup. We will run it to ensure base image is pulled.
            f'cd {os.path.expanduser("~")}/Marzban-node && sudo docker compose up -d && sudo docker compose down',
            f'sudo rm -f {os.path.expanduser("~")}/Marzban-node/docker-compose.yml', # Remove the temp docker-compose.yml
            f'sudo mkdir -p /var/lib/marzban-node', # Ensure this directory exists on remote node
            f'sudo echo "{cert_content}" > /var/lib/marzban-node/ssl_client_cert.pem', # Save cert to fixed path
            # Recreate docker-compose.yml with a default single marzban-node service.
            # This will be overwritten/merged later by our main bash script if multiple nodes are needed.
            f'cd {os.path.expanduser("~")}/Marzban-node && sudo bash -c \'echo "services:\n  marzban-node:\n    image: gozargah/marzban-node:latest\n    restart: always\n    network_mode: host\n    environment:\n      SSL_CLIENT_CERT_FILE: \\"/var/lib/marzban-node/ssl_client_cert.pem\\"\n      SERVICE_PORT: \\"{DEFAULT_SERVICE_PORT}\\"\n      XRAY_API_PORT: \\"{DEFAULT_API_PORT}\\"\n    volumes:\n      - /var/lib/marzban-node:/var/lib/marzban-node\n      - /var/lib/marzban:/var/lib/marzban" > docker-compose.yml && sudo docker compose up -d\''
        ]

        for command in commands:
            logging.info(f"Executing SSH command: {command}")
            stdin, stdout, stderr = client.exec_command(command)
            stdout_output = stdout.read().decode('utf-8').strip()
            stderr_output = stderr.read().decode('utf-8').strip()
            exit_status = stdout.channel.recv_exit_status()

            if exit_status == 0:
                logging.info(f"Command executed successfully. Output: {stdout_output}")
            else:
                logging.error(f"Command failed with exit status {exit_status}. Error: {stderr_output}")
                raise Exception(f"SSH command failed: {command}")

    except paramiko.AuthenticationException:
        logging.error("SSH Authentication failed. Check username and password.")
        return False
    except paramiko.SSHException as e:
        logging.error(f"SSH connection failed: {e}. Check server IP and port.")
        return False
    except Exception as e:
        logging.error(f"Error during SSH command execution: {e}")
        return False
    finally:
        client.close()
        logging.info("SSH connection closed.")
    return True

# --- Main execution logic when smart_curlscript.py is run directly ---
if __name__ == "__main__":
    # Marzban Panel Information
    logging.info("\n--- Marzban Panel Information ---")
    DOMAIN_INPUT = input("Please Enter Your Marzban Domain/IP: ")
    PORT_INPUT = input("Please Enter Your Marzban Port: ")
    USERNAME_INPUT = input("Please Enter Your Marzban Username: ")
    PASSWORD_INPUT = input("Please Enter Your Marzban Password: ")

    HTTPS_INPUT = True
    while True:
        https_if_statment = input("Are You using HTTPS/SSL? (y/n): ").lower()
        if https_if_statment == "y":
            break
        elif https_if_statment == "n":
            HTTPS_INPUT = False
            break
        else:
            logging.warning("invalid value, try again...")

    ADD_AS_HOST_INPUT = True
    while True:
        host_if_statment = input("Do you Want To Add This Node as a New Host For Every Inbound (y/n): ").lower()
        if host_if_statment == "y":
            break
        elif host_if_statment == "n":
            ADD_AS_HOST_INPUT = False
            break
        else:
            logging.warning("invalid value, try again...")

    # Node Server Configuration (for SSH connection by this script)
    logging.info("\n--- Node Server Information (for SSH connection from this script) ---")
    SERVER_IP_INPUT = input("Please Enter Your Node Server Domain/IP (this server's IP): ")
    SERVER_PORT_INPUT = '22'
    while True:
        port_input = input("Please Enter Your Node Server SSH Port (Default : 22): ")
        if port_input == "":
            break
        else:
            SERVER_PORT_INPUT = port_input
            break
    SERVER_USER_INPUT = 'root'
    while True:
        user_input = input("Please Enter Your Node Server SSH User (Default : root): ")
        if user_input == "":
            break
        else:
            SERVER_USER_INPUT = user_input
            break
    SERVER_PASSWORD_INPUT = input("Please Enter Your Node Server SSH password: ")

    # --- Node details for Marzban Panel (for adding node via API) ---
    logging.info("\n--- Node Details for Marzban Panel ---")
    NODE_SERVICE_NAME = input("Enter a UNIQUE name for this node service in Docker/Marzban Panel (e.g., my-new-node): ")
    NODE_DISPLAY_ADDRESS = input(f"Enter Node's Address for Marzban Panel (this node's public IP/domain, e.g., {SERVER_IP_INPUT}): ") or SERVER_IP_INPUT

    AUTO_ASSIGN_PORTS = input("Do you want to auto-assign SERVICE_PORT and XRAY_API_PORT (y/n)? (e.g., 62050, 62051): ").lower()
    if AUTO_ASSIGN_PORTS == 'y':
        NODE_SERVICE_PORT = DEFAULT_SERVICE_PORT # Use fixed defaults for now, as finding free ports is complex here
        NODE_API_PORT = DEFAULT_API_PORT
        logging.info(f"Auto-assigned SERVICE_PORT: {NODE_SERVICE_PORT}, API_PORT: {NODE_API_PORT}")
    else:
        NODE_SERVICE_PORT = input("Enter SERVICE_PORT for this node: ")
        NODE_API_PORT = input("Enter XRAY_API_PORT for this node: ")

    # Get access token
    access_token = get_access_token(DOMAIN_INPUT, PORT_INPUT, HTTPS_INPUT, USERNAME_INPUT, PASSWORD_INPUT)
    if not access_token:
        sys.exit(1)

    # Get client certificate
    cert_content = get_cert(DOMAIN_INPUT, PORT_INPUT, HTTPS_INPUT, access_token)
    if not cert_content:
        sys.exit(1)

    # Add node to panel
    if not add_node_to_panel(DOMAIN_INPUT, PORT_INPUT, HTTPS_INPUT, access_token, NODE_SERVICE_NAME, NODE_DISPLAY_ADDRESS, NODE_SERVICE_PORT, NODE_API_PORT, ADD_AS_HOST_INPUT):
        sys.exit(1)

    # Run SSH commands on the node server to set up Marzban-node
    if not run_ssh_commands_on_node(SERVER_IP_INPUT, SERVER_PORT_INPUT, SERVER_USER_INPUT, SERVER_PASSWORD_INPUT, cert_content):
        sys.exit(1)

    logging.info("Node setup and panel addition completed successfully.")
    logging.info("Please verify the node status in your Marzban panel.")
    logging.info("Remember to manually combine services in docker-compose.yml if you have multiple nodes.")
