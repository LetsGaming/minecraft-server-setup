# Reverse Proxy Setup (HTTPS)

`mc-api-server` should be served behind a TLS-terminating reverse proxy whenever the bot reaches it over a network you do not trust. It runs scripts and reads files on this host and is authenticated by a single API key, so plaintext on an untrusted network hands that key to anyone on the path.

The examples use port `3030`, the `API_SERVER.PORT` in `variables.example.json`; use yours. With a proxy in front, make the wrapper listen on loopback only, so the plain-HTTP port is not reachable from outside: add `Environment="MC_BIND_HOST=127.0.0.1"` and `Environment="MC_TRUST_PROXY=true"` to its unit (`sudo systemctl edit <install>-api-server`), or close the port in your firewall.

> The bundled web interface (`minecraft-server-manager`, port 3001) was retired and no longer needs a vhost. If you still have one configured, remove it — see [retiring-web-interface.md](retiring-web-interface.md).

## nginx example

```nginx
# /etc/nginx/sites-available/minecraft

# Redirect HTTP → HTTPS
server {
    listen 80;
    server_name mc-api.example.com;
    return 301 https://$host$request_uri;
}

# API server
server {
    listen 443 ssl http2;
    server_name mc-api.example.com;

    ssl_certificate     /etc/letsencrypt/live/mc-api.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mc-api.example.com/privkey.pem;

    location / {
        proxy_pass         http://127.0.0.1:3030;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $remote_addr;  # set, not appended: the wrapper trusts this header
        proxy_read_timeout 3600s;  # required for SSE /logs/stream
        proxy_buffering    off;    # required for SSE
    }
}

```

## Caddy example (automatic HTTPS)

```
mc-api.example.com {
    reverse_proxy localhost:3030 {
        flush_interval -1  # required for SSE
    }
}

```

## Obtaining a certificate

```bash
certbot --nginx -d mc-api.example.com
```
