# KIND Multi-Node Cluster with Calico CNI

This repository contains a Bash script to automate the creation of a **multi-node KIND cluster** with **Calico CNI**.

## Prerequisites

- Linux system (x86_64 or ARM64)
- `sudo` privileges
- `curl` installed

## Setup

1. Clone the repository:
```bash
git clone <repo-url>
cd kind-calico-setup
sudo bash scripts/setup-kind-calico.sh
