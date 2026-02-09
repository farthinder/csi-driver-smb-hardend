# Security Hardening

This document describes the security hardening improvements made to the SMB CSI driver.

## Changes Made

### 1. Removed hostNetwork

**Previous:** Both the controller Deployment and node DaemonSet used `hostNetwork: true`.

**Current:** Removed `hostNetwork: true` from both components.

**Reason:** 
- `hostNetwork: true` gives pods access to the host's network stack, which is a security risk.
- The CSI driver does not require direct access to the host network to connect to SMB servers.
- Using the pod network namespace with the default DNS policy (`ClusterFirst`) is sufficient for DNS resolution and network connectivity.

**Impact:**
- Reduced attack surface by isolating pod networking from the host
- Pods now use the cluster network instead of the host network
- Changed `dnsPolicy` from `ClusterFirstWithHostNet` to `ClusterFirst` to match the new networking mode

### 2. Replaced privileged: true with Specific Capabilities

**Previous:** The `smb` container in both node and controller pods ran with `privileged: true`.

**Current:** Replaced with specific Linux capabilities:
```yaml
securityContext:
  capabilities:
    add:
      - SYS_ADMIN
    drop:
      - ALL
  allowPrivilegeEscalation: false
```

**Reason:**
- `privileged: true` grants all capabilities to a container, which is excessive.
- The SMB CSI driver only needs `CAP_SYS_ADMIN` for mount operations.
- Following the principle of least privilege by only granting the minimum required capability.

**Impact:**
- Significantly reduced container privileges
- Still allows mount/unmount operations required for CSI functionality
- Prevents privilege escalation with `allowPrivilegeEscalation: false`

### 3. Added readOnlyRootFilesystem

**Containers affected:**
- liveness-probe (both node and controller)
- node-driver-registrar
- csi-provisioner
- csi-resizer

**Change:**
```yaml
securityContext:
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
```

**Reason:**
- These sidecar containers don't need to write to their filesystem
- Read-only root filesystem prevents runtime modifications
- Protects against certain types of container breakout attacks

**Impact:**
- Improved defense-in-depth
- No functional impact as these containers don't require write access

### 4. Dropped All Capabilities by Default

**All containers** now explicitly drop all Linux capabilities with:
```yaml
capabilities:
  drop:
    - ALL
```

Only the `smb` container adds back `SYS_ADMIN` as needed.

## Security Benefits

1. **Reduced Attack Surface:** Removing hostNetwork limits the blast radius if a container is compromised
2. **Least Privilege:** Only granting SYS_ADMIN capability instead of full privileged mode
3. **Immutable Filesystem:** Read-only root filesystem for sidecar containers
4. **No Privilege Escalation:** Explicitly preventing privilege escalation
5. **Network Isolation:** Pods use cluster networking instead of host networking

## Compatibility

These changes maintain full compatibility with the CSI specification while improving security:
- SMB mount/unmount operations work correctly with `CAP_SYS_ADMIN`
- DNS resolution works with `ClusterFirst` DNS policy
- No changes required to storage classes or PVC definitions

## Testing

The hardened manifests should be tested with:
1. Basic volume provisioning and mounting
2. Volume deletion and cleanup
3. Multiple concurrent volumes
4. DNS resolution to SMB servers by hostname

## Deployment

### Using kubectl
```bash
kubectl apply -f deploy/csi-smb-controller.yaml
kubectl apply -f deploy/csi-smb-node.yaml
```

### Using Helm
The Helm chart has been updated with the same security improvements:
```bash
helm install csi-driver-smb charts/latest/csi-driver-smb \
  --namespace kube-system \
  --create-namespace
```

## References

- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Linux Capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [CSI Driver Security Best Practices](https://kubernetes-csi.github.io/docs/)
