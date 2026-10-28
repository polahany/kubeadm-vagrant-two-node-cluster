Vagrant.configure("2") do |config|
  # Ubuntu 22.04 LTS avoids the Ubuntu 24.04 Bento initramfs freeze seen
  # with VirtualBox 7.2 running through the Windows Hyper-V backend.
  config.vm.box = "bento/ubuntu-22.04"

  # Give slow systems more time to start.
  config.vm.boot_timeout = 600

  # We do not need to mount the Windows project inside the nodes.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.define "control-plane", primary: true do |control|
    control.vm.hostname = "k8s-control-plane"

    # Copy the declarative test workload into the control-plane user's home.
    control.vm.provision "file",
      source: "nginx-test.yaml",
      destination: "/home/vagrant/nginx-test.yaml"

    # Force Flannel to use the unique host-only NIC instead of duplicate NAT IPs.
    control.vm.provision "file",
      source: "flannel-interface-patch.yaml",
      destination: "/home/vagrant/flannel-interface-patch.yaml"

    # Keep the instructor's smoke test ready to run from the control plane.
    control.vm.provision "file",
      source: "cluster-smoke-test.sh",
      destination: "/home/vagrant/cluster-smoke-test.sh"

    control.vm.provision "shell",
      inline: "chmod 0755 /home/vagrant/cluster-smoke-test.sh"

    # Private, non-public network shared by the host and both VMs.
    control.vm.network "private_network", ip: "192.168.56.10"

    control.vm.provider "virtualbox" do |vb|
      vb.name = "k8s-control-plane"
      vb.gui = false
      vb.memory = 3072
      # VirtualBox 7.2 on this Hyper-V-backed Windows host can stall an
      # Ubuntu guest during initramfs startup with exactly two vCPUs.
      vb.cpus = 3
      # Keep every Kubernetes node identity unique, including the NAT NIC.
      vb.customize ["modifyvm", :id, "--mac-address1", "080027A1B2C3"]
    end
  end

  config.vm.define "worker" do |worker|
    worker.vm.hostname = "k8s-worker"
    worker.vm.network "private_network", ip: "192.168.56.11"

    worker.vm.provider "virtualbox" do |vb|
      vb.name = "k8s-worker"
      vb.gui = false
      vb.memory = 2048
      vb.cpus = 3
      vb.customize ["modifyvm", :id, "--mac-address1", "080027D4E5F6"]
    end
  end
end
