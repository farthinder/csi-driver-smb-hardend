#!/bin/bash

# Copyright 2024 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

# Talos E2E Test for Hardened SMB CSI Driver
# Tests the security-hardened driver on Talos with external SMB and DNS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
TALOS_VERSION="${TALOS_VERSION:-v1.6.0}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.29.0}"
CLUSTER_NAME="${CLUSTER_NAME:-smb-talos-test}"
SMB_SERVER_NAME="${SMB_SERVER_NAME:-smb-server}"
SMB_HOSTNAME="${SMB_HOSTNAME:-smb-server.external.local}"
SMB_USERNAME="${SMB_USERNAME:-smbuser}"
SMB_PASSWORD="${SMB_PASSWORD:-Smb@Pass123}"
SMB_SHARE="${SMB_SHARE:-share}"
DNS_SERVER_NAME="${DNS_SERVER_NAME:-dns-server}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*"
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*"
}

cleanup() {
    log "Cleaning up test resources..."
    
    # Delete test pod and PVC
    kubectl delete pod smb-test-pod --ignore-not-found=true --wait=false 2>/dev/null || true
    kubectl delete pvc smb-pvc --ignore-not-found=true --wait=false 2>/dev/null || true
    kubectl delete secret smbcreds --ignore-not-found=true 2>/dev/null || true
    kubectl delete storageclass smb-test --ignore-not-found=true 2>/dev/null || true
    
    # Uninstall CSI driver
    helm uninstall csi-driver-smb -n kube-system --wait 2>/dev/null || true
    
    # Stop and remove containers
    docker stop ${SMB_SERVER_NAME} ${DNS_SERVER_NAME} 2>/dev/null || true
    docker rm ${SMB_SERVER_NAME} ${DNS_SERVER_NAME} 2>/dev/null || true
    
    # Delete Talos cluster
    if command -v talosctl &> /dev/null; then
        talosctl cluster destroy --name ${CLUSTER_NAME} 2>/dev/null || true
    fi
    
    log "Cleanup complete"
}

trap cleanup EXIT

check_prerequisites() {
    log "Checking prerequisites..."
    
    local missing_tools=()
    
    command -v docker &> /dev/null || missing_tools+=("docker")
    command -v kubectl &> /dev/null || missing_tools+=("kubectl")
    command -v helm &> /dev/null || missing_tools+=("helm")
    command -v talosctl &> /dev/null || missing_tools+=("talosctl")
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        error "Please install missing tools and try again"
        exit 1
    fi
    
    log "All prerequisites met"
}

setup_smb_server() {
    log "Setting up Ubuntu SMB server..."
    
    # Create SMB server container with Samba
    docker run -d \
        --name ${SMB_SERVER_NAME} \
        --hostname ${SMB_HOSTNAME} \
        -p 445:445 \
        -e "SMB_USER=${SMB_USERNAME}" \
        -e "SMB_PASSWORD=${SMB_PASSWORD}" \
        -e "SMB_SHARE=${SMB_SHARE}" \
        dperson/samba:latest \
        -u "${SMB_USERNAME};${SMB_PASSWORD}" \
        -s "${SMB_SHARE};/share;yes;no;no;all;${SMB_USERNAME}" \
        -p
    
    # Get SMB server IP
    local smb_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${SMB_SERVER_NAME})
    
    # Wait for SMB server to be ready
    log "Waiting for SMB server to be ready..."
    sleep 5
    
    # Test SMB server connectivity
    if docker exec ${SMB_SERVER_NAME} smbclient -L localhost -U "${SMB_USERNAME}%${SMB_PASSWORD}" -N &>/dev/null; then
        log "SMB server is ready at ${smb_ip}"
        echo "${smb_ip}" > /tmp/smb_server_ip
    else
        error "SMB server failed to start properly"
        exit 1
    fi
}

setup_dns_server() {
    log "Setting up external DNS server..."
    
    local smb_ip=$(cat /tmp/smb_server_ip)
    
    # Create CoreDNS configuration
    cat > /tmp/Corefile << EOF
.:53 {
    hosts {
        ${smb_ip} ${SMB_HOSTNAME}
        fallthrough
    }
    forward . 8.8.8.8 8.8.4.4
    log
    errors
}
EOF
    
    # Start CoreDNS container
    docker run -d \
        --name ${DNS_SERVER_NAME} \
        -p 1053:53/udp \
        -v /tmp/Corefile:/Corefile:ro \
        coredns/coredns:latest \
        -conf /Corefile
    
    local dns_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${DNS_SERVER_NAME})
    
    log "DNS server is ready at ${dns_ip}"
    echo "${dns_ip}" > /tmp/dns_server_ip
}

deploy_talos_cluster() {
    log "Deploying Talos cluster..."
    
    local dns_ip=$(cat /tmp/dns_server_ip)
    
    # Create Talos cluster with custom DNS
    talosctl cluster create \
        --name ${CLUSTER_NAME} \
        --kubernetes-version ${KUBERNETES_VERSION} \
        --talos-version ${TALOS_VERSION} \
        --wait \
        --wait-timeout 10m \
        --dns-domain cluster.local \
        --controlplanes 1 \
        --workers 1
    
    # Get kubeconfig
    talosctl kubeconfig --force --nodes 127.0.0.1 ${CLUSTER_NAME}
    
    # Wait for cluster to be ready
    log "Waiting for Kubernetes cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=5m
    
    log "Talos cluster is ready"
}

install_csi_driver() {
    log "Installing SMB CSI driver via Helm..."
    
    # Install from local chart
    helm install csi-driver-smb \
        ${PROJECT_ROOT}/charts/latest/csi-driver-smb \
        --namespace kube-system \
        --set linux.enabled=true \
        --set windows.enabled=false \
        --wait \
        --timeout 5m
    
    # Wait for driver pods to be ready
    log "Waiting for CSI driver pods to be ready..."
    kubectl wait --for=condition=Ready pods -l app=csi-smb-controller -n kube-system --timeout=3m
    kubectl wait --for=condition=Ready pods -l app=csi-smb-node -n kube-system --timeout=3m
    
    log "CSI driver installed successfully"
}

verify_security_settings() {
    log "Verifying hardened security settings..."
    
    local failed=0
    
    # Check controller pod
    log "Checking controller pod security settings..."
    local controller_pod=$(kubectl get pods -n kube-system -l app=csi-smb-controller -o jsonpath='{.items[0].metadata.name}')
    
    # Verify hostNetwork is false
    local host_network=$(kubectl get pod ${controller_pod} -n kube-system -o jsonpath='{.spec.hostNetwork}')
    if [ "${host_network}" = "true" ]; then
        error "Controller pod has hostNetwork: true (should be false)"
        failed=1
    else
        log "✓ Controller pod hostNetwork: false"
    fi
    
    # Verify smb container is not privileged
    local privileged=$(kubectl get pod ${controller_pod} -n kube-system -o jsonpath='{.spec.containers[?(@.name=="smb")].securityContext.privileged}')
    if [ "${privileged}" = "true" ]; then
        error "SMB container is privileged: true (should be false)"
        failed=1
    else
        log "✓ SMB container privileged: false"
    fi
    
    # Verify readOnlyRootFilesystem on smb container
    local readonly_root=$(kubectl get pod ${controller_pod} -n kube-system -o jsonpath='{.spec.containers[?(@.name=="smb")].securityContext.readOnlyRootFilesystem}')
    if [ "${readonly_root}" != "true" ]; then
        error "SMB container readOnlyRootFilesystem: ${readonly_root} (should be true)"
        failed=1
    else
        log "✓ SMB container readOnlyRootFilesystem: true"
    fi
    
    # Verify capabilities
    local caps_add=$(kubectl get pod ${controller_pod} -n kube-system -o jsonpath='{.spec.containers[?(@.name=="smb")].securityContext.capabilities.add}')
    if [[ "${caps_add}" != *"SYS_ADMIN"* ]]; then
        error "SMB container missing SYS_ADMIN capability"
        failed=1
    else
        log "✓ SMB container has SYS_ADMIN capability"
    fi
    
    # Check node pod
    log "Checking node pod security settings..."
    local node_pod=$(kubectl get pods -n kube-system -l app=csi-smb-node -o jsonpath='{.items[0].metadata.name}')
    
    # Verify hostNetwork is false
    host_network=$(kubectl get pod ${node_pod} -n kube-system -o jsonpath='{.spec.hostNetwork}')
    if [ "${host_network}" = "true" ]; then
        error "Node pod has hostNetwork: true (should be false)"
        failed=1
    else
        log "✓ Node pod hostNetwork: false"
    fi
    
    if [ ${failed} -eq 1 ]; then
        error "Security verification failed!"
        exit 1
    fi
    
    log "All security settings verified successfully!"
}

create_test_resources() {
    log "Creating test resources..."
    
    local smb_ip=$(cat /tmp/smb_server_ip)
    
    # Create SMB credentials secret
    kubectl create secret generic smbcreds \
        --from-literal=username=${SMB_USERNAME} \
        --from-literal=password=${SMB_PASSWORD}
    
    # Create StorageClass
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: smb-test
provisioner: smb.csi.k8s.io
parameters:
  source: "//${SMB_HOSTNAME}/${SMB_SHARE}"
  csi.storage.k8s.io/node-stage-secret-name: "smbcreds"
  csi.storage.k8s.io/node-stage-secret-namespace: "default"
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
    
    log "Test resources created"
}

test_dns_resolution() {
    log "Testing DNS resolution from cluster..."
    
    # Create a test pod to check DNS
    kubectl run dns-test --image=busybox:latest --rm -it --restart=Never -- \
        nslookup ${SMB_HOSTNAME} || {
        error "DNS resolution failed for ${SMB_HOSTNAME}"
        exit 1
    }
    
    log "✓ DNS resolution successful"
}

test_smb_mount() {
    log "Testing SMB volume mount..."
    
    # Create PVC
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smb-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: smb-test
EOF
    
    # Wait for PVC to be bound
    log "Waiting for PVC to be bound..."
    kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/smb-pvc --timeout=2m
    
    log "✓ PVC created and bound successfully"
    
    # Create test pod with volume
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: smb-test-pod
spec:
  containers:
  - name: test-container
    image: busybox:latest
    command:
      - "/bin/sh"
      - "-c"
      - "echo 'Hello from Talos!' > /mnt/test.txt && cat /mnt/test.txt && sleep 3600"
    volumeMounts:
    - name: smb-volume
      mountPath: /mnt
  volumes:
  - name: smb-volume
    persistentVolumeClaim:
      claimName: smb-pvc
EOF
    
    # Wait for pod to be ready
    log "Waiting for test pod to be ready..."
    kubectl wait --for=condition=Ready pod/smb-test-pod --timeout=2m
    
    log "✓ Pod created and SMB volume mounted successfully"
    
    # Verify data was written
    log "Verifying data in SMB volume..."
    local output=$(kubectl exec smb-test-pod -- cat /mnt/test.txt)
    if [ "${output}" = "Hello from Talos!" ]; then
        log "✓ Data written and read successfully from SMB volume"
    else
        error "Data verification failed. Expected: 'Hello from Talos!', Got: '${output}'"
        exit 1
    fi
}

run_tests() {
    log "=== Starting Talos E2E Tests for Hardened SMB CSI Driver ==="
    
    check_prerequisites
    setup_smb_server
    setup_dns_server
    deploy_talos_cluster
    install_csi_driver
    verify_security_settings
    create_test_resources
    test_dns_resolution
    test_smb_mount
    
    log "=== All tests passed successfully! ==="
}

# Main execution
run_tests
