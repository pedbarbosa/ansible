#!/usr/bin/env bash

if [ ! -e "/etc/ansible/hosts" ]; then
    echo "No hosts found in '/etc/ansible/hosts', exiting..."
    exit 1
fi

ansible-playbook -v arch.yml
