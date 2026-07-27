#!/bin/sh
# Clean up any existing http-proxy-server files to avoid confusion
rm -f /usr/local/bin/http-proxy-server*

# First priority: http-proxy-server binary already exists
if [ -f /usr/local/bin/http-proxy-server ]; then
  echo "http-proxy-server already exists, using it"
elif [ -f /var/lib/katzenpost/servicenode1/http-proxy-server.bin ]; then
  cp -f /var/lib/katzenpost/servicenode1/http-proxy-server.bin /usr/local/bin/http-proxy-server
  chmod +x /usr/local/bin/http-proxy-server
  echo "Copied http-proxy-server from data directory"
elif [ -f /var/lib/katzenpost/servicenode1/http-proxy-server ]; then
  if od -N5 -t x1 /var/lib/katzenpost/servicenode1/http-proxy-server 2>/dev/null | grep -q "7f 45 4c 46"; then
    cp -f /var/lib/katzenpost/servicenode1/http-proxy-server /usr/local/bin/http-proxy-server
    chmod +x /usr/local/bin/http-proxy-server
    echo "Copied http-proxy-server binary from data directory"
  else
    echo "ERROR: http-proxy-server is not a binary executable in data directory" >&2
    exit 1
  fi
else
  echo "ERROR: http-proxy-server not found in any location" >&2
  exit 1
fi

# Create chatd stub if it doesn't exist
if [ ! -f /usr/local/bin/chatd ]; then
  cat > /usr/local/bin/chatd << 'CHATDUM'
#!/bin/sh
echo "chatd stub: sleeping..."
while true; do sleep 3600; done
CHATDUM
  chmod +x /usr/local/bin/chatd
fi

exec /usr/local/bin/server -f /var/lib/katzenpost/servicenode1/katzenpost.toml
