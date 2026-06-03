# Main instance
resource "oci_core_instance" "dokploy_main" {
  count = var.deploy ? 1 : 0

  display_name         = "dokploy-main-${random_string.resource_code.result}"
  compartment_id       = var.compartment_id
  availability_domain  = var.availability_domain_main
  preserve_boot_volume = true

  is_pv_encryption_in_transit_enabled = local.instance_config.is_pv_encryption_in_transit_enabled
  shape                               = local.instance_config.shape

  metadata = {
    ssh_authorized_keys     = local.instance_config.ssh_authorized_keys
    user_data               = base64encode(file("./bin/dokploy-main.sh"))
    dokploy_domain          = var.dokploy_domain
    dokploy_domains         = join(",", distinct(concat([var.dokploy_domain], var.dokploy_additional_domains)))
    admin_access_cidrs      = join(",", distinct(concat([local.current_ip_cidr], var.admin_ip_whitelist, [oci_core_vcn.dokploy_vcn.cidr_block])))
    backup_bucket           = oci_objectstorage_bucket.dokploy_backups.name
    backup_namespace        = data.oci_objectstorage_namespace.current.namespace
    enable_automated_backup = var.enable_automated_backups
    backup_script           = base64encode(file("./bin/backup-to-object-storage.sh"))
  }

  create_vnic_details {
    display_name              = "dokploy-main-${random_string.resource_code.result}"
    subnet_id                 = oci_core_subnet.dokploy_subnet.id
    assign_ipv6ip             = false
    assign_private_dns_record = true
    assign_public_ip          = false # Changed to false - using reserved IP instead
  }

  availability_config {
    recovery_action = local.instance_config.availability_config.recovery_action
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = local.instance_config.instance_options.are_legacy_imds_endpoints_disabled
  }

  shape_config {
    memory_in_gbs = local.instance_config.shape_config.memory_in_gbs
    ocpus         = local.instance_config.shape_config.ocpus
  }

  source_details {
    # Use recovery boot volume if specified, otherwise use standard image
    source_id   = var.recovery_boot_volume_id != "" ? var.recovery_boot_volume_id : local.instance_config.source_details.source_id
    source_type = var.recovery_boot_volume_id != "" ? "bootVolume" : local.instance_config.source_details.source_type
  }

  agent_config {
    is_management_disabled = "false"
    is_monitoring_disabled = "false"
    plugins_config {
      desired_state = "DISABLED"
      name          = "Vulnerability Scanning"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Management Agent"
    }
    plugins_config {
      desired_state = "ENABLED"
      name          = "Custom Logs Monitoring"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Compute RDMA GPU Monitoring"
    }
    plugins_config {
      desired_state = "ENABLED"
      name          = "Compute Instance Monitoring"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Compute HPC RDMA Auto-Configuration"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Compute HPC RDMA Authentication"
    }
    plugins_config {
      desired_state = "ENABLED"
      name          = "Cloud Guard Workload Protection"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Block Volume Management"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Bastion"
    }
  }

  # Ignore source_details changes after recovery to avoid OCI provider bug
  lifecycle {
    ignore_changes = [source_details]
  }
}

# Worker instances (similar to main instance)
resource "oci_core_instance" "dokploy_worker" {
  count = var.deploy ? var.num_worker_instances : 0

  display_name   = "dokploy-worker-${count.index + 1}-${random_string.resource_code.result}"
  compartment_id = var.compartment_id
  # Spread workers across the region's ADs for a modicum of redundancy (see
  # ads.tf). AD is immutable, so changing placement recreates the instance.
  availability_domain = local.worker_ad[count.index]

  is_pv_encryption_in_transit_enabled = local.instance_config.is_pv_encryption_in_transit_enabled
  shape                               = local.instance_config.shape

  metadata = {
    ssh_authorized_keys = local.instance_config.ssh_authorized_keys
    user_data           = base64encode(file("./bin/dokploy-worker.sh"))
  }

  create_vnic_details {
    display_name              = "dokploy-worker-${count.index + 1}-${random_string.resource_code.result}"
    subnet_id                 = oci_core_subnet.dokploy_subnet.id
    assign_ipv6ip             = false
    assign_private_dns_record = true
    assign_public_ip          = true
  }

  availability_config {
    recovery_action = local.instance_config.availability_config.recovery_action
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = local.instance_config.instance_options.are_legacy_imds_endpoints_disabled
  }

  shape_config {
    memory_in_gbs = local.instance_config.shape_config.memory_in_gbs
    ocpus         = local.instance_config.shape_config.ocpus
  }

  source_details {
    source_id   = local.instance_config.source_details.source_id
    source_type = local.instance_config.source_details.source_type
    # Free-tier block storage is 200 GB total; 50 GB is the OCI minimum boot
    # volume. 4 nodes x 50 GB = 200 GB = exactly the Always-Free allotment.
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  agent_config {
    is_management_disabled = "false"
    is_monitoring_disabled = "false"
    plugins_config {
      desired_state = "DISABLED"
      name          = "Vulnerability Scanning"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Management Agent"
    }
    plugins_config {
      desired_state = "ENABLED"
      name          = "Custom Logs Monitoring"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Compute RDMA GPU Monitoring"
    }
    plugins_config {
      desired_state = "ENABLED"
      name          = "Compute Instance Monitoring"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Compute HPC RDMA Auto-Configuration"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Compute HPC RDMA Authentication"
    }
    plugins_config {
      desired_state = "ENABLED"
      name          = "Cloud Guard Workload Protection"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Block Volume Management"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Bastion"
    }
  }
}
