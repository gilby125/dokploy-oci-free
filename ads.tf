# Availability domains for the region, used to spread worker nodes across ADs
# for a modicum of fault tolerance (a single-AD outage should not take down the
# whole worker pool / NLB backend set).
#
# ADs are a tenancy-level concept, so this lists against the root compartment
# (var.compartment_id is the tenancy OCID here).
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

locals {
  # Ordered list of AD names in this region, e.g.
  # ["YWJJ:US-CHICAGO-1-AD-1", "...-AD-2", "...-AD-3"].
  ad_names = [for ad in data.oci_identity_availability_domains.ads.availability_domains : ad.name]

  # Round-robin worker placement, offset by 1 so workers prefer ADs OTHER than
  # the main node's AD first. With 1 main + 3 workers over 3 ADs this yields a
  # 2-1-1 spread instead of clustering. AD is immutable, so changing a worker's
  # placement forces instance recreation.
  worker_ad = [
    for i in range(var.num_worker_instances) :
    local.ad_names[(i + 1) % length(local.ad_names)]
  ]
}
