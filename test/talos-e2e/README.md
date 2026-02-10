# Talos E2E Test for Hardened SMB CSI Driver

This test validates that the hardened SMB CSI driver (without hostNetwork and privileged mode) works correctly on a Talos cluster with external SMB server and DNS.

## Test Scenario

1. **Talos Cluster**: Creates a Talos Kubernetes cluster
2. **External SMB Server**: Ubuntu container/VM running Samba
3. **External DNS**: DNS server accessible from the cluster
4. **Helm Deployment**: Installs the hardened CSI driver via Helm
5. **Validation**: 
   - DNS resolution to SMB server by hostname
   - Mount SMB share successfully
   - Read/write data to mounted volume
   - Cleanup and unmount

## Prerequisites

- Docker (for running Ubuntu SMB server container)
- Talosctl (for managing Talos cluster)
- Kubectl (for Kubernetes operations)
- Helm (for deploying CSI driver)
- CoreDNS or dnsmasq (for external DNS)

## Test Components

### 1. SMB Server (Ubuntu)
- Runs in Docker container or separate VM
- Configured with Samba
- Accessible from Talos cluster network
- Hostname: `smb-server.external.local`

### 2. DNS Server
- External DNS server (CoreDNS/dnsmasq)
- Resolves `smb-server.external.local` to SMB server IP
- Accessible from Talos cluster

### 3. Talos Cluster
- Multi-node Talos cluster (1 control plane, 1+ workers)
- Network access to SMB server and DNS

### 4. Test Validation
- Create PVC
- Mount volume in pod
- Write test data
- Read and verify data
- Delete PVC
- Verify cleanup

## Running the Test

```bash
# Run the complete test
./run-talos-e2e-test.sh

# Or run individual steps
./setup-smb-server.sh      # Setup Ubuntu SMB server
./setup-dns-server.sh      # Setup external DNS
./deploy-talos-cluster.sh  # Create Talos cluster
./install-driver.sh        # Deploy CSI driver via Helm
./run-test-workload.sh     # Test mounting and operations
./cleanup.sh               # Cleanup all resources
```

## Expected Results

✅ DNS resolution from Talos cluster to external SMB server works
✅ SMB CSI driver pods start successfully with hardened security context
✅ PVC creation succeeds
✅ Volume mounts successfully in pod
✅ Data can be written and read from SMB share
✅ Volume unmounts cleanly
✅ PVC deletion completes successfully

## Security Validations

The test also validates that the hardened security settings are applied:
- ❌ hostNetwork: false (not using host network)
- ❌ privileged: false (not running privileged)
- ✅ capabilities: only SYS_ADMIN granted
- ✅ readOnlyRootFilesystem: true on all containers
- ✅ allowPrivilegeEscalation: false on smb container
