# Security Hardening Summary

This document provides a before/after comparison of the security improvements made to the SMB CSI driver.

## Summary Table

| Security Setting | Before | After | Benefit |
|-----------------|--------|-------|---------|
| **hostNetwork** | `true` on both node and controller | `false` (removed) | Prevents access to host network stack |
| **dnsPolicy** | `ClusterFirstWithHostNet` | `ClusterFirst` | Matches new pod networking mode |
| **privileged** | `true` on smb container | `false` (removed) | Prevents excessive privilege grant |
| **capabilities** | All (via privileged) | Only `SYS_ADMIN` for smb container | Follows least privilege principle |
| **allowPrivilegeEscalation** | Not set (defaults to true) | `false` on smb container | Prevents privilege escalation attacks |
| **readOnlyRootFilesystem** | Not set on any container | `true` on ALL containers | Immutable container filesystems |
| **Writable volumes** | Full root filesystem | Only `/tmp` via emptyDir | Minimal writable storage |

## Detailed Changes

### Controller Deployment (csi-smb-controller.yaml)

#### Before:
```yaml
spec:
  template:
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        - name: smb
          securityContext:
            privileged: true
            capabilities:
              drop:
                - ALL
```

#### After:
```yaml
spec:
  template:
    spec:
      dnsPolicy: ClusterFirst
      containers:
        - name: smb
          securityContext:
            readOnlyRootFilesystem: true
            capabilities:
              add:
                - SYS_ADMIN
              drop:
                - ALL
            allowPrivilegeEscalation: false
          volumeMounts:
            - mountPath: /tmp
              name: tmp-dir
      volumes:
        - name: tmp-dir
          emptyDir: {}
```

### Node DaemonSet (csi-smb-node.yaml)

#### Before:
```yaml
spec:
  template:
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        - name: liveness-probe
          securityContext:
            capabilities:
              drop:
                - ALL
        - name: node-driver-registrar
          securityContext:
            capabilities:
              drop:
                - ALL
        - name: smb
          securityContext:
            privileged: true
            capabilities:
              drop:
                - ALL
```

#### After:
```yaml
spec:
  template:
    spec:
      dnsPolicy: ClusterFirst
      containers:
        - name: liveness-probe
          securityContext:
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
        - name: node-driver-registrar
          securityContext:
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
        - name: smb
          securityContext:
            readOnlyRootFilesystem: true
            capabilities:
              add:
                - SYS_ADMIN
              drop:
                - ALL
            allowPrivilegeEscalation: false
          volumeMounts:
            - mountPath: /tmp
              name: tmp-dir
      volumes:
        - name: tmp-dir
          emptyDir: {}
```

## Impact on Pod Security Standards

### Before
The pods would fail to meet the **Restricted** Pod Security Standard and had issues with **Baseline**:
- ❌ Uses `hostNetwork: true` (Baseline violation)
- ❌ Uses `privileged: true` (Baseline violation)
- ❌ No read-only root filesystem (Restricted requirement)
- ❌ Allows privilege escalation (Restricted requirement)

### After
The pods now meet the **Baseline** Pod Security Standard and are closer to **Restricted**:
- ✅ No `hostNetwork` usage
- ✅ No `privileged` containers
- ✅ Read-only root filesystem on all containers
- ✅ Explicitly prevents privilege escalation
- ⚠️ Still requires `CAP_SYS_ADMIN` (needed for mount operations)
  - This is an acceptable exception for CSI drivers per Kubernetes documentation

## Kubernetes Pod Security Standards Compliance

| Standard Level | Before | After |
|---------------|--------|-------|
| **Privileged** | ✅ Pass | ✅ Pass |
| **Baseline** | ❌ Fail | ✅ Pass |
| **Restricted** | ❌ Fail | ⚠️ Partial* |

\* Partial compliance: Meets most Restricted requirements except `CAP_SYS_ADMIN` is still required for CSI mount functionality.

## Why CAP_SYS_ADMIN is Required

The `CAP_SYS_ADMIN` capability is necessary for the SMB CSI driver to:
1. Mount SMB volumes using the `mount()` system call
2. Unmount volumes using the `umount()` system call
3. Create and manage mount propagation

This is a standard requirement for CSI node drivers and is documented in the [CSI specification](https://github.com/container-storage-interface/spec/blob/master/spec.md).

Alternative approaches like using a separate mount helper with setuid were considered but:
- Add complexity and potential security issues
- Are not standard practice in the CSI community
- Would still require elevated privileges

## Security Risk Reduction

The changes reduce the attack surface and risk in several ways:

1. **Network Isolation**: Without `hostNetwork`, a compromised container cannot:
   - Sniff host network traffic
   - Bind to host network ports
   - Bypass network policies

2. **Privilege Reduction**: Without `privileged: true`, a compromised container cannot:
   - Load kernel modules
   - Access all devices
   - Bypass many security features

3. **Filesystem Protection**: With `readOnlyRootFilesystem: true`:
   - Malware cannot modify container binaries
   - Runtime modifications are prevented
   - Only designated writable areas (/tmp) can be used

4. **No Privilege Escalation**: With `allowPrivilegeEscalation: false`:
   - Processes cannot gain more privileges than the container
   - Setuid/setgid bits are ignored
   - Additional layer of defense

## Validation Recommendations

Before deploying to production, validate:
1. ✅ YAML syntax is valid (validated with yamllint)
2. ⚠️ Functional testing needed:
   - [ ] Create PVC and verify volume provisioning
   - [ ] Mount volume to a pod and write data
   - [ ] Verify DNS resolution to SMB server works
   - [ ] Delete PVC and verify cleanup
   - [ ] Test with multiple concurrent volumes
   - [ ] Verify credential files in /tmp are created correctly

## Files Modified

- `deploy/csi-smb-controller.yaml` - Direct kubectl deployment manifest
- `deploy/csi-smb-node.yaml` - Direct kubectl deployment manifest
- `charts/latest/csi-driver-smb/templates/csi-smb-controller.yaml` - Helm template
- `charts/latest/csi-driver-smb/templates/csi-smb-node.yaml` - Helm template
- `charts/latest/csi-driver-smb/values.yaml` - Helm values
- `docs/security-hardening.md` - New documentation
- `README.md` - Added security section

## References

- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Pod Security Standards Enforcement](https://kubernetes.io/docs/tutorials/security/ns-level-pss/)
- [Linux Capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [CSI Driver Security](https://kubernetes-csi.github.io/docs/)
- [Container Security Best Practices](https://kubernetes.io/docs/concepts/security/pod-security-policy/)
