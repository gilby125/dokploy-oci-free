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

  # Deterministic, identity-stable AD placement keyed by worker id. Worker N maps
  # to ad_names[N % len], which reproduces the original count-based formula
  # (worker id N lived at count index N-1, AD = ad_names[((N-1)+1) % len]). This
  # keeps worker "3" pinned to ad_names[0] (AD-1) exactly where it already runs,
  # so shrinking the fleet does NOT recreate it (AD is immutable). map: id -> AD.
  worker_ad = {
    for id in var.worker_node_ids :
    id => local.ad_names[tonumber(id) % length(local.ad_names)]
  }
}
