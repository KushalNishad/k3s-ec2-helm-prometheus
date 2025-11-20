# k3s-ec2-helm-prometheus

This project automates the deployment of a lightweight Kubernetes cluster using **k3s** on an **Ubuntu 22.04 EC2 instance**, followed by installing:

- Nginx (via Helm)
- Prometheus (via Helm)

Everything is driven by a single Bash script (`setup.sh`).

---

## Repository Structure

```bash
k3s-ec2-helm-prometheus/
│
├── setup.sh                      # Main automation script
├── cleanup.sh                    # (Optional) Removes all AWS resources
├── README.md                     # Documentation
├── .env.example                  # Template for AWS credentials
│
├── Resources/
│   ├── AWS/
│   │   ├── ec2_details.json      # Stores instance metadata
│   │   └── sg_details.json       # Stores security group metadata
│   └── Logs/
│       └── setup.log             # Full script log output
│
└── helm/
    └── nginx-chart/              # (Optional) Custom Helm chart for Nginx
```
---

## How to Run
```bash
git clone https://github.com/<your-username>/k3s-ec2-helm-prometheus.git
cd k3s-ec2-helm-prometheus

cp .env.example .env
vi .env     # add AWS keys + region

chmod +x setup.sh
./setup.sh
```