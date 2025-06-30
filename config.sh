#!/bin/bash

# --- Marzban Panel Information ---
# !!! IMPORTANT: Replace these with your actual Marzban Panel details !!!
PANEL_DOMAIN="subvip.alitorkevip.ir" # e.g., your-panel.com or 1.2.3.4
PANEL_PORT="443"                      # e.g., 80, 443, 2003
USE_HTTPS="true"                      # Set to "true" for HTTPS, "false" for HTTP
PANEL_USERNAME="all"                  # Your Marzban Panel Username
PANEL_PASSWORD="all"                  # Your Marzban Panel Password

# --- New Node Service Details ---
# These settings will be used for the new node service added to Docker Compose
NODE_SERVICE_NAME="new-marzban-node"  # A unique name for this node service in Docker (e.g., my-new-node-panel1)

# Auto-assign ports: Set to "true" to let the script find free ports, "false" to specify manually below.
AUTO_ASSIGN_PORTS="true" 
# If AUTO_ASSIGN_PORTS is "false", set your desired ports here:
MANUAL_SERVICE_PORT="61000"           # Example: 61000
MANUAL_API_PORT="61001"               # Example: 61001

# --- Node Address for Marzban Panel ---
# This is how the node will appear in the Marzban Panel's "Address" field.
# Leave empty to auto-detect public IP, or specify a domain (e.g., node.yourdomain.com).
NODE_DISPLAY_ADDRESS=""               # e.g., 178.128.41.153 or node.yourdomain.com (Leave empty for auto-detect)

# --- Add Node as new Host ---
# Set to "true" to add this node's address as a new host for every inbound in Marzban Panel, "false" otherwise.
ADD_AS_NEW_HOST="true"
