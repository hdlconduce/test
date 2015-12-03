#!/bin/bash

cd `dirname $0`

KUBE_VERSION="1.1.1"
function install_kubectl {
   echo "Installing kubectl..."
   wget https://storage.googleapis.com/kubernetes-release/release/v${KUBE_VERSION}/bin/darwin/amd64/kubectl
   chmod +x kubectl
   echo "Requiring sudo privileges to install kubectl into /usr/local/bin"
   sudo mv kubectl /usr/local/bin/
}

#install kubectl
if ! which kubectl > /dev/null
then
    install_kubectl
else
    if ! kubectl version -c | grep -q "${KUBE_VERSION}"
    then
	#old version, need to upgrade
	install_kubectl
    fi
fi

echo "Building virtual machine..."
if ! vagrant plugin list | grep -q "vagrant-triggers"
then
    vagrant plugin install vagrant-triggers
fi
if sysctl net.inet.ip.forwarding | grep -q "0"
then
    echo "Sudo is needed to enable port forwarding"
    sudo sysctl -w net.inet.ip.forwarding=1
    sudo pfctl -e
fi
if [ -e .vagrant_timestamp ]
then
    if [ Vagrantfile -nt .vagrant_timestamp ]
    then
	vagrant up --provision
	touch .vagrant_timestamp
    else
	vagrant up
    fi
else
    vagrant up
    touch .vagrant_timestamp
    vagrant ssh -c "/src/make.sh clean"
fi
vagrant ssh -c "/src/make.sh"
./k8s/run_dev.sh
