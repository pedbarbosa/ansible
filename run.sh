#!/usr/bin/env bash

# TODO: Add check to see if Ansible is installed
#       If not, install and configure

if [ ! -e "/etc/ansible/hosts" ]; then
    echo "No hosts found in '/etc/ansible/hosts', exiting..."
    exit 1
fi

# TODO: Scan environment and configure accordingly

# TODO: For now, do Arch setups only
ansible-playbook -v arch.yml
