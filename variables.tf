variable "ssh_authorized_keys" {
  description = "SSH public key for instances. For example: ssh-rsa AAEAAAA....3R ssh-key-2024-09-03"
  type        = string
}

variable "compartment_id" {
  description = "The OCID of the compartment. Find it: Profile → Tenancy: youruser → Tenancy information → OCID https://cloud.oracle.com/tenancy"
  type        = string
}

variable "source_image_id" {
  description = "Source Ubuntu 22.04 image OCID. Find the right one for your region: https://docs.oracle.com/en-us/iaas/images/image/128dbc42-65a9-4ed0-a2db-be7aa584c726/index.htm"
  type        = string
}

variable "num_worker_instances" {
  description = "LEGACY (superseded by worker_node_ids): no longer referenced. Kept declared so existing tfvars that set it don't error."
  type        = number
  default     = 1
}

variable "worker_node_ids" {
  description = "Stable IDs for the worker nodes. Each becomes display name dokploy-worker-<id>, DNS oci-w<id>, and is AD-placed by ads.tf via local.worker_ad[<id>]. PAYG accounts are exempt from the Always-Free ARM cut, so the full 4 OCPU / 24 GB / 200 GB A1 allotment is in use: 1 main + 3 workers ['1','2','3'], each at 1 OCPU / 6 GB / 50 GB. Worker '3' hosts the self-hosted agentplane Postgres (10.0.0.244)."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "availability_domain_main" {
  description = "Availability domain for dokploy-main instance. Find it Core Infrastructure → Compute → Instances → Availability domain (left menu). For example: WBJv:EU-FRANKFURT-1-AD-1"
  type        = string
}

variable "availability_domain_workers" {
  description = "Availability domain for dokploy-main instance. Find it Core Infrastructure → Compute → Instances → Availability domain (left menu). For example: WBJv:EU-FRANKFURT-1-AD-2"
  type        = string
}

variable "instance_shape" {
  description = "The shape of the instance. VM.Standard.A1.Flex is free tier eligible."
  type        = string
  default     = "VM.Standard.A1.Flex" # OCI Free
}

variable "memory_in_gbs" {
  description = "Memory in GBs for instance shape config. 6 GB is the maximum for free tier with 3 working nodes."
  type        = string
  default     = "6" # OCI Free
}

# Per-node override for the DB worker (worker-3): the shared Postgres serves the
# whole fleet and is CPU/RAM-bound on 1 OCPU, so it gets a bigger slice while a
# web worker is dropped (num_web_backends 3->2). The tenancy total stays within
# the PAYG Always-Free A1 pool (4 OCPU / 24 GB): main 1/6 + w1 1/6 + w3 2/12.
variable "db_worker_id" {
  description = "worker_node_ids entry that hosts the shared Postgres and gets the larger shape. Empty = all workers use the default shape."
  type        = string
  default     = "3"
}

variable "db_ocpus" {
  description = "OCPUs for the DB worker. Keep tenancy total <= 4 OCPU (PAYG A1 free pool)."
  type        = string
  default     = "2"
}

variable "db_memory_in_gbs" {
  description = "Memory (GB) for the DB worker. Keep tenancy total <= 24 GB (PAYG A1 free pool)."
  type        = string
  default     = "12"
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size per instance. 50 is the OCI minimum; 4 nodes x 50 GB = 200 GB = the full Always-Free block-storage allotment. Do not raise without reducing node count."
  type        = number
  default     = 50 # OCI Free: 200 GB total / 4 nodes
}

variable "komodo_core_public_key" {
  description = "Public key of the Komodo Core that manages these nodes (the PERIPHERY_CORE_PUBLIC_KEY value from the Core host, e.g. /opt/komodo/compose.env). Each node's Periphery trusts requests signed by this key (passkey-less auth). Set in terraform.tfvars; not committed."
  type        = string
}

variable "doppelops_zone" {
  description = "Cloudflare zone for the app fleet. doppelops.com apex = fleet; apps live on <app>.doppelops.com subdomains."
  type        = string
  default     = "doppelops.com"
}

variable "agentplane_subdomain" {
  description = "Subdomain under doppelops_zone for the agentplane public resolver (points at the NLB, CF-proxied)."
  type        = string
  default     = "agentplane"
}

variable "oci_auth" {
  description = "OCI provider auth method. 'ApiKey' (default) reads ~/.oci/config API key; set 'SecurityToken' to use a session token from `oci session authenticate`."
  type        = string
  default     = "ApiKey"
}

variable "oci_config_profile" {
  description = "OCI config profile name in ~/.oci/config."
  type        = string
  default     = "DEFAULT"
}

variable "oci_region" {
  description = "OCI region. Required when oci_auth = SecurityToken."
  type        = string
  default     = "us-chicago-1"
}

variable "komodo_image_tag" {
  description = "Komodo Periphery image tag (ghcr.io/moghtech/komodo-periphery). Match the Core version."
  type        = string
  default     = "2"
}

variable "deploy" {
  description = "Master on/off switch. true = create/maintain the compute + NLB layer. Set to false and `terraform apply` to TEAR DOWN the servers and load balancer instead of redeploying over the top. The VCN/subnet/gateways, the reserved IP 170.9.237.30 (kept, just unassigned), and the backup bucket are preserved either way, so a later `deploy = true` reattaches the same IP."
  type        = bool
  default     = true
}

variable "ocpus" {
  description = "OCPUs for instance shape config. 1 OCPU is the maximum for free tier with 3 working nodes."
  type        = string
  default     = "1" # OCI Free
}

variable "admin_ip_whitelist" {
  description = "List of IP addresses (in CIDR notation) allowed to access SSH and Dokploy dashboard. Example: ['1.2.3.4/32', '5.6.7.8/32']"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Open to all by default - CHANGE THIS for production
}

variable "dokploy_domain" {
  description = "LEGACY (Dokploy is gone): no longer referenced by any resource. Kept declared so existing tfvars that set it don't error; defaulted so it isn't required."
  type        = string
  default     = ""
}

variable "dokploy_additional_domains" {
  description = "Additional hostnames that should route to the Dokploy dashboard (for example, apex domains)."
  type        = list(string)
  default     = []
}

variable "cloudflare_api_token" {
  description = "API token with DNS edit permissions for the Cloudflare zone."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "DEPRECATED: Use cloudflare_zones instead. Cloudflare zone ID that contains the Dokploy hostnames."
  type        = string
  default     = ""
}

variable "cloudflare_proxied" {
  description = "Whether Cloudflare should proxy the managed A records (set true to enable the orange cloud)."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Number of days to retain object storage backups before automatic deletion."
  type        = number
  default     = 7
}

variable "enable_automated_backups" {
  description = "Enable automated daily backups of Docker/Dokploy data to object storage."
  type        = bool
  default     = true
}

variable "recovery_boot_volume_id" {
  description = "OPTIONAL: Boot volume OCID to restore from. Leave empty for normal operation. Set this to a preserved boot volume OCID to recover from a disaster. Example: 'ocid1.bootvolume.oc1.region.abc123...'"
  type        = string
  default     = ""
}

variable "managed_dns_records" {
  description = "Map of DNS records to manage in Cloudflare. Each record specifies domain and subdomain. Use '@' for apex domain. All records will point to the main instance IP."
  type = map(object({
    domain    = string # e.g. "throughfire.net" or "rateduty.com"
    subdomain = string # e.g. "www" or "@" for apex
  }))
  default = {}
}
