# 🛠️ OCP Easy Install on AWS

**OCP Easy Install on AWS** is a set of scripts that automate the installation of **OpenShift 4.x** clusters on **AWS**.  
It simplifies the setup process by handling instance type selection, pull secrets, SSH keys, and generating the OpenShift `install-config.yaml`.

---

## 💡 Features

- ✅ Automatic detection of **AWS region** and **base domain** (Route53)  
- ✅ Pre-flight checks for **openshift-install**, AWS credentials, SSH keys, and pull secrets  
- ✅ Interactive selection of **master and worker instance types**  
- ✅ Easy selection of **OpenShift versions** from the stable channel  
- ✅ Automatic generation of **install-config.yaml** with all required fields  
- ✅ Optional **release image override** with architecture detection  
- ✅ Fully **colorful and user-friendly output** with icons  

---

## ⚙️ Requirements

- Bash 4+  
- AWS CLI configured with appropriate credentials  
- OpenShift Installer (matching desired OpenShift version)  
- Pull secret file from [Red Hat OpenShift](https://cloud.redhat.com/openshift/install)  
- SSH key for cluster access  

---

## 🚀 Installation Steps

1. **Clone the repository:**

```bash
git clone https://github.com/mmartofel/ocp-easy-install-aws.git
cd ocp-easy-install-aws
```

2. **Set optional environment variables:**

```bash
export AWS_PROFILE=default
export CLUSTER_NAME=zenek
export CLUSTER_DIR=./config
export BASE_DOMAIN=example.com
```
3. **Run the installation script:**

```bash
./install.sh
```

Follow the interactive prompts to choose master and worker instance types, and OpenShift version.
The script will generate install-config.yaml and start the cluster installation.

4. **Access your cluster:**

```bash
export KUBECONFIG=./config/auth/kubeconfig
oc status
```

```graphql
.
├── install.sh                # Main installation script
├── instances/                # Instance type definitions
│   ├── master
│   └── worker
├── pull-secret.txt           # OpenShift pull secret (user-provided)
├── ssh/                      # SSH key for nodes
│   └── id_rsa.pub
└── config/                   # Generated OpenShift config directory
    └── install-config.yaml
```

🖌️ **Customization**

You can modify:

instances/master and instances/worker to update available instance types

install-config.yaml template in the script to add extra AWS settings or networking options

OpenShift version selection to pin a specific patch release

⚠️ **Notes**

The installer supports automatic OpenShift version selection from the stable channel (e.g., stable-4.20). You can modify your channel over time, or propose how can we improve that functionality together.

The script includes pre-flight checks to prevent common errors.

Custom release image override is used to start from most recent or just purposly chosen patch version at the start to save time for 'after install' upgrades chain.

📖 References

OpenShift Installation Guide

AWS OpenShift Installer

🤝 Contributing

Feel free to submit issues, pull requests, or suggest new features.
This project is meant to simplify OpenShift installations for AWS users and is community-driven.

⚡ License

This repository is licensed under the MIT License. See LICENSE
 for details.