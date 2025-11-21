# Automatically detect current public IP
data "http" "current_ip" {
  url = "https://api.ipify.org?format=text"
}

locals {
  current_ip_cidr = "${chomp(data.http.current_ip.response_body)}/32"
}
