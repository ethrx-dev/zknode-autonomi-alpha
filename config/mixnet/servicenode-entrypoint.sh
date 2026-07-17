#!/bin/sh
if [ -f /var/lib/katzenpost/servicenode1/http-proxy-server ] && [ ! -f /usr/local/bin/http-proxy-server.bin ]; then
  cp /var/lib/katzenpost/servicenode1/http-proxy-server /usr/local/bin/http-proxy-server.bin
  chmod +x /usr/local/bin/http-proxy-server.bin
fi
if [ ! -f /usr/local/bin/http-proxy-server ]; then
  cat > /usr/local/bin/http-proxy-server << 'WRAP'
#!/bin/sh
exec /usr/local/bin/http-proxy-server.bin -log_dir /var/lib/katzenpost/servicenode1 -log_level DEBUG "$@"
WRAP
  chmod +x /usr/local/bin/http-proxy-server
fi
exec /usr/local/bin/server -f /var/lib/katzenpost/servicenode1/katzenpost.toml
