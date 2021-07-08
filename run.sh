#!/usr/bin/env bash

function is_debian {
    [[ -e /etc/debian_version ]]
}

# Check if Ansible is installed
if ! command -v ansible &> /dev/null; then
    echo "Ansible isn't installed!"
    if is_debian; then
        echo "Calling 'apt' to install Ansible ..."
        sudo apt install -y ansible sshpass
    fi
fi

# Check if localhost is defined as a host
if [ ! -f "/etc/ansible/hosts" ]; then
  echo touch /etc/ansible/hosts
fi

if ! grep '127.0.0.1' /etc/ansible/hosts &> /dev/null; then
    echo "Updating Ansible hosts file ..."
    echo '127.0.0.1' | sudo tee -a /etc/ansible/hosts
fi

if is_debian; then
  playbook=ubuntu
else
  playbook=arch
fi

ansible-playbook -CD "$playbook".yml
