## Mac install

### Ensure homebrew is installed

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Install ansible

```
brew install ansible
```

### Ansible dry run

```
ansible-playbook -CD mac.yml
```

### Ansible apply

```
ansible-playbook -v mac.yml
```

