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
        log_py("Usage: python smart_api_handler.py <domain> <port> <https_bool> <username> <password> <node_name> <node_address> <service_port> <api_port> <add_as_new_host_bool_str>")
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
