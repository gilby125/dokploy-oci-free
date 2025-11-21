# Repository Guidelines

## Project Structure & Module Organization
Terraform sources live at the repository root (`main.tf`, `network.tf`, `variables.tf`, `outputs.tf`) and define the OCI resources for the Dokploy control plane and workers. Helper scripts in `bin/` provision Dokploy on each node (`bin/dokploy-main.sh`, `bin/dokploy-worker.sh`). Image assets reside in `doc/`, while environment-specific values belong in `terraform.tfvars` (excluded from version control when containing secrets).

## Build, Test, and Development Commands
Run `terraform init` once per workspace to download the OCI provider. Use `terraform fmt` before committing to normalize spacing. Execute `terraform validate` to catch syntax or provider issues locally. Produce a change preview with `terraform plan -var-file=terraform.tfvars`, and apply infrastructure changes with `terraform apply -var-file=terraform.tfvars` only after review. For scripted installs, you can dry-run Dokploy provisioning via `bash bin/dokploy-main.sh` on a disposable instance.

## Coding Style & Naming Conventions
All Terraform files use two-space indentation and snake_case for variables, locals, and output names (e.g., `num_worker_instances`). Resource names mirror OCI services (`oci_core_instance.dokploy_main`) and should include a descriptive suffix such as `_main` or `_worker`. Shell scripts in `bin/` should remain POSIX-compliant; start with `#!/usr/bin/env bash`, enable `set -euo pipefail`, and prefer lowercase, hyphenated filenames for new utilities.

## Testing Guidelines
Every change must pass `terraform fmt -check` and `terraform validate`. Capture the latest `terraform plan` output in the pull request, highlighting affected resources and any drift. When modifying shell scripts, smoke-test them on an OCI instance or local VM and document the command used. Keep the Terraform state clean by destroying test stacks with `terraform destroy` after validation.

## Commit & Pull Request Guidelines
Follow the concise, imperative style seen in the history (e.g., `Reopen ports 80/443 to public, delegate restrictions to Traefik`). Group related Terraform and script adjustments into a single commit and avoid mixing infrastructure changes with documentation-only updates. Pull requests should include: a summary of the change, linked issues if available, the relevant `terraform plan` snippet, and screenshots or logs when altering Dokploy behavior.

## Security & Configuration Tips
Never commit real API keys, SSH private keys, or populated state files; scrub sensitive values from `terraform.tfstate` before sharing. Store per-environment overrides in untracked `*.auto.tfvars` files and reference OCI compartment IDs via variables. When adjusting networking rules, double-check CIDR whitelists in `network.tf` to prevent unintended public exposure of Dokploy or worker nodes.
