#!/usr/bin/env bash
# Self-signed HTTPS cert so phones on the same Wi-Fi can use the camera (https://<laptop-ip>:8443).
# Phones will show a certificate warning once; tap through it ("Show Details" → "visit this website").
set -euo pipefail
cd "$(dirname "$0")/.."
IP="${1:-$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')}"
mkdir -p certs
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout certs/key.pem -out certs/cert.pem \
  -subj "/CN=swarm-sight" \
  -addext "subjectAltName=IP:${IP},IP:127.0.0.1,DNS:localhost"
echo "Wrote certs/cert.pem and certs/key.pem for ${IP}"
