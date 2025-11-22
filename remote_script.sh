GREEN='\033[0;32m'
NC='\033[0m'

EC2_PUBLIC_IP=$(curl -s ifconfig.me)

set -e
sudo apt-get update -y >/dev/null 2>&1

# Install k3s
echo -e "Installing k3s..."
curl -sfL https://get.k3s.io | sudo sh - >/dev/null 2>&1
echo -e "${GREEN}ks3s installed successfully.${NC}\n"

# Kubeconfig for ubuntu user
mkdir -p /home/ubuntu/.kube
sudo cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config
sudo chmod 600 /home/ubuntu/.kube/config

export KUBECONFIG=/home/ubuntu/.kube/config

# Persist it for future SSH logins
echo 'export KUBECONFIG=/home/ubuntu/.kube/config' >> /home/ubuntu/.bashrc

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1


# Add repo to install nginx
echo -e "Adding repo to install nginx..."
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1
echo -e "${GREEN}nginx repo installed successfully.${NC}\n"

echo -e "Adding repo to install Prometheus..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
echo -e "${GREEN}Prometheus repo installed successfully.${NC}\n"

echo -e "Updating Helm repo..."
helm repo update >/dev/null 2>&1
echo -e "${GREEN}Helm repo updated successfully.${NC}\n"

# Install nginx
echo -e "Deploying Nginx webserver via Helm..."
helm install nginx-web-server bitnami/nginx \
--namespace nginx \
--create-namespace \
--set service.type=NodePort \
--set service.nodePorts.http=30080 >/dev/null 2>&1
echo -e "${GREEN}Nginx webserver deployed on http://${EC2_PUBLIC_IP}:30080 successfully.${NC}\n"

echo -e "${GREEN}Nginx services:${NC}"
kubectl get svc -n nginx

# Create file to use fixed NodePort for prometheus
cat <<EOF2 > prom-values.yaml
prometheus:
  service:
    type: NodePort
    nodePort: 30090
EOF2

# Install prometheus in "monitoring" namespace
echo -e "\nDeploying Prometheus as a NodePort service via Helm..."
helm install kps prometheus-community/kube-prometheus-stack \
--namespace monitoring \
--create-namespace \
-f prom-values.yaml >/dev/null 2>&1
echo -e "${GREEN}Prometheus deployed on http://${EC2_PUBLIC_IP}:30090 successfully.${NC}\n"

echo -e "${GREEN}Prometheus services:${NC}"
kubectl get svc -n monitoring

echo -e "${GREEN}Sample metric check (up):${NC}"

curl -s "http://${EC2_PUBLIC_IP}:30090/api/v1/query?query=up" | head -c 300
echo

echo -e "\n${GREEN}Metric check completed.${NC}"