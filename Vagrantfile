require 'fileutils'
require 'net/http'
require 'open-uri'
require 'json'

class Module
  def redefine_const(name, value)
    __send__(:remove_const, name) if const_defined?(name)
    const_set(name, value)
  end
end

required_plugins = %w(vagrant-triggers)
required_plugins.each do |plugin|
  need_restart = false
  unless Vagrant.has_plugin? plugin
    system "vagrant plugin install #{plugin}"
    need_restart = true
  end
  exec "vagrant #{ARGV.join(' ')}" if need_restart
end

VAGRANT_ROOT = File.dirname(File.expand_path(__FILE__))
CHANNEL = 'alpha'
COREOS_VERSION = 'latest'
upstream = "http://#{CHANNEL}.release.core-os.net/amd64-usr/current"
url = "#{upstream}/version.txt"
Object.redefine_const(:COREOS_VERSION,
                      open(url).read().scan(/COREOS_VERSION=.*/)[0].gsub('COREOS_VERSION=', ''))
BASE_IP_ADDR = "172.17.8"
KUBERNETES_VERSION = '1.1.1'
DNS_DOMAIN = "cluster.local"
DNS_UPSTREAM_SERVERS = "8.8.8.8:53,8.8.4.4:53"

MOUNT_POINTS = YAML::load_file(File.join(File.dirname(__FILE__), 'dev/synced_folders.yaml'))
DOCKERCFG = File.expand_path("~/.dockercfg")
SSL_FILE = File.join(File.dirname(__FILE__), "dev/kube-serviceaccount.key")

unless File.exists?(File.join(ENV['HOME'], ".secrets/test_user_password"))
  raise "Could not find test user password. Please update secrets directory."
end

unless File.exists?(File.join(ENV['HOME'], ".secrets/hatch_secrets.py"))
  raise "Could not find Hatch secrets. Please update secrets directory."
end


file_to_disk = File.join(VAGRANT_ROOT, '.vagrant/swap_disk.vdi')

Vagrant.configure("2") do |config|
  config.ssh.insert_key = false
  config.ssh.forward_agent = true
  config.ssh.username = 'core'

  config.vm.define "conduce"
  config.vm.box = "coreos-#{CHANNEL}"
  config.vm.box_version = "= #{COREOS_VERSION}"
  config.vm.box_url = "#{upstream}/coreos_production_vagrant.json"

  config.vm.provider :virtualbox do |vb|
    vb.check_guest_additions = false
    vb.functional_vboxsf     = false
    vb.memory = (ENV['BANKSY_MEMORY'] || 8192).to_i
    vb.cpus = (ENV['BANKSY_CPUS'] || 8).to_i

    unless File.exist?(file_to_disk)
      vb.customize ['createhd', '--filename', file_to_disk, '--size', 4 * 1024]
    end
    vb.customize ['storageattach', :id, '--storagectl', 'IDE Controller', '--port', 1, '--device', 0, '--type', 'hdd', '--medium', file_to_disk]
  end

  hostname = "master"
  ETCD_SEED_CLUSTER = "#{hostname}=http://#{BASE_IP_ADDR}.101:2380"
  cfg = File.join(File.dirname(__FILE__), "dev/master.yaml")
  MASTER_IP="#{BASE_IP_ADDR}.101"

  config.vm.hostname = "master"

  # suspend / resume is hard to be properly supported because we have no way
  # to assure the fully deterministic behavior of whatever is inside the VMs
  # when faced with XXL clock gaps... so we just disable this functionality.
  config.trigger.reject [:suspend, :resume] do
    info "'vagrant suspend' and 'vagrant resume' are disabled."
    info "- please do use 'vagrant halt' and 'vagrant up' instead."
  end

  config.trigger.instead_of :reload do
    exec "vagrant halt && vagrant up"
    exit
  end

  config.trigger.after [:up, :resume] do
    info "Sanitizing stuff..."
    if Gem.win_platform?
      system "eval `ssh-agent -s`; ssh-add ~/.vagrant.d/insecure_private_key"
    else
      system "ssh-add ~/.vagrant.d/insecure_private_key"
    end
    system "rm -rf ~/.fleetctl/known_hosts"
  end

  config.trigger.after [:up] do
    info "Waiting for Kubernetes master to become ready..."
    j, uri, res = 0, URI("http://#{MASTER_IP}:8080"), nil
    loop do
      j += 1
      begin
        res = Net::HTTP.get_response(uri)
      rescue
        sleep 10
      end
      break if res.is_a? Net::HTTPSuccess or j >= 50
    end

    nuke_services_script = File.join(File.dirname(__FILE__), "scripts/nuke-services")
    wait_for_ready_script = File.join(File.dirname(__FILE__), "scripts/wait_for_ready")
    wait_for_service_script = File.join(File.dirname(__FILE__), "scripts/wait_for_service")

    info "Stopping all old conduce services..."
    system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" #{nuke_services_script}"

    res, uri.path = nil, '/api/v1/namespaces/default/replicationControllers/kube-dns'
    begin
      res = Net::HTTP.get_response(uri)
    rescue
    end
    if not res.is_a? Net::HTTPSuccess
      dns_controller = File.join(File.dirname(__FILE__), "dev/dns/dns-controller.yaml")
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl create -f #{dns_controller}"
      info "Waiting for kube-dns to start..."
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" #{wait_for_ready_script} kube-dns"
    end

    res, uri.path = nil, '/api/v1/namespaces/default/services/kube-dns'
    begin
      res = Net::HTTP.get_response(uri)
    rescue
    end
    if not res.is_a? Net::HTTPSuccess
      dns_service = File.join(File.dirname(__FILE__), "dev/dns/dns-service.yaml")
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl create -f #{dns_service}"

      yamlFile = File.join(File.dirname(__FILE__), "dev/heapster/kube-system-namespace.yaml")
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl create -f #{yamlFile}"

      info "Stopping old monitoring services (error messages can be safely ignored)..."
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl --namespace kube-system stop services heapster monitoring-grafan monitoring-influxdb"
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl --namespace kube-system stop rc heapster influxdb-grafana"

      info "Starting monitoring services..."
      yamlFile = File.join(File.dirname(__FILE__), "dev/heapster/heapster-service-account.yaml")
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl create -f #{yamlFile}"

      yamlFile = File.join(File.dirname(__FILE__), "dev/heapster/heapster-service.yaml")
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl create -f #{yamlFile}"

      yamlFile = File.join(File.dirname(__FILE__), "dev/heapster/influxdb-service.yaml")
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl create -f #{yamlFile}"

      yamlFile = File.join(File.dirname(__FILE__), "dev/heapster/grafana-service.yaml")
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl create -f #{yamlFile}"

      info "Waiting for monitoring services..."
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" #{wait_for_service_script} --namespace kube-system heapster"
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" #{wait_for_service_script} --namespace kube-system monitoring-grafana"
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" #{wait_for_service_script} --namespace kube-system monitoring-influxdb"

      yamlFile = File.join(File.dirname(__FILE__), "dev/heapster/heapster-controller.yaml")
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl create -f #{yamlFile}"

      info "Waitng for heapster replication controller..."
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" #{wait_for_ready_script} --namespace kube-system heapster"

      yamlFile = File.join(File.dirname(__FILE__), "dev/heapster/influxdb-grafana-controller.yaml")
      system "KUBERNETES_MASTER=\"http://#{MASTER_IP}:8080\" kubectl create -f #{yamlFile}"
    end

  end

  config.trigger.before [:destroy] do
    system <<-EOT.prepend("\n\n") + "\n"
          rm -f temp/*
        EOT
  end

  config.trigger.after [:destroy] do
    vagrant_timestamp = File.join(File.dirname(__FILE__), ".vagrant_timestamp")
    system "rm -f #{vagrant_timestamp}"
  end

  # For Windows we don't forward standard ports here -- it won't work. We do it with config.vm.network below
  if not Gem.win_platform?
    config.trigger.after [:provision, :up, :reload] do
      puts " ==> Sudo Password (to forward ports) "
      system('echo "
rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080
rdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443
" | sudo pfctl -f - > /dev/null 2>&1; echo "==> Fowarding Ports: 80 -> 8080, 443 -> 8443"')
    end
    config.trigger.after [:halt, :destroy] do
      system("sudo pfctl -f /etc/pf.conf > /dev/null 2>&1; echo '==> Removing Port Forwarding'")
    end
  end

  config.vm.network :private_network, ip: "#{BASE_IP_ADDR}.101"
  # you can override this in synced_folders.yaml
  config.vm.synced_folder ".", "/vagrant", disabled: true

  begin
    MOUNT_POINTS.each do |mount|
      mount_options = ""
      disabled = false
      nfs =  true
      if mount['mount_options']
        mount_options = mount['mount_options']
      end
      if mount['disabled']
        disabled = mount['disabled']
      end
      if mount['nfs']
        nfs = mount['nfs']
      end
      if File.exist?(File.expand_path("#{mount['source']}"))
        if mount['destination']
          if Gem.win_platform?
            config.vm.synced_folder "#{mount['source']}", "#{mount['destination']}",
                                    id: "#{mount['name']}",
                                    disabled: disabled,
                                    virtualbox: true
          else
            config.vm.synced_folder "#{mount['source']}", "#{mount['destination']}",
                                    id: "#{mount['name']}",
                                    disabled: disabled,
                                    mount_options: ["#{mount_options}"],
                                    nfs: nfs
          end
        end
      end
    end
  rescue
  end

  if File.exist?(DOCKERCFG)
    config.vm.provision :file, run: "always",
                        :source => "#{DOCKERCFG}", :destination => "/home/core/.dockercfg"

    config.vm.provision :shell, run: "always" do |s|
      s.inline = "cp /home/core/.dockercfg /root/.dockercfg"
      s.privileged = true
    end
  end

  if File.exist?(SSL_FILE)
    config.vm.provision :file, :source => "#{SSL_FILE}", :destination => "/home/core/kube-serviceaccount.key"
  end

  if File.exist?(cfg)
    config.vm.provision :file, :source => "#{cfg}", :destination => "/tmp/vagrantfile-user-data"
    config.vm.provision :shell, :privileged => true,
                        inline: <<-EOF
          mv /tmp/vagrantfile-user-data /var/lib/coreos-vagrant/
        EOF

  end

  config.vm.network "forwarded_port", guest: 80, host: 8080
  config.vm.network "forwarded_port", guest: 443, host: 8443
  if Gem.win_platform?
    config.vm.network "forwarded_port", guest:80, host:80
    config.vm.network "forwarded_port", guest:443, host:443
  end

  if File.exists?(File.join(ENV['HOME'], ".secrets/test_user_password"))
    config.vm.provision "file", source: "~/.secrets/test_user_password", destination: "/home/core/.secrets/test_user_password"
  end

  if File.exists?(File.join(ENV['HOME'], ".secrets/hatch_secrets.py"))
    config.vm.provision "file", source: "~/.secrets/hatch_secrets.py", destination: "/home/core/.secrets/hatch_secrets.py"
  end

  config.vm.provision :shell, :privileged => true,
                      inline: <<-EOF
      mkdir -p /etc/nginx/ssl
      openssl genrsa 2048 > /etc/nginx/ssl/star-mct-io-key
      openssl req -x509 -batch -new -key /etc/nginx/ssl/star-mct-io-key -out /etc/nginx/ssl/star-mct-io-pem
      if [ -e /home/core/.secrets/hatch_secrets.py ] ; then
        cp /home/core/.secrets/hatch_secrets.py /etc/nginx/ssl/hatch-secrets-py
      fi
    EOF

  config.vm.provision :shell, :privileged => true,
                      inline: <<-EOF
      mkdir -p /var/volumes/data
      chown 999:999 /var/volumes/data
    EOF

end
