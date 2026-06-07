# Reverse Proxy Setup (HTTPS)

Both `minecraft-api-server` (default port 3000) and `minecraft-server-manager` (default port 3001) should be served behind a TLS-terminating reverse proxy in production.

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

# Web manager
server {
    listen 443 ssl http2;
    server_name mc-manager.example.com;

    ssl_certificate     /etc/letsencrypt/live/mc-manager.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mc-manager.example.com/privkey.pem;

    location / {
        proxy_pass            http://127.0.0.1:3001;
        proxy_set_header      Host $host;
        proxy_set_header      X-Real-IP $remote_addr;
        # WebSocket support for the terminal
        proxy_http_version    1.1;
        proxy_set_header      Upgrade $http_upgrade;
        proxy_set_header      Connection "upgrade";
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

mc-manager.example.com {
    reverse_proxy localhost:3001
}
```

## Obtaining a certificate

```bash
certbot --nginx -d mc-api.example.com -d mc-manager.example.com
```
