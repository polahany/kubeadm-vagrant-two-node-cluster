# Implementation Report: Two-Node kubeadm Cluster

## 1. Objective

The assignment was to create a Kubernetes cluster with one control-plane node and one worker node using `kubeadm`, understand why each preparation step is required, and verify the completed architecture with a real workload.

The final environment contains:

- `k8s-control-plane` at `192.168.56.10`.
- `k8s-worker` at `192.168.56.11`.
- Kubernetes v1.37.1.
- containerd 2.2.1.
- Flannel v0.28.9.
- Two Nginx replicas exposed through NodePort `30080`.

## 2. Host inventory and virtualization decision

The Windows host already had WSL2 and Docker Desktop, but it did not have a general-purpose VM manager. A genuine two-node kubeadm cluster requires two independently addressable Linux machines with unique hostnames and machine identities. Two distributions sharing the same WSL2 utility VM would not provide the clean node isolation expected by the assignment.

VirtualBox and Vagrant were selected because:

- VirtualBox runs full Linux VMs on Windows Home.
- Vagrant defines both machines in a reviewable file.
- Static host-only addresses make the cluster topology repeatable.
- The lab can be started and stopped without deleting its state.

The tools were installed from an elevated PowerShell terminal:

```powershell
winget install --id Oracle.VirtualBox --exact --source winget `
  --accept-package-agreements --accept-source-agreements

winget install --id Hashicorp.Vagrant --exact --source winget `
  --accept-package-agreements --accept-source-agreements
```

Installed versions were VirtualBox 7.2.22 and Vagrant 2.4.9.

## 3. Vagrant topology and design choices

The initial Vagrant design used two Ubuntu VMs:

| Setting | Control plane | Worker | Reason |
|---|---|---|---|
| Hostname | `k8s-control-plane` | `k8s-worker` | Unique Kubernetes node identities. |
| Private IP | `192.168.56.10` | `192.168.56.11` | Stable node-to-node communication. |
| CPU | 3 | 3 | Meets kubeadm requirements and avoids a tested two-vCPU timing issue. |
| RAM | 3 GiB | 2 GiB | Leaves enough memory for control-plane and workload components. |
| NAT NIC | Enabled | Enabled | Provides package and image downloads. |
| Host-only NIC | Enabled | Enabled | Provides the cluster network. |

The shared `/vagrant` folder was disabled because Kubernetes did not require a host-mounted project directory and a smaller VM surface is easier to reason about.

Stable, distinct NAT MAC addresses were also configured. The initial Bento clone inherited the same NAT MAC on both VMs. Although the private NICs were already unique, Kubernetes documentation expects unique node hardware identities, so both NIC sets were made unambiguous.

## 4. Boot failure and corrective decision

The first VM used `bento/ubuntu-24.04`. VirtualBox started the process, but the guest repeatedly froze at:

```text
Begin: Loading essential drivers ...
```

The NAT port accepted TCP connections, but SSH never produced a banner, proving that the guest kernel had not completed its boot rather than Vagrant using a wrong key.

A pause/resume cycle released the timing stall once, but the failure repeated after reload. A lab that requires a manual recovery on every boot is not reproducible, so the image was changed to `bento/ubuntu-22.04`, an LTS release compatible with kubeadm. Three vCPUs were retained because exactly two vCPUs also triggered a known VirtualBox/Hyper-V timing path on the workstation.

Ubuntu 22.04 later encountered the same initramfs timing race once on the
control-plane VM. Three rapid pause/resume cycles released it without changing
the virtual disk. The guest clock was then resynchronized with
`systemd-timesyncd`. This workaround preserves WSL2 and Docker Desktop, which
would otherwise be disrupted by disabling the Windows hypervisor.

The replacement nodes successfully completed:

- Initial boot.
- Vagrant hostname and network configuration.
- SSH key replacement.
- A controlled control-plane restart.
- Two-way private-network ping tests.

WSL, Docker Desktop, Windows security features, and unrelated virtualization state were preserved.

## 5. Node identity and network selection

VirtualBox gives each VM a separate NAT network whose guest address can be `10.0.2.15`. Therefore both machines displayed that same NAT address even though they were separate VMs.

Using automatic kubelet detection could have registered both nodes with `10.0.2.15`. The kubelet was explicitly configured to use the host-only interface:

```text
k8s-control-plane -> --node-ip=192.168.56.10
k8s-worker        -> --node-ip=192.168.56.11
```

This produced the verified Kubernetes Internal IPs shown by `kubectl get nodes -o wide`.

Unique product UUIDs and MAC addresses were verified before kubeadm installation.

## 6. Linux kernel preparation

Swap was disabled because kubelet normally rejects a node with swap enabled. Persistent swap entries were commented in `/etc/fstab` so the condition survives reboot.

Two kernel modules were loaded:

- `overlay` supplies OverlayFS, which containerd uses for layered container filesystems.
- `br_netfilter` passes bridged traffic through the Linux netfilter path so Kubernetes and CNI rules can process it.

Three persistent sysctl values were configured:

```text
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
```

IP forwarding allows a Linux node to route packets between Pod, node, and external interfaces. The bridge settings allow Kubernetes networking rules to see packets crossing Linux bridges.

Verification showed both modules loaded and the relevant sysctl values set to `1`.

## 7. Container runtime decision

containerd was selected because it implements Kubernetes CRI directly and avoids the extra `cri-dockerd` adapter required by Docker Engine.

A default containerd configuration was generated and changed to:

```text
SystemdCgroup = true
```

This aligns containerd with kubelet and Ubuntu's systemd cgroup manager. Mixing `cgroupfs` and `systemd` can create inconsistent resource-management views under pressure.

The containerd service was enabled for immediate start and boot persistence.

## 8. Kubernetes package installation

The Kubernetes v1.37 `pkgs.k8s.io` repository was used instead of the deprecated legacy repository. The following packages were installed on both nodes:

- `kubeadm` for cluster bootstrap and node join.
- `kubelet` for node-level Pod reconciliation.
- `kubectl` for administration.

All three were placed on hold because Kubernetes upgrades must respect version-skew rules and should not occur as an accidental side effect of a general OS upgrade.

The kubelet restart loop before `kubeadm init` was expected: kubelet was installed but did not yet have cluster configuration.

## 9. Control-plane initialization

The control plane was initialized with:

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.56.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket=unix:///run/containerd/containerd.sock
```

The decisions behind these arguments were:

- The API server advertises the stable host-only address reachable by the worker.
- `10.244.0.0/16` matches Flannel's default Pod address space.
- The CRI socket removes ambiguity and explicitly selects containerd.

`kubeadm init` generated the cluster PKI, static control-plane Pod manifests, kubelet configuration, bootstrap token, and administrator kubeconfig.

The administrator kubeconfig was copied to the regular `vagrant` user's `$HOME/.kube/config` with mode `0600`.

## 10. CNI networking and the rollout timeout

Flannel v0.28.9 was installed as the cluster CNI. Flannel runs as a DaemonSet so every node receives one networking agent.

The first rollout command timed out after 300 seconds:

```text
0 of 1 updated pods are available
```

Inspection showed that the configuration was correct. The small CNI plugin image downloaded quickly, while the main Flannel image took 5 minutes and 38 seconds. The timeout reported only that the readiness deadline expired; it did not cancel the DaemonSet.

After the download completed:

- Flannel became `1/1 Running` on the control plane.
- The node changed to `Ready`.
- Both CoreDNS Pods became `Running`.

The verification timeout was increased to 600 seconds for this network environment. When the worker joined, a second Flannel Pod was scheduled there successfully.

Both VirtualBox NAT interfaces appear inside their separate NAT networks as
`10.0.2.15`. Flannel initially selected this duplicated `eth0` address, which
prevented worker Pods from reaching CoreDNS on the control plane. A declarative
DaemonSet patch adds `--iface=eth1`, forcing Flannel to use the unique
`192.168.56.10/11` host-only addresses for VXLAN traffic.

## 11. Worker join

A fresh bootstrap command was generated on the control plane:

```bash
sudo kubeadm token create --print-join-command
```

The generated command was run on the worker with the containerd CRI socket. The token authenticated the bootstrap request, while the CA hash protected discovery against connecting to the wrong API server.

The worker registered with Internal IP `192.168.56.11`, became `Ready`, and received its Flannel and kube-proxy DaemonSet Pods.

The optional `worker` role label was added for clearer output. Kubernetes does not require that label to schedule workloads.

## 12. End-to-end workload test

A Deployment with two Nginx replicas and a NodePort Service on `30080` were
defined declaratively in `nginx-test.yaml`. Vagrant copies this manifest to
`/home/vagrant/nginx-test.yaml` on the control-plane VM, where it is applied
with `kubectl apply`. Keeping the workload in YAML makes the test repeatable,
reviewable, and idempotent instead of depending on imperative creation commands.

The final state proved all major control paths:

- Deployment reconciliation produced `2/2` available replicas.
- The scheduler placed both application Pods on `k8s-worker`.
- Pod addresses `10.244.1.2` and `10.244.1.3` came from the worker's Flannel subnet.
- The NodePort Service mapped port `30080` to container port `80`.
- An HTTP request to `192.168.56.11:30080` returned the Nginx response.

The instructor-provided `cluster-smoke-test.sh` is also copied by Vagrant to
the control-plane node and marked executable. It performs broader checks in an
isolated temporary namespace without changing existing workloads or node
configuration.

## 13. Verified final state

```text
NAME                STATUS   ROLES           INTERNAL-IP
k8s-control-plane   Ready    control-plane   192.168.56.10
k8s-worker          Ready    worker          192.168.56.11
```

Verified system components included:

- One Flannel Pod per node.
- One kube-proxy Pod per node.
- Two running CoreDNS replicas.
- Healthy API server, etcd, scheduler, and controller manager.
- Two running Nginx application Pods on the worker.
- A working NodePort Service.

## 14. Alternatives considered

| Decision | Selected | Alternatives | Reason |
|---|---|---|---|
| Node platform | VirtualBox VMs | WSL distributions, cloud VMs, physical hosts | Full local node isolation without cloud cost. |
| VM automation | Vagrant | Manual VirtualBox setup | Repeatable, reviewable topology. |
| Runtime | containerd | CRI-O, Docker plus cri-dockerd | Direct CRI support and simple kubeadm integration. |
| CNI | Flannel | Calico, Cilium | Small and understandable overlay for a learning cluster. |
| Pod network | `10.244.0.0/16` | Other non-overlapping CIDRs | Matches the selected Flannel manifest. |
| Service exposure | NodePort | port-forward, Ingress, LoadBalancer | Tests node and Service networking without extra controllers. |

## 15. Limitations and production differences

This design intentionally prioritizes learning over production availability:

- A single control plane is a single point of failure.
- A single embedded etcd member is not highly available.
- There is no API-server load balancer.
- There is no dynamic persistent-volume provisioner.
- Flannel provides basic overlay networking rather than advanced policy and observability features.
- The Vagrant bootstrap defines the machines, while Kubernetes installation remains manual to demonstrate understanding of each step.

A production design would normally use multiple control-plane nodes, an odd-sized etcd quorum, a stable load-balanced API endpoint, backup and upgrade procedures, storage integration, monitoring, and a security-focused network policy implementation.

## 16. Main lessons

1. A running VM process does not prove a guest completed boot; console and SSH-banner diagnostics distinguish those states.
2. Kubernetes node identity includes hostname, machine identity, MAC addresses, and reachable Internal IP.
3. The container runtime and kubelet must agree on cgroup management.
4. kubeadm creates control-plane configuration but does not install Pod networking.
5. A rollout timeout is an observation deadline, not necessarily a failed workload.
6. DaemonSets are the correct mechanism for node-level agents such as Flannel and kube-proxy.
7. The final HTTP test validates scheduling, runtime, CNI, Service networking, and the application together.

## References

- [Vagrant multi-machine environments](https://developer.hashicorp.com/vagrant/docs/multi-machine)
- [Vagrant private networks](https://developer.hashicorp.com/vagrant/docs/networking/private_network)
- [Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Container runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [Kubernetes architecture](https://kubernetes.io/docs/concepts/architecture/)
- [Flannel documentation](https://github.com/flannel-io/flannel)
