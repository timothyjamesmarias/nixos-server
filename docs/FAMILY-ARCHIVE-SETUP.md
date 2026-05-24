# Family Archive — First-Time Setup

Step-by-step runbook for deploying the family-archive app. Do these in order.

## 1. Cloudflare — Domain Setup

Add `mariasfamilyarchive.com` to Cloudflare and configure DNS.

1. Log into Cloudflare > Add a site > `mariasfamilyarchive.com`
2. Select the Free plan
3. Update the domain's nameservers at your registrar to the ones Cloudflare gives you
4. Wait for nameserver propagation (can take up to 24 hours, usually minutes)
5. Create DNS records:
   - **A record**: `mariasfamilyarchive.com` → `192.168.1.7` (Proxied / orange cloud)
   - **A record**: `www.mariasfamilyarchive.com` → `192.168.1.7` (Proxied) — optional, for www redirect
6. Set SSL/TLS mode to **Full (strict)**

### Cloudflare API Token

Your existing Cloudflare API token needs DNS edit permissions for this new zone. If it's scoped to `timothymarias.com` only, you'll need to update it:

1. Go to Cloudflare > My Profile > API Tokens
2. Edit your existing token
3. Under Zone Resources, add `mariasfamilyarchive.com` (or change to "All zones")
4. Save

The DDNS updater in `cloudflare-ddns.nix` will also need to know about this zone if you want automatic IP updates for it.

## 2. Cloudflare — Origin CA Certificate

Generate an origin certificate so Traefik can terminate TLS from Cloudflare.

1. In Cloudflare, go to `mariasfamilyarchive.com` > SSL/TLS > Origin Server
2. Click "Create Certificate"
3. Let Cloudflare generate a private key (RSA or ECDSA)
4. Hostnames: `mariasfamilyarchive.com`, `*.mariasfamilyarchive.com`
5. Validity: 15 years (default)
6. Click Create
7. **Copy the certificate (PEM)** — you'll need this for secrets
8. **Copy the private key** — you'll need this for secrets
9. You cannot retrieve the private key later, so save it now

## 3. AWS — S3 Bucket and IAM User

Create a dedicated S3 bucket and scoped IAM credentials.

### Create the bucket

1. Go to AWS Console > S3 > Create bucket
2. Bucket name: something like `marias-family-archive` (globally unique)
3. Region: pick one close to your server (e.g., `us-east-1`)
4. Block all public access: **leave enabled** (the app generates signed URLs or serves through itself)
5. Create bucket

If the app needs public read access for images (it generates public S3 URLs via `GenerateURL()`), you'll need to either:
- Unblock public access and add a bucket policy allowing `s3:GetObject` on `arn:aws:s3:::BUCKET_NAME/*`
- Or set up CloudFront in front of the bucket

Since `GenerateURL()` returns `https://BUCKET.s3.REGION.amazonaws.com/PATH`, the objects need to be publicly readable. Add this bucket policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }
  ]
}
```

And uncheck "Block all public access" for the bucket.

### Create IAM user

1. Go to IAM > Users > Create user
2. Name: `family-archive-s3`
3. No console access needed
4. Attach an inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:HeadObject"
      ],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }
  ]
}
```

5. Create the user, then create an access key (use case: "Application running outside AWS")
6. Save the Access Key ID and Secret Access Key — you'll need them for secrets

## 4. Secrets — sops-nix

Add all secrets to the encrypted secrets file.

```bash
cd ~/projects/nixos-server
sops secrets/secrets.yaml
```

Add these entries:

```yaml
# Origin CA certificate for mariasfamilyarchive.com
origin-cert-pem-familyarchive: |
    -----BEGIN CERTIFICATE-----
    <paste the certificate from step 2>
    -----END CERTIFICATE-----
origin-cert-key-familyarchive: |
    -----BEGIN PRIVATE KEY-----
    <paste the private key from step 2>
    -----END PRIVATE KEY-----

# Family Archive app secrets
family-archive:
    session-secret: <generate: openssl rand -hex 32>
    admin-email: <your email address>
    admin-password: <your admin password>
    database-password: <generate: openssl rand -hex 16>
    s3-bucket: <bucket name from step 3>
    s3-region: <e.g., us-east-1>
    aws-access-key-id: <from step 3>
    aws-secret-access-key: <from step 3>
```

Save and close — sops encrypts automatically.

## 5. Database — Set User Password

NixOS `ensureDatabases` and `ensureUsers` will create the database and user, but you need to set the password manually (NixOS doesn't manage postgres passwords declaratively).

After the first `nixos-rebuild switch` that includes the family-archive config:

```bash
# On the server
sudo -u postgres psql -c "ALTER USER family_archive WITH PASSWORD '<same password from sops>';"
```

The password must match what you put in `family-archive/database-password` in secrets.yaml, because the env file generator constructs the `DATABASE_URL` with it.

## 6. GitHub — CI Deploy Key

Generate an SSH key pair for GitHub Actions to use when deploying.

```bash
# On your local machine
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/github_actions_deploy -N ""
```

Add the **public key** to the deploy user's authorized keys in `modules/base.nix`:

```nix
users.users.deploy = {
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3... timmarias@Tims-MacBook-Pro.local"
    "ssh-ed25519 AAAAC3... github-actions-deploy"  # <-- add this
  ];
};
```

Add the **private key** as a GitHub repo secret:

1. Go to familyArchive repo > Settings > Secrets and variables > Actions
2. Add these repository secrets:
   - `SERVER_SSH_KEY`: paste the contents of `~/.ssh/github_actions_deploy`
   - `SERVER_HOST`: your server's public IP (or DDNS hostname if you have one)
   - `SERVER_USER`: `deploy`

## 7. Deploy

With all the above in place:

```bash
# On your local machine, push the nixos-server changes
cd ~/projects/nixos-server
git add -A && git commit -m "feat: add family-archive app"
git push

# SSH into the server and apply
ssh deploy@<server-ip>
cd ~/nixos-server
git pull
sudo nixos-rebuild switch --flake ~/nixos-server#server
```

Then set the database password (step 5 above).

For the first app deployment, you can either:
- Create a GitHub release on familyArchive (triggers the full pipeline), or
- Build and push the image manually, then run `deploy.sh`:

```bash
# Manual first deploy (from your local machine)
docker build -t ghcr.io/timothyjamesmarias/family-archive:v0.1.0 .
docker push ghcr.io/timothyjamesmarias/family-archive:v0.1.0

# Get the digest
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/timothyjamesmarias/family-archive:v0.1.0 | cut -d@ -f2

# On the server
./scripts/deploy.sh family-archive sha256:<digest>
```

## 8. Verify

```bash
# On the server — check container is running and healthy
docker ps --filter name=family-archive

# Check logs for migration output
docker logs family-archive 2>&1 | head -20

# From anywhere — test the endpoint
curl -I https://mariasfamilyarchive.com/
```

You should see a 200 response. Log in at `https://mariasfamilyarchive.com/login` with the admin email and password from your secrets.

## Troubleshooting

### Container won't start
```bash
# Check systemd service status
sudo systemctl status docker-family-archive

# Check if env file was generated
sudo cat /run/family-archive/env

# Check if sops secrets were decrypted
sudo ls -la /run/secrets/family-archive/
```

### Database connection refused
```bash
# Verify PgBouncer is listening on the Docker bridge
ss -tlnp | grep 6432

# Test from inside the container
docker exec family-archive sh -c 'wget -qO- http://localhost:8080/ || echo "app not responding"'

# Check pg_hba.conf allows the Docker subnet
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE database::text LIKE '%family%';"
```

### S3 upload failures
- Verify the bucket exists and the region matches
- Verify the IAM credentials are correct: `aws s3 ls s3://BUCKET_NAME/ --region REGION`
- The container needs internet access — verify it's on `proxy-net` (not an internal network)

### TLS / certificate errors
- Verify Cloudflare SSL/TLS is set to "Full (strict)"
- Verify the origin cert covers `mariasfamilyarchive.com`
- Check Traefik logs: `docker logs traefik 2>&1 | grep -i cert`
