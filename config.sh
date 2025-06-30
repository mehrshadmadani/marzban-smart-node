#!/bin/bash

# --- Marzban Panel Information ---
# These are default values. The main script will prompt for these inputs.
DEFAULT_PANEL_DOMAIN="your-default-panel.com" # e.g., your-panel.com or 1.2.3.4
DEFAULT_PANEL_PORT="443"                      # e.g., 80, 443, 2003
DEFAULT_USE_HTTPS="true"                      # "true" for HTTPS, "false" for HTTP
DEFAULT_PANEL_USERNAME="admin"                # Your Marzban Panel Username
DEFAULT_PANEL_PASSWORD="your-admin-password"  # Your Marzban Panel Password

# --- New Node Service Details ---
# These are default values for the new node service added to Docker Compose
DEFAULT_NODE_SERVICE_NAME="marzban-node-1"  # A unique default name for this node service in Docker

# Default for auto-assigning ports: "true" to let the script find free ports, "false" to specify manually.
DEFAULT_AUTO_ASSIGN_PORTS="true" 
# Default manual ports (if AUTO_ASSIGN_PORTS is "false"):
DEFAULT_MANUAL_SERVICE_PORT="61000"           
DEFAULT_MANUAL_API_PORT="61001"               

# --- Node Address for Marzban Panel ---
# Default for how the node will appear in the Marzban Panel's "Address" field.
# Leave empty for auto-detect public IP, or specify a domain.
DEFAULT_NODE_DISPLAY_ADDRESS=""               # e.g., 178.128.41.153 or node.yourdomain.com (Leave empty for auto-detect)

# --- Add Node as new Host ---
# Default to "true" to add this node's address as a new host for every inbound in Marzban Panel.
DEFAULT_ADD_AS_NEW_HOST="true"
