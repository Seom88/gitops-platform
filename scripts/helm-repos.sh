#!/usr/bin/env bash
# Idempotent Helm repo setup shared by CI and the justfile.
# Intended to be SOURCED so callers can call helm_repos_ensure explicitly:
#   # shellcheck source=helm-repos.sh
#   source "$(dirname "$0")/helm-repos.sh"
# Superset of repos needed by validate (lint/dependency) and discover/scan
# (aquasecurity is only consumed by the image-discovery flow).
set -euo pipefail

helm_repos_ensure() {
  helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add tailscale https://pkgs.tailscale.com/helmcharts >/dev/null 2>&1 || true
  helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
  helm repo add aquasecurity https://aquasecurity.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
}
