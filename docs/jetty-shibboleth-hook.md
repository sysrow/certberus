# Certberus: Jetty / Shibboleth IdP post-issue hook

Guide for automatic LE/HARICA certificate deployment to Jetty (Shibboleth IdP)
via the certberus `certbot-only` module and a post-issue hook.

## How it works

1. `certberus auto --webserver certbot-only` obtains the cert via certbot
2. The post-issue hook automatically:
   - Converts PEM cert+key to PKCS12
   - Saves to `/opt/shibboleth-idp/credentials/idp-userfacing.p12`
   - Sets owner to `jetty`, permissions `600`
   - Restarts Jetty

## 1. Creating the hook

```bash
mkdir -p /etc/certberus/hooks/post-issue.d /etc/certberus/hooks/renewed.d

cat > /etc/certberus/hooks/post-issue.d/10-copy-to-jetty.sh << 'EOF'
#!/bin/bash
DOMAIN="${CA_PRIMARY_DOMAIN:-}"
[[ -z "$DOMAIN" ]] && exit 0

CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
P12="/opt/shibboleth-idp/credentials/idp-userfacing.p12"

[[ -f "$CERT" && -f "$KEY" ]] || exit 0

/usr/bin/openssl pkcs12 -export -passout pass: \
    -inkey "$KEY" \
    -in "$CERT" \
    -out "$P12"

chown jetty "$P12"
chmod 600 "$P12"

systemctl is-active --quiet jetty && systemctl restart jetty || true
EOF

chmod +x /etc/certberus/hooks/post-issue.d/10-copy-to-jetty.sh

# Copy for renewal (certbot renewal)
cp /etc/certberus/hooks/post-issue.d/10-copy-to-jetty.sh \
   /etc/certberus/hooks/renewed.d/10-copy-to-jetty.sh
```

## 2a. Issuing a cert - Let's Encrypt

```bash
# Staging (test):
certberus auto --webserver certbot-only \
    --domain shib.example.com \
    --email admin@example.com \
    --staging -y -v

# Production:
certberus auto --webserver certbot-only \
    --domain shib.example.com \
    --email admin@example.com \
    -y
```

## 2b. Issuing a cert - HARICA (CESNET TCS / EAB)

```bash
certberus auto --webserver certbot-only \
    --domain shib.example.com \
    --email admin@example.com \
    --ca harica \
    --eab-kid "YOUR_EAB_KID" \
    --eab-hmac "YOUR_EAB_HMAC_KEY" \
    --acme-url "https://acme-v02.harica.gr/acme/YOUR-ACCOUNT-UUID/directory" \
    -y
```

Concrete example (example.com):
```bash
certberus auto --webserver certbot-only \
    --domain example.com \
    --email admin@example.com \
    --ca harica \
    --eab-kid "YOUR_EAB_KID" \
    --eab-hmac "YOUR_EAB_HMAC_KEY" \
    --acme-url "https://acme-v02.harica.gr/acme/YOUR-ACCOUNT-UUID/directory" \
    -y
```

> **Note**: The domain must have an A record pointing to the server where certberus runs.
> HARICA validates the HTTP-01 challenge on port 80.

## 3. Verification

```bash
# Cert exists?
certberus cert-info shib.example.com

# PKCS12 created?
ls -la /opt/shibboleth-idp/credentials/idp-userfacing.p12
openssl pkcs12 -in /opt/shibboleth-idp/credentials/idp-userfacing.p12 \
    -passin pass: -nokeys | openssl x509 -noout -subject -issuer

# Hooks working?
certberus hooks list
```

## 4. Jetty configuration (start.d/ssl.ini)

Jetty must know about the PKCS12 file:

```ini
# /opt/shibboleth-idp/jetty-base/start.d/ssl.ini (or start.d/shibboleth.ini)
jetty.sslContext.keyStorePath=/opt/shibboleth-idp/credentials/idp-userfacing.p12
jetty.sslContext.keyStoreType=PKCS12
jetty.sslContext.keyStorePassword=
jetty.sslContext.keyManagerPassword=
```

## Variables available in the hook

The hook receives these environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `CA_EVENT` | Event type | `post-issue` |
| `CA_WEBSERVER` | Module | `certbot-only` |
| `CA_SOURCE` | Cert source | `certbot` |
| `CA_PRIMARY_DOMAIN` | Primary domain | `shib.example.com` |
| `CA_DOMAIN_LIST` | All domains | `shib.example.com alt.example.com` |
| `CA_CERT_PATH` | Cert path | `/etc/letsencrypt/live/.../fullchain.pem` |
| `CA_KEY_PATH` | Key path | `/etc/letsencrypt/live/.../privkey.pem` |
| `CA_CERT_ISSUER` | CA identifier | `letsencrypt` / `harica` |
| `CA_STAGING` | Staging mode | `0` / `1` |
| `CA_DRY_RUN` | Dry-run mode | `0` / `1` |
