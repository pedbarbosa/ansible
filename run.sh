#!/usr/bin/env bash
set -euo pipefail

function is_debian {
    [[ -e /etc/debian_version ]]
}

function is_macos {
    [[ "$(uname -s)" == "Darwin" ]]
}

# Check if Ansible is installed
if ! command -v ansible &> /dev/null; then
    echo "Ansible isn't installed!"
    if is_debian; then
        echo "Calling 'apt' to install Ansible ..."
        sudo apt install -y ansible sshpass
    elif is_macos; then
        if ! command -v brew &> /dev/null; then
            echo "Homebrew isn't installed, installing ..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        echo "Calling 'brew' to install Ansible ..."
        brew install ansible
    fi
fi

public_key_file="$HOME/.ssh/id_ed25519.pub"
authorized_keys_file="$HOME/.ssh/authorized_keys"
current_user=$(whoami)

if [[ ! -f "$public_key_file" ]]; then
    echo "SSH ID file '$public_key_file' doesn't exist, creating ..."
    ssh-keygen -t ed25519 -f "$public_key_file" -C "$(hostname)" -N ""
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

sudoers_file="/etc/sudoers.d/$current_user"
if [[ ! -f "$sudoers_file" ]]; then
    echo "Adding user '$current_user' to sudoers ..."
    echo "$current_user ALL=(ALL) NOPASSWD:ALL" | sudo tee "$sudoers_file" > /dev/null
    sudo chmod 0440 "$sudoers_file"
    if ! sudo visudo -cf "$sudoers_file"; then
        echo "Generated sudoers file is invalid, removing ..."
        sudo rm -f "$sudoers_file"
        exit 1
    fi
fi

if ! grep '127.0.0.1' /etc/ansible/hosts &> /dev/null; then
    echo "Updating Ansible hosts file ..."
    echo '127.0.0.1' | sudo tee -a /etc/ansible/hosts
fi

if is_debian; then
    playbook=ubuntu
elif is_macos; then
    playbook=mac
else
    echo "Unsupported OS, exiting ..."
    exit 1
fi

ansible-playbook -CD "$playbook".yml

echo "This was a dry run. If you wish to apply these changes, run: ansible-playbook -v $playbook.yml"
