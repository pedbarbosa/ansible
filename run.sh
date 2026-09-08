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

public_key_file="$HOME/.ssh/id_ed25519.pub"
authorized_keys_file="$HOME/.ssh/authorized_keys"
current_user=$(whoami)

if [[ ! -f "$public_key_file" ]]; then
    echo "SSH ID file '$public_key_file' doesn't exist, creating ..."
    ssh-keygen -t ed25519 -f "$public_key_file" -C '$(hostname)' -N ""
fi

if [[ ! -f "$authorized_keys_file" ]]; then
  echo "Creating '$authorized_keys_file' file ..."
  touch "$authorized_keys_file"
  chmod 600 "$authorized_keys_file"
fi

public_key=$(cat "$public_key_file")
if ! grep -qF "$public_key" "$authorized_keys_file"; then
    echo "'$authorized_keys_file' requires an update ..."
    echo "$public_key" >> "$authorized_keys_file"
else
    echo "'$authorized_keys_file' is up-to-date."
fi

# Check if localhost is defined as a host
if [ ! -f "/etc/ansible/hosts" ]; then
    sudo mkdir -p /etc/ansible
    sudo touch /etc/ansible/hosts
fi

if [[ ! -f "/etc/sudoers.d/$current_user" ]]; then
    echo "Adding user '$current_user' to sudoers ..."
    echo "$current_user ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers.d/$current_user
fi

if ! grep '127.0.0.1' /etc/ansible/hosts &> /dev/null; then
    echo "Updating Ansible hosts file ..."
    echo '127.0.0.1' | sudo tee -a /etc/ansible/hosts
fi

if is_debian; then
  playbook=ubuntu
else
  echo "Unsupported OS, exiting ..."
  exit 1
fi

ansible-playbook -CD "$playbook".yml
