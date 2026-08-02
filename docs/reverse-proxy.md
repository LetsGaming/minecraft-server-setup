# Reverse Proxy Setup (HTTPS)

`minecraft-api-server` (default port 3000) should be served behind a TLS-terminating reverse proxy in production. It runs scripts and reads files on this host and is authenticated by a single API key, so plaintext on an untrusted network hands that key to anyone on the path.

> The bundled web interface (`minecraft-server-manager`, port 3001) was retired and no longer needs a vhost. If you still have one configured, remove it — see [retiring-web-interface.md](retiring-web-interface.md).

## nginx example

```nginx
# /etc/nginx/sites-available/minecraft

# Redirect HTTP → HTTPS
server {
    listen 80;
    server_name mc.example.com;
    return 301 https://$host$request_uri;
}

# API server
server {
    listen 443 ssl http2;
    server_name mc-api.example.com;

    ssl_certificate     /etc/letsencrypt/live/mc-api.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mc-api.example.com/privkey.pem;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_read_timeout 3600s;  # required for SSE /logs/stream
        proxy_buffering    off;    # required for SSE
    }
}

```

## Caddy example (automatic HTTPS)

```
mc-api.example.com {
    reverse_proxy localhost:3000 {
        flush_interval -1  # required for SSE
    }
}

```

## Obtaining a certificate

```bash
certbot --nginx -d mc-api.example.com
```
