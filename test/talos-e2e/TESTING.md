# Manual Testing Guide

This guide provides step-by-step instructions for manually testing the hardened SMB CSI driver on Talos.

## Quick Start

For a fully automated test, simply run:

```bash
cd test/talos-e2e
./run-talos-e2e-test.sh
```

The script will:
1. ✅ Check prerequisites (docker, kubectl, helm, talosctl)
2. ✅ Setup Ubuntu SMB server in Docker
3. ✅ Setup external DNS server
4. ✅ Deploy Talos Kubernetes cluster
5. ✅ Install CSI driver via Helm
6. ✅ Verify security settings (no hostNetwork, no privileged)
7. ✅ Test DNS resolution from cluster
8. ✅ Create PVC and mount SMB volume
9. ✅ Verify read/write operations
10. ✅ Cleanup all resources

## Prerequisites

Install these tools before running the test:

### 1. Docker
```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install docker.io
sudo usermod -aG docker $USER
```

### 2. Talosctl
```bash
curl -sL https://talos.dev/install | sh
sudo mv talosctl /usr/local/bin/
talosctl version --client
```

### 3. Kubectl
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client
```

### 4. Helm
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

## Manual Step-by-Step Testing

If you want to run each step manually for debugging:

### Step 1: Setup SMB Server

```bash
# Start Ubuntu SMB server
docker run -d \
  --name smb-server \
  --hostname smb-server.external.local \
  -p 445:445 \
  -e "SMB_USER=smbuser" \
  -e "SMB_PASSWORD=Smb@Pass123" \
  -e "SMB_SHARE=share" \
  dperson/samba:latest \
  -u "smbuser;Smb@Pass123" \
  -s "share;/share;yes;no;no;all;smbuser" \
  -p

# Get SMB server IP
SMB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' smb-server)
echo "SMB Server IP: $SMB_IP"
```

### Step 2: Setup DNS Server

```bash
# Create CoreDNS config
cat > /tmp/Corefile << EOF
.:53 {
    hosts {
        $SMB_IP smb-server.external.local
        fallthrough
    }
    forward . 8.8.8.8 8.8.4.4
    log
    errors
}
EOF

# Start DNS server
docker run -d \
  --name dns-server \
  -p 1053:53/udp \
  -v /tmp/Corefile:/Corefile:ro \
  coredns/coredns:latest \
  -conf /Corefile

# Get DNS server IP
DNS_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dns-server)
echo "DNS Server IP: $DNS_IP"
```

### Step 3: Deploy Talos Cluster

```bash
# Create Talos cluster
talosctl cluster create \
  --name smb-talos-test \
  --kubernetes-version v1.29.0 \
  --talos-version v1.6.0 \
  --wait \
  --controlplanes 1 \
  --workers 1

# Get kubeconfig
talosctl kubeconfig --force smb-talos-test

# Verify cluster
kubectl get nodes
kubectl get pods -A
```

### Step 4: Install CSI Driver

```bash
# Install from local charts
cd ../../  # Go to project root
helm install csi-driver-smb \
  ./charts/latest/csi-driver-smb \
  --namespace kube-system \
  --set linux.enabled=true \
  --set windows.enabled=false \
  --wait

# Verify installation
kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-driver-smb
```

### Step 5: Verify Security Settings

```bash
# Check controller pod
CONTROLLER_POD=$(kubectl get pods -n kube-system -l app=csi-smb-controller -o jsonpath='{.items[0].metadata.name}')

# Verify hostNetwork is false
kubectl get pod $CONTROLLER_POD -n kube-system -o jsonpath='{.spec.hostNetwork}'
# Should output nothing or "false"

# Verify not privileged
kubectl get pod $CONTROLLER_POD -n kube-system -o jsonpath='{.spec.containers[?(@.name=="smb")].securityContext.privileged}'
# Should output nothing or "false"

# Verify readOnlyRootFilesystem
kubectl get pod $CONTROLLER_POD -n kube-system -o jsonpath='{.spec.containers[?(@.name=="smb")].securityContext.readOnlyRootFilesystem}'
# Should output "true"

# Check capabilities
kubectl get pod $CONTROLLER_POD -n kube-system -o jsonpath='{.spec.containers[?(@.name=="smb")].securityContext.capabilities}'
# Should show: {"add":["SYS_ADMIN"],"drop":["ALL"]}
```

### Step 6: Create Test Resources

```bash
# Create SMB credentials
kubectl create secret generic smbcreds \
  --from-literal=username=smbuser \
  --from-literal=password=Smb@Pass123

# Create StorageClass
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: smb-test
provisioner: smb.csi.k8s.io
parameters:
  source: "//smb-server.external.local/share"
  csi.storage.k8s.io/node-stage-secret-name: "smbcreds"
  csi.storage.k8s.io/node-stage-secret-namespace: "default"
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
```

### Step 7: Test DNS Resolution

```bash
# Test DNS from cluster
kubectl run dns-test --image=busybox:latest --rm -it --restart=Never -- \
  nslookup smb-server.external.local
# Should resolve to SMB server IP
```

### Step 8: Test SMB Mount

```bash
# Create PVC
kubectl apply -f - <<EOF
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

# Wait for PVC
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/smb-pvc --timeout=2m

# Create test pod
kubectl apply -f - <<EOF
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

# Wait for pod
kubectl wait --for=condition=Ready pod/smb-test-pod --timeout=2m

# Verify data
kubectl exec smb-test-pod -- cat /mnt/test.txt
# Should output: "Hello from Talos!"
```

### Step 9: Cleanup

```bash
# Delete test resources
kubectl delete pod smb-test-pod
kubectl delete pvc smb-pvc
kubectl delete secret smbcreds
kubectl delete storageclass smb-test

# Uninstall CSI driver
helm uninstall csi-driver-smb -n kube-system

# Stop containers
docker stop smb-server dns-server
docker rm smb-server dns-server

# Destroy Talos cluster
talosctl cluster destroy --name smb-talos-test
```

## Troubleshooting

### SMB Server Not Accessible
```bash
# Check SMB server is running
docker ps | grep smb-server

# Check SMB server logs
docker logs smb-server

# Test SMB connection
docker exec smb-server smbclient -L localhost -U "smbuser%Smb@Pass123" -N
```

### DNS Not Resolving
```bash
# Check DNS server is running
docker ps | grep dns-server

# Check DNS server logs
docker logs dns-server

# Test DNS directly
dig @$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dns-server) smb-server.external.local
```

### CSI Driver Pods Not Starting
```bash
# Check pod status
kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-driver-smb

# Check pod logs
kubectl logs -n kube-system -l app=csi-smb-controller --all-containers
kubectl logs -n kube-system -l app=csi-smb-node --all-containers

# Describe pods for events
kubectl describe pods -n kube-system -l app=csi-smb-controller
```

### PVC Not Binding
```bash
# Check PVC status
kubectl describe pvc smb-pvc

# Check CSI driver logs
kubectl logs -n kube-system -l app=csi-smb-controller -c smb

# Check events
kubectl get events --sort-by='.lastTimestamp'
```

## Expected Results

When everything works correctly:

✅ SMB server container running and accessible
✅ DNS server resolving smb-server.external.local
✅ Talos cluster deployed with 1 control plane and 1 worker
✅ CSI driver pods all running with hardened security:
   - hostNetwork: false
   - privileged: false
   - readOnlyRootFilesystem: true
   - capabilities: only SYS_ADMIN
✅ DNS resolution from cluster works
✅ PVC created and bound
✅ Pod successfully mounts SMB volume
✅ Data can be written and read from SMB share

## CI/CD Integration

The test is also available as a GitHub Actions workflow:
- Workflow file: `.github/workflows/talos-e2e.yml`
- Triggered on PRs affecting CSI driver files
- Can be manually triggered via workflow_dispatch
- Automatically collects logs on failure
