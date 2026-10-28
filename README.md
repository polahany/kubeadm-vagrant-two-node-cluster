# Two-Node Kubernetes Cluster with kubeadm and Vagrant

This project creates a reproducible two-node Kubernetes lab on a Windows host. Vagrant manages two Ubuntu virtual machines in VirtualBox, while `kubeadm` bootstraps one control-plane node and one worker node.

The verified cluster uses Kubernetes v1.37.1, containerd, Flannel networking, CoreDNS, and kube-proxy. A two-replica Nginx Deployment and NodePort Service provide an end-to-end workload test.

## Architecture

```text
Windows host
  |
  | Vagrant + VirtualBox host-only network
  |
  +-- k8s-control-plane (192.168.56.10)
  |     |- kube-apiserver
  |     |- etcd
  |     |- kube-scheduler
  |     |- kube-controller-manager
  |     |- kubelet + containerd
  |     |- kube-proxy
  |     |- Flannel
  |     `- CoreDNS
  |
  `-- k8s-worker (192.168.56.11)
        |- kubelet + containerd
        |- kube-proxy
        |- Flannel
        `- application Pods
```

| Node | Role | Private IP | CPUs | RAM |
|---|---|---:|---:|---:|
| `k8s-control-plane` | Control plane | `192.168.56.10` | 3 | 3 GiB |
| `k8s-worker` | Worker | `192.168.56.11` | 3 | 2 GiB |

VirtualBox also gives each VM a NAT interface for internet access. Both NAT interfaces can display `10.0.2.15` because they are in separate NAT networks. Kubernetes is explicitly configured to use the unique `192.168.56.0/24` host-only addresses.

## Repository contents

```text
.
|- Vagrantfile
|- README.md
|- IMPLEMENTATION_REPORT.md
`- .gitignore
```

Vagrant machine state, SSH keys, Kubernetes credentials, logs, and diagnostic screenshots are intentionally excluded from Git.

## Prerequisites

- Windows 10 or 11 with hardware virtualization enabled.
- Oracle VirtualBox 7.2.x.
- Vagrant 2.4.x.
- At least 6 GiB of available RAM for the two VMs.
- Internet access for Ubuntu packages and container images.

Install the host tools from an elevated PowerShell terminal:

```powershell
winget install --id Oracle.VirtualBox --exact --source winget `
  --accept-package-agreements --accept-source-agreements

winget install --id Hashicorp.Vagrant --exact --source winget `
  --accept-package-agreements --accept-source-agreements
```

## Run the existing local cluster

From PowerShell:

```powershell
Set-Location 'D:\programming\barq intern\barq task 2\kubeadm-lab'
vagrant status
vagrant up
vagrant ssh control-plane
```

Inside the control-plane VM:

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get deployments
kubectl get services
curl -I http://192.168.56.11:30080
```

Expected results:

- Both nodes are `Ready`.
- Flannel and kube-proxy have one Pod on each node.
- Both CoreDNS Pods are `Running`.
- Both Nginx Pods run on `k8s-worker`.
- The HTTP request returns `200 OK`.

To stop the lab without deleting it:

```powershell
vagrant halt
```

Do not use `vagrant destroy` unless the cluster should be permanently erased.

## Build the cluster from a fresh clone

### 1. Create and access the VMs

```powershell
vagrant validate
vagrant up --provider=virtualbox
vagrant ssh control-plane
```

Open a second PowerShell terminal for the worker:

```powershell
vagrant ssh worker
```

Commands marked **both nodes** must be run in both VM terminals.

### 2. Prepare both nodes

Run on **both nodes**:

```bash
sudo swapoff -a
sudo sed -ri.bak '/[[:space:]]swap[[:space:]]/s/^#?/#/' /etc/fstab

sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

These settings enable container filesystem layers, bridged packet filtering, and routing between Pod and node networks.

### 3. Install and configure containerd

Run on **both nodes**:

```bash
sudo apt-get update
sudo apt-get install -y containerd
sudo install -d -m 0755 /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd
sudo systemctl restart containerd
```

The `systemd` cgroup driver keeps containerd aligned with kubelet and the Ubuntu init system.

### 4. Install Kubernetes packages

Run on **both nodes**:

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo install -d -m 0755 /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key |
  sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' |
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

### 5. Select unique Kubernetes node addresses

On the **control plane**:

```bash
echo 'KUBELET_EXTRA_ARGS=--node-ip=192.168.56.10' |
  sudo tee /etc/default/kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

On the **worker**:

```bash
echo 'KUBELET_EXTRA_ARGS=--node-ip=192.168.56.11' |
  sudo tee /etc/default/kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

This override prevents both kubelets from selecting the duplicated VirtualBox NAT address.

### 6. Initialize the control plane

Run only on `k8s-control-plane`:

```bash
sudo kubeadm config images pull \
  --cri-socket=unix:///run/containerd/containerd.sock

sudo kubeadm init \
  --apiserver-advertise-address=192.168.56.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket=unix:///run/containerd/containerd.sock
```

Configure kubectl for the regular `vagrant` user:

```bash
mkdir -p "$HOME/.kube"
sudo install -o "$(id -u)" -g "$(id -g)" -m 0600 \
  /etc/kubernetes/admin.conf "$HOME/.kube/config"
```

### 7. Install Flannel networking

```bash
kubectl apply -f \
  https://github.com/flannel-io/flannel/releases/download/v0.28.9/kube-flannel.yml

kubectl rollout status daemonset/kube-flannel-ds \
  -n kube-flannel --timeout=600s

kubectl rollout status deployment/coredns \
  -n kube-system --timeout=600s
```

Flannel assigns a Pod subnet to each node and carries cross-node Pod traffic over VXLAN.

### 8. Join the worker

Generate the join command on the control plane:

```bash
sudo kubeadm token create --print-join-command
```

Run the generated command on the worker with `sudo` and the containerd socket appended:

```bash
sudo kubeadm join 192.168.56.10:6443 \
  --token REPLACE_WITH_GENERATED_TOKEN \
  --discovery-token-ca-cert-hash sha256:REPLACE_WITH_GENERATED_HASH \
  --cri-socket=unix:///run/containerd/containerd.sock
```

Never commit a live bootstrap token.

Optionally label the worker from the control plane:

```bash
kubectl label node k8s-worker node-role.kubernetes.io/worker=worker
```

### 9. Validate the cluster

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

### 10. Deploy the end-to-end test

```bash
kubectl create deployment nginx-test --image=nginx:alpine --replicas=2
kubectl create service nodeport nginx-test \
  --tcp=80:80 --node-port=30080
kubectl rollout status deployment/nginx-test --timeout=180s
kubectl get pods -o wide
kubectl get services
curl -I http://192.168.56.11:30080
```

The response should be `HTTP/1.1 200 OK`, and both application Pods should be scheduled on the worker.

## Component responsibilities

| Component | Responsibility |
|---|---|
| kube-apiserver | Exposes the Kubernetes API and validates requests. |
| etcd | Stores the authoritative cluster state. |
| kube-scheduler | Assigns unscheduled Pods to suitable nodes. |
| kube-controller-manager | Reconciles actual state with desired state. |
| kubelet | Ensures assigned Pods are running on a node. |
| containerd | Pulls images and executes containers through CRI. |
| kube-proxy | Implements Kubernetes Service networking. |
| Flannel | Provides cross-node Pod networking. |
| CoreDNS | Provides DNS discovery for cluster Services and Pods. |

## Troubleshooting

### Flannel rollout times out

Check whether images are still downloading:

```bash
kubectl get pods -n kube-flannel -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -n 40
```

A rollout timeout does not cancel the DaemonSet. On the verified workstation, the Flannel image took more than five minutes to download and became healthy afterward.

### A node registers with `10.0.2.15`

Verify `/etc/default/kubelet` contains the correct `--node-ip` value, then restart kubelet. The expected Internal IPs are `192.168.56.10` and `192.168.56.11`.

### Vagrant VM boot is slow

VirtualBox can be slower when it uses the Windows Hyper-V backend. This project uses Ubuntu 22.04 and three vCPUs per VM because the tested Bento Ubuntu 24.04 image repeatedly froze during initramfs startup on this host.

## Limitations

This is a learning cluster, not a production high-availability design. It has one control plane and one etcd member, no persistent storage provisioner, and no control-plane load balancer. Losing the control-plane VM can make the cluster unavailable and can lose cluster state.

## References

- [Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Container runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [Kubernetes components](https://kubernetes.io/docs/concepts/overview/components/)
- [Flannel](https://github.com/flannel-io/flannel)
