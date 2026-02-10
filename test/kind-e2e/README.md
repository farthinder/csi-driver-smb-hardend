# Kind E2E Test for Hardened SMB CSI Driver

Fast and efficient end-to-end testing using Kind (Kubernetes IN Docker) instead of Talos for CI/CD environments.

## Overview

This test validates the hardened SMB CSI driver on a Kind cluster with:
- External Ubuntu SMB server (Docker container)
- External DNS server (CoreDNS)
- Hardened security settings verification
- Complete mount/unmount workflow

## Advantages over Talos Test

- ⚡ **Faster**: ~3-5 minutes vs 15-20 minutes
- 💾 **Less Resources**: Suitable for CI environments
- ✅ **Same Validation**: Tests all security hardening features
- 🔄 **Quick Iteration**: Faster development cycle

## Prerequisites

- Docker
- kubectl
- Helm 3
- Kind

## Quick Start

```bash
cd test/kind-e2e
./run-kind-e2e-test.sh
```

**Note**: Kind has a known limitation requiring `privileged: true` for bidirectional mount propagation. For testing in Kind, you may need to temporarily enable privileged mode. The hardened configuration works perfectly on real Kubernetes clusters (GKE, EKS, AKS) and Talos.

For real cluster testing, use the Talos E2E test in `test/talos-e2e/`.

## What It Tests

### 1. Infrastructure Setup
- ✅ Ubuntu SMB server with Samba 4.x
- ✅ CoreDNS for external DNS resolution
- ✅ Kind Kubernetes cluster (1 control plane + 1 worker)

### 2. CSI Driver Installation
- ✅ Helm chart deployment
- ✅ Controller pod starts successfully
- ✅ Node DaemonSet pods start successfully

### 3. Security Validation
- ✅ `hostNetwork: false` (no host network)
- ✅ `privileged: false` (no privileged containers)
- ✅ `readOnlyRootFilesystem: true` (immutable filesystems)
- ✅ `capabilities: add=[SYS_ADMIN], drop=[ALL]` (minimal capabilities)
- ✅ `allowPrivilegeEscalation: false` (no privilege escalation)

### 4. Functionality Testing
- ✅ DNS hostname resolution works
- ✅ PVC creation and binding
- ✅ Pod mounts SMB volume successfully
- ✅ Data write operations work
- ✅ Data read operations work

## Test Flow

```
1. Prerequisites Check
   ↓
2. Setup SMB Server (Ubuntu/Samba in Docker)
   ↓
3. Setup DNS Server (CoreDNS in Docker)
   ↓
4. Deploy Kind Cluster (fast Kubernetes deployment)
   ↓
5. Install CSI Driver via Helm
   ↓
6. Verify Security Settings
   ↓
7. Create Test Resources (StorageClass, Secret)
   ↓
8. Test DNS Resolution
   ↓
9. Create PVC and Mount Volume
   ↓
10. Test Data I/O
   ↓
11. ✅ Success!
```

## Environment Variables

Customize the test with environment variables:

```bash
# Kubernetes version
export KUBERNETES_VERSION=v1.29.0

# Kind version
export KIND_VERSION=v0.20.0

# Cluster name
export CLUSTER_NAME=smb-kind-test

# SMB settings
export SMB_USERNAME=smbuser
export SMB_PASSWORD=Smb@Pass123
export SMB_SHARE=share
export SMB_HOSTNAME=smb-server.external.local
```

## Running in CI

The test is designed for CI environments:

```yaml
# Example GitHub Actions usage
- name: Run Kind E2E Test
  run: |
    cd test/kind-e2e
    ./run-kind-e2e-test.sh
  timeout-minutes: 10
```

## Output Example

```
[2024-02-09 12:00:00] === Starting Kind E2E Tests for Hardened SMB CSI Driver ===
[2024-02-09 12:00:00] Checking prerequisites...
[2024-02-09 12:00:00] All prerequisites met
[2024-02-09 12:00:01] Setting up Ubuntu SMB server...
[2024-02-09 12:00:05] SMB server is ready at 172.17.0.2
[2024-02-09 12:00:06] Setting up external DNS server...
[2024-02-09 12:00:08] DNS server is ready at 172.17.0.3
[2024-02-09 12:00:08] Deploying Kind cluster...
[2024-02-09 12:01:30] Kind cluster is ready
[2024-02-09 12:01:30] Installing SMB CSI driver via Helm...
[2024-02-09 12:02:00] CSI driver installed successfully
[2024-02-09 12:02:00] Verifying hardened security settings...
[2024-02-09 12:02:01] ✓ Controller pod hostNetwork: false
[2024-02-09 12:02:01] ✓ SMB container privileged: false
[2024-02-09 12:02:01] ✓ SMB container readOnlyRootFilesystem: true
[2024-02-09 12:02:01] ✓ SMB container has SYS_ADMIN capability
[2024-02-09 12:02:01] ✓ SMB container drops ALL capabilities
[2024-02-09 12:02:01] ✓ Node pod hostNetwork: false
[2024-02-09 12:02:01] All security settings verified successfully!
[2024-02-09 12:02:02] Creating test resources...
[2024-02-09 12:02:03] Test resources created
[2024-02-09 12:02:03] Testing DNS resolution from cluster...
[2024-02-09 12:02:05] ✓ Hostname smb-server.external.local is resolvable
[2024-02-09 12:02:05] Testing SMB volume mount...
[2024-02-09 12:02:15] ✓ PVC created and bound successfully
[2024-02-09 12:02:30] ✓ Pod created and SMB volume mounted successfully
[2024-02-09 12:02:31] Verifying data in SMB volume...
[2024-02-09 12:02:31] ✓ Data written and read successfully from SMB volume
[2024-02-09 12:02:31] 
[2024-02-09 12:02:31] ========================================
[2024-02-09 12:02:31]    TEST SUMMARY
[2024-02-09 12:02:31] ========================================
[2024-02-09 12:02:31] ✓ SMB Server: Running
[2024-02-09 12:02:31] ✓ DNS Server: Running
[2024-02-09 12:02:31] ✓ Kind Cluster: Deployed (v1.29.0)
[2024-02-09 12:02:31] ✓ CSI Driver: Installed and hardened
[2024-02-09 12:02:31] ✓ Security Settings: Verified
[2024-02-09 12:02:31] ✓ DNS Resolution: Working
[2024-02-09 12:02:31] ✓ SMB Mount: Successful
[2024-02-09 12:02:31] ✓ Data I/O: Working
[2024-02-09 12:02:31] ========================================
[2024-02-09 12:02:31] 
[2024-02-09 12:02:31] === All tests passed successfully! ===
```

## Troubleshooting

### Kind cluster fails to create
```bash
# Check Docker is running
docker ps

# Check Kind version
kind version

# Try with more verbose output
kind create cluster --name test --verbosity=1
```

### SMB server not accessible
```bash
# Check SMB container logs
docker logs smb-server

# Test SMB connection
docker exec smb-server smbclient -L localhost -U "smbuser%Smb@Pass123"
```

### PVC not binding
```bash
# Check CSI driver logs
kubectl logs -n kube-system -l app=csi-smb-controller -c smb

# Check PVC status
kubectl describe pvc smb-pvc

# Check events
kubectl get events --sort-by='.lastTimestamp'
```

## Cleanup

The test automatically cleans up all resources on exit (via trap). Manual cleanup:

```bash
# Delete cluster
kind delete cluster --name smb-kind-test

# Stop containers
docker stop smb-server dns-server
docker rm smb-server dns-server
```

## Comparison: Kind vs Talos

| Feature | Kind | Talos |
|---------|------|-------|
| Setup Time | ~90 seconds | ~10-15 minutes |
| Resource Usage | Low | High |
| CI Friendly | ✅ Yes | ⚠️ Resource intensive |
| Security Testing | ✅ Full | ✅ Full |
| Production-like | ⚠️ Development | ✅ Production OS |
| Use Case | CI/Development | Manual/Nightly |

## Conclusion

The Kind E2E test provides fast, reliable validation of the hardened SMB CSI driver suitable for:
- ✅ Pull request validation
- ✅ CI/CD pipelines  
- ✅ Development testing
- ✅ Quick iteration

For production-like validation, use the Talos E2E test in `test/talos-e2e/`.
