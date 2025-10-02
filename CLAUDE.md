# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project deploys Dokploy (an open-source deployment platform) to Oracle Cloud Infrastructure (OCI) Free Tier using Terraform. It provisions a main instance running Dokploy and optional worker instances to form a Docker Swarm cluster.

## Architecture

- **Main instance**: Runs Dokploy dashboard (accessible on port 3000), Docker Swarm manager
- **Worker instances**: Join the Docker Swarm cluster as worker nodes (configurable via `num_worker_instances`)
- **Network**: VCN with 10.0.0.0/16 CIDR, subnet 10.0.0.0/24, internet gateway for public access
- **Bootstrap scripts**: Located in `bin/` directory
  - `dokploy-main.sh`: Installs Dokploy, configures SSH root access, sets up Docker Swarm firewall rules
  - `dokploy-worker.sh`: Configures worker node dependencies and firewall rules

## Prerequisites

Before deploying, you need:
1. **OCI CLI**: Install and configure OCI CLI with credentials
2. **Terraform**: Install Terraform CLI
3. **OCI Account**: Free tier account with compartment OCID
4. **SSH Keys**: Public SSH key for instance access
5. **Image OCID**: Ubuntu 22.04 image OCID for your region (see variables.tf:12)

## Required Variables

Must be provided during deployment (see `variables.tf`):
- `compartment_id`: OCI compartment OCID (find at: Profile → Tenancy → OCID)
- `ssh_authorized_keys`: SSH public key string (format: `ssh-rsa AAAA...`)
- `source_image_id`: Ubuntu 22.04 image OCID for your region
- `availability_domain_main`: Availability domain for main instance (e.g., `WBJv:EU-FRANKFURT-1-AD-1`)
- `availability_domain_workers`: Availability domain for worker instances

## Terraform Commands

```bash
# Initialize Terraform
terraform init

# Validate configuration
terraform validate

# Plan deployment (review changes)
terraform plan

# Apply infrastructure
terraform apply

# Destroy infrastructure
terraform destroy

# View outputs (shows IP addresses)
terraform output
```

## Deployment Process

1. Configure OCI CLI credentials (`oci setup config`)
2. Initialize Terraform (`terraform init`)
3. Create `terraform.tfvars` file with required variables
4. Plan and apply (`terraform plan && terraform apply`)
5. Access Dokploy dashboard at `http://<main_instance_ip>:3000`
6. Add worker nodes to cluster via Dokploy dashboard (see README.md sections on cluster setup)

## Free Tier Limits

- Maximum 4 instances total (1 main + 3 workers)
- Instance shape: `VM.Standard.A1.Flex` (ARM-based)
- Total resources: 24 GB RAM, 4 OCPUs across all instances
- Default configuration: 6 GB RAM, 1 OCPU per instance

## Network Security

Configured in `network.tf`:
- Port 22: SSH
- Port 80/443: HTTP/HTTPS
- Port 3000: Dokploy dashboard
- Port 81/444: Traefik proxy
- Ports 2376, 2377, 7946 (TCP/UDP), 4789 (UDP): Docker Swarm

## Local Configuration

- `locals.tf`: Centralizes instance configuration pulled from variables
- Instance config includes encryption, shape, source image, availability settings
- All instances share the same configuration from `local.instance_config`

## Post-Deployment

After successful deployment:
1. SSH to main instance using the private key pair
2. Access Dokploy dashboard at `http://<main_ip>:3000`
3. Generate SSH keys in Dokploy dashboard for server connections
4. Add worker instances to cluster via Dokploy UI (use root user, private IPs for internal networking)
