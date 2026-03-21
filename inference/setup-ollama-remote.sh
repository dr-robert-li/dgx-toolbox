#!/usr/bin/env bash
# Reconfigure Ollama to listen on all interfaces (for NVIDIA Sync / LAN access)
# Requires sudo — adds OLLAMA_HOST=0.0.0.0 to the systemd service
set -e

SERVICE_FILE="/etc/systemd/system/ollama.service"

if ! [ -f "$SERVICE_FILE" ]; then
    echo "Ollama systemd service not found at $SERVICE_FILE"
    exit 1
fi

# Check if already configured
if grep -q "OLLAMA_HOST=0.0.0.0" "$SERVICE_FILE" 2>/dev/null; then
    echo "Ollama is already configured for remote access (OLLAMA_HOST=0.0.0.0)"
    echo "Listening on port 11434 on all interfaces."
    exit 0
fi

echo "This will reconfigure Ollama to listen on all interfaces (0.0.0.0:11434)."
echo "Requires sudo."
echo ""

# Create override directory
sudo mkdir -p /etc/systemd/system/ollama.service.d

# Add environment override (non-destructive — doesn't modify the original service file)
sudo tee /etc/systemd/system/ollama.service.d/remote.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
EOF

sudo systemctl daemon-reload
sudo systemctl restart ollama

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "========================================"
echo " Ollama Remote Access Enabled"
echo " Local:  http://localhost:11434"
echo " LAN:    http://${IP}:11434"
echo "========================================"
echo ""
echo "To revert: sudo rm /etc/systemd/system/ollama.service.d/remote.conf && sudo systemctl daemon-reload && sudo systemctl restart ollama"
