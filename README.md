# consul-aws-esm
This repo builds the required AWS Networking and EKS resources to run consul-esm on EKS and test Prepared queries.

## Getting Started
Review the different architecture models within ./quickstart.  There are more details on these at the bottom of this README.  
### Pre Reqs
- Consul Enterprise License `./files/consul.lic`
- Setup shell with AWS credentials 
- Create AWS EC2 Key Pair (ssh key) in us-west-2 or target region
- Terraform 1.3.7+
- aws cli
- kubectl
- helm

## Provision Infrastructure
Edit the `quickstart/1vpc-2eks/my.auto.tfvars` and replace the `ec2_key_pair_name` value with your AWS key pair name.  Then use Terraform to build the required AWS Infrastructure.
```
cd quickstart/1vpc-2eks
terraform init
terraform apply -auto-approve
```

Connect to EKS using `scripts/kubectl_connect_eks.sh`.  Pass this script the path to the terraform state file used to provision the EKS cluster.  If cwd is ./1vpc-2eks like above then this command would look like the following:
```
source ../../scripts/kubectl_connect_eks.sh .
```
This script connects EKS and builds some useful aliases shown in the output.
* `consul1` alias for consul1 EKS cluster context
* `consul2` alias for consul2 EKS cluster context
* `kk` alias : kubectl -n kube-system
* `kc` alias : kubectl -n consul
* `k` alias  : kubectl

Install the AWS Load Balancer Controller addon to EKS from the terraform directory.
```
../../scripts/install_awslb_controller.sh .
```
This is used to create an NLB for Consul mesh gateways to enable Peering, and an external NLB for the Consul UI.


## Install Consul
```
cd consul_helm_values
terraform init
terraform apply -auto-approve
```

### Upgrade consul to run agents
An agent should be deployed to K8s if using this repo's infrastructure so skip this step.  This terraform above creates a helm values file when installing Consul.  This can be found for each Consul cluster.  For example, consul1 cluster used these helm values `./quickstart/1vpc-2eks/consul_helm_values/yaml/auto-consul-vpc1-consul1-values-server-sd.yaml`.  This file can be used directly with `helm upgrade` to test various configurations.  


Example: Running helm upgrade
```
RELEASE=$(helm -n consul list -o json | jq -r '.[].name')
helm upgrade ${RELEASE} hashicorp/consul --namespace consul --values ./yaml/auto-consul-vpc1-consul1-values-server-sd.yaml
```
If you're building Consul outside of this repo ensure the helm values are set properly.

## Deploy EMS on K8s with an agent
Connect to the EKS cluster hosting Consul and set your current K8s context to the first EKS cluster `consul1`.
The script below will register the external learn svc.  To test failover across DCs skip this step and jump to the optional section below and deploy fake-service on the two VMs that were created in this repo.
```
cd ../../../esm/k8s-with-agent
consul1
./deploy.sh
consul2
./deploy.sh
```

### Review Consul UI's
Login to the consul UI to see the new ext svc and consul-esm svc registered. Get the Consul URL and token for the current k8s context using the following script.  Review both Consul clusters.
```
consul1
../../scripts/setConsulEnv.sh
consul2
../../scripts/setConsulEnv.sh
```

Click on the ext learn svc. It should be passing its health checks.
The http-check should be returning 200 OK.

If there are additional EKS Consul datacenters, switch contexts to the target DC and repeat these steps.

### Configure Consul DNS on EKS
Patch core-dns configmap to forward all .consul requests to Consul DNS.
```
consul1
../../scripts/patch_coredns_to_fwd_to_consul.sh
consul2
../../scripts/patch_coredns_to_fwd_to_consul.sh
```

Verify coredns is now forwarding .consul requests to Consul
```
consul1
kc exec statefulset/consul-server -- nslookup consul.service.consul
kc exec statefulset/consul-server -- nslookup learn.service.consul
consul2
kc exec statefulset/consul-server -- nslookup learn.service.consul
```
### Deploy consul-esm and validate Geo-Failover across DCs with prepared queries.
If there are two datacenters do these steps in each one. This repo requires the use of a bastion host to SSH to the internal VMs.  The infra built from this repo will work with the below shortcuts.
```
cd ../../quickstart/1vpc-2eks
vm1=$(terraform output -json | jq -r '.usw2_ec2_ip.value."vpc1-vm1"')
vm2=$(terraform output -json | jq -r '.usw2_ec2_ip.value."vpc1-vm2"')
bastion=$(terraform output -json | jq -r '.usw2_ec2_ip.value."vpc1-bastion"')
```

SSH to the vm in the first DC.  Use your private key so it can be forwarded to the target host.
```
ssh-add -L ${HOME}/.ssh/ppresto-ptfe-dev-key.pem
ssh -A -J ubuntu@${bastion} ubuntu@${vm1}
```

#### Install fake service (web) and run it on each VM.
You should no be ssh'd into vm1. vm1 will be part of Consul dc1, and vm2 will be part of Consul dc2.  
Note: When running the below commands you can update the service Name to reflect the DC if graphically doing the failover.  For example,
```
export NAME-"web-dc1"
```

Install fake service by copying and pasting the following in the VM terminal.
```
mkdir -p ${HOME}/fake-service/{central_config,bin,logs}
cd ${HOME}/fake-service/bin
wget https://github.com/nicholasjackson/fake-service/releases/download/v0.23.1/fake_service_linux_amd64.zip
unzip fake_service_linux_amd64.zip
chmod 755 ${HOME}/fake-service/bin/fake-service

cat >${HOME}/fake-service/start.sh <<-EOF
#!/bin/bash

export MESSAGE="Web RESPONSE"
export NAME="web"
export SERVER_TYPE="http"
export LISTEN_ADDR="0.0.0.0:8080"
nohup ./bin/fake-service > logs/fake-service.out 2>&1 &
EOF

chmod 755 ${HOME}/fake-service/start.sh
cd ${HOME}/fake-service
./start.sh
exit
```

Repeat this for vm2
```
ssh -A -J ubuntu@${bastion} ubuntu@${vm2}
```

#### Edit 2 ext service files to point to the service on each VM.
Query the environment to collect the VM Node(hostname), and IP Address.  These files will be registered by the correct Consul DC in the next step.

Run the following commands to get dc1 vm1 environment values.
```
output=$(terraform output -json)
NODE=$(echo $output | jq -r '.usw2_ec2_dns.value."vpc1-vm1"')
ADDRESS=$(echo $output | jq -r '.usw2_ec2_ip.value."vpc1-vm1"')
ID="web-dc1"
echo -e " NODE: $NODE \n ADDRESS: $ADDRESS\n ID: $ID"
```
Edit `./esm/k8s-with-agent/web-ext-dc1.json` with the these values and replace both attributes below with $ADDRESS.
* Address
* http-check url address 

Run the following commands to get dc1 vm2 environment values.
```
output=$(terraform output -json)
NODE=$(echo $output | jq -r '.usw2_ec2_dns.value."vpc1-vm2"')
ADDRESS=$(echo $output | jq -r '.usw2_ec2_ip.value."vpc1-vm2"')
ID="web-dc2"
echo -e " NODE: $NODE \n ADDRESS: $ADDRESS\n ID: $ID"
```
Edit `./esm/k8s-with-agent/web-ext-dc2.json` with the these values and replace both attributes below with $ADDRESS.
* Address
* http-check url address 

#### Register the web svc on each Consul DC.
Update `./esm/k8s-with-agent/deploy.sh` with the new external service file value. 
```
#EXT_SERVICE_JSON="learn-ext.json"
EXT_SERVICE_JSON="web-ext-${DATACENTER}.json"
```
Rerun `./esm/k8s-with-agent/deploy.sh`.  This script will run against the current k8s context.
```
cd ../../esm/k8s-with-agent
consul1
./deploy.sh

consul2
./deploy.sh
```
Review the Consul UI's to see the new `web` service registered and being healthchecked by ESM.
#### Setup Peering between both Datacenters for Failover
Peer the two Consul DC's so services like `web` can discover and failover across them.

The peering scripts assume the following:
* Consul is running on K8s
* current datacenters are dc1, dc2
* current terminal is authN to both K8s clusters
* K8s contexts are consul1, consul2
* Sets mesh defaults to Peer through Mesh Gateways

If anything is different make the necessary adjustments.
```
cd ../peering
```

Update `peer_dc1_to_dc2.sh` to reflect your K8s contexts if different.
```
#  Setup Kubeconfig to auth into AKS Consul cluster
CTX1=consul1
CTX2=consul2
```

Peer the two clusters
```
./peer_dc1_to_dc2.sh
```
Note:  To peer directly from Consul servers instead of the more secure design using Mesh Gateways comment out the following lines setting up the mesh defaults to peer through MGW.
```
#kubectl -n consul --context ${CTX1} apply -f ${CUR_SCRIPT_DIR}/mesh.yaml
#kubectl -n consul --context ${CTX2} apply -f ${CUR_SCRIPT_DIR}/mesh.yaml
```

####  Create Prepared Query
Go to each EKS context and create a prepared query that will failover the `web` service across peers.  The following script will use the current-contex, create a prepared query for that DC, and list the defined queries to verify it was created.
```
cd ../prepared_query
consul1
./deploy.sh
consul2
./deploy.sh
```

#### Validate Failover

Go to each DC and lookup web.query.consul.  The local IP should be returned.
```
consul1
kc exec statefulset/consul-server -- nslookup web.query.consul
consul2
kc exec statefulset/consul-server -- nslookup web.query.consul
```

SSH to vm1 and kill web
```
ssh -A -J ubuntu@${bastion} ubuntu@${vm1}
pkill fake-service
exit
```
Wait a couple seconds ...
ESM may take a couple seconds to identify the unhealthy instance depending on its configuration.  Once the UI shows `web` in dc1 failing test out the query in dc1 again.

```
consul1
kc exec statefulset/consul-server -- nslookup web.query.consul
```
This time the IP returned should be the IP address of the `web` service in DC2.

### Clean Up
Go to `./esm` directory
```
cd ..
```

Cut and paste the following commands to remove the peering connection, consul-esm, web and learn ext monitors, and prepared queries.
```
peering/peer_dc1_to_dc2.sh -d

consul1
prepared_query/deploy.sh -d
kubectl -n consul delete po -l component=client
k8s-with-agent/deploy.sh -d

consul2
prepared_query/deploy.sh -d
kubectl -n consul delete po -l component=client
k8s-with-agent/deploy.sh -d
```

Uninstall all Consul datacenters using Terraform's helm provider
```
cd ../quickstart/vpc1-eks2/consul_helm_values
terraform destroy -auto-approve
```

Uninstall infrastructure
```
cd ../
terraform destroy -auto-approve
```

## Appendix

### Deploy ESM on Kubernetes with no Consul agents
#### K8s deployment
Sample deployment files are available in `./k8s`.  Review `k8s/deploy.sh` to see the kubernetes objects that will be created in the k8s current-context.  Then run the script.

```
./deploy.sh
```
When running ESM in an agentless environment like K8s it needs to stick to a single Consul server to avoid healthcheck flapping.  Running ESM with an agent would avoid this and is covered in `./k8s-with-agent`.

This script does the following:
* creates a new consul-expose-server-0 endpoint that uses an Internal NLB to route to a single consul server.  
* deploys the esm-service in the consul namespace.
* Uses the secret: consul-ca-cert
* Uses the secret: consul-bootstrap-acl-token
* Uses the consul-expose-server-0 endpoint to route to a single Consul node
* Registers an external service with healthchecks (default: learn.hashicorp.com)

The new K8s endpoint may take a few minutes before its resolvable in DNS.  Wait a couple minutes...

#### Consul UI
Login to the consul UI to see the new ext svc and consul-esm svc registered.
Click on the ext svc. It should be passing its health checks.
The http-check should be returning 200 OK.

#### Consul DNS
Setup Consul DNS on EKS to resolve the external service using Consul DNS.  Try the following Patch for a quick fix.
```
../scripts/patch_coredns_to_fwd_to_consul.sh
```
Refer to Hashicorp docs for more information on setting up DNS forwarding.

If Consul DNS is setup on EKS the new ext svc should now be resolveable from within EKS.
```
nslookup learn.service.consul
```

#### Deploy Fake-service to VM
In addition to the default `learn.hashicorp.com` example, you may want to verify something within your ecosystem.  Deploy fake-service to a VM that is outside K8s and not running a Consul agent so it acts as an external service.  In a new terminal ssh to the VM and do the following.
```
### Install fake-service
mkdir -p ${HOME}/fake-service/{central_config,bin,logs}
cd ${HOME}/fake-service/bin
wget https://github.com/nicholasjackson/fake-service/releases/download/v0.23.1/fake_service_linux_amd64.zip
unzip fake_service_linux_amd64.zip
chmod 755 ${HOME}/fake-service/bin/fake-service
```

Create the start script
```
cat >${HOME}/fake-service/start.sh <<-EOF
#!/bin/bash

# Start Web Service
export MESSAGE="Web RESPONSE"
export NAME="web"
export SERVER_TYPE="http"
export LISTEN_ADDR="0.0.0.0:8080"
nohup ./bin/fake-service > logs/fake-service.out 2>&1 &
EOF
```

Start fake-service
```
chmod 755 ${HOME}/fake-service/start.sh
cd ${HOME}/fake-service
./start.sh
```
This service will listen on port 8080 so review the security groups to ensure its routable from ESM.

##### Register fake-service (web)
Go to the original terminal with access to EKS and kubectl do the following:
```
cd ./examples/esm/k8s
```
Edit `web-ext.json` and replace 3 things.
* Node 
* Address
* Address in the http check definition

Save the file and register the external service.
```
CONSUL_HTTP_TOKEN="$(kubectl -n consul get secret consul-bootstrap-acl-token -o json | jq -r '.data.token'| base64 -d)"
CONSUL_HTTP_ADDR="$(kubectl -n consul get svc consul-expose-servers -o json | jq -r '.status.loadBalancer.ingress[].hostname'):8500"
curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data @web-ext.json ${CONSUL_HTTP_ADDR}/v1/catalog/register
```

##### Deregister fake-service (web)
```
CONSUL_HTTP_TOKEN="$(kubectl -n consul get secret consul-bootstrap-acl-token -o json | jq -r '.data.token'| base64 -d)"
CONSUL_HTTP_ADDR="$(kubectl -n consul get svc consul-expose-servers -o json | jq -r '.status.loadBalancer.ingress[].hostname'):8500"
Node=$(cat web-ext.json | jq -r '.Node')
Address=$(cat web-ext.json | jq -r '.Address')
ServiceID=$(cat web-ext.json | jq -r '.Service.ID')

#Deregister Service
curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data '{"Datacenter": "dc1","Node": "${Node}","ServiceID": "${ServiceID}"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister

#Deregister Node
curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data '{"Datacenter": "dc1","Node": "${Node}"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister
curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data '{"Node": "${Node}","Address": "${Address}"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister

```
### Deploy ESM on VM with Consul agent

Get Consul Information and Secrets first.
```
#Create CA Cert on VM from K8s secret
kubectl -n consul get secret consul-ca-cert --context consul1 -o json | jq -r '.data."tls.crt"' | base64 -d > /etc/consul.d/certs/ca.pem

# Set Env vars
DATACENTER="dc1"
GOSSIP_KEY=$(kubectl -n consul get secrets consul-gossip-encryption-key -o jsonpath='{.data.key}'| base64 -d)
RETRY_JOIN="$(kubectl -n consul get svc consul-expose-servers -o json | jq -r '.status.loadBalancer.ingress[].hostname')"
CONSUL_ACL_TOKEN=$(kubectl -n consul get secrets consul-bootstrap-acl-token -o jsonpath='{.data.token}'| base64 -d)
local_ip=`ip -o route get to 169.254.169.254 | sed -n 's/.*src \([0-9.]\+\).*/\1/p'`
```

Install Consul
```
## Install Consul - Ext K8s cluster requires awscli, kubctl, .kube and expose host ports
curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add -
apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
apt update && apt install -y consul-enterprise=1.16.0+ent-1 unzip jq awscli
snap install kubectl --classic
mkdir -p /etc/consul.d/certs
```

Modify the default consul.hcl file
```
cat > /etc/consul.d/consul.hcl <<- EOF
datacenter = "$DATACENTER"
data_dir = "/opt/consul"
server = false
client_addr = "0.0.0.0"
bind_addr = "0.0.0.0"
advertise_addr = "$local_ip"
retry_join = ["$RETRY_JOIN"]
encrypt = "$GOSSIP_KEY"
encrypt_verify_incoming = true
encrypt_verify_outgoing = true
log_level = "INFO"
ui = true
enable_script_checks = true
#verify_incoming = true
#verify_outgoing = true
#verify_server_hostname = true
ca_file = "/etc/consul.d/certs/ca.pem"
#cert_file = "/etc/consul.d/certs/client-cert.pem"
#key_file = "/etc/consul.d/certs/client-key.pem"
auto_encrypt = {
  tls = true
}

connect {
  enabled = true
}

ports {
  grpc = 8502
}
EOF
```
Support ACLs if enabled.  Update CONSUL_ACL_TOKEN.
```
cat >/etc/consul.d/client_acl.hcl <<- EOF
acl = {
  enabled = true
  #down_policy = "async-cache"
  #default_policy = "deny"
  #enable_token_persistence = true
  tokens {
    agent = "${CONSUL_ACL_TOKEN}"
  }
}
EOF
```

Configure systemd
```
cat >/etc/systemd/system/consul.service << EOF
[Unit]
Description="HashiCorp Consul Ent - A service mesh solution"
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/consul.d/consul.hcl

[Service]
EnvironmentFile=-/etc/consul.d/consul.env
User=consul
Group=consul
ExecStart=/usr/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

Start Consul
```
# Start Consul
systemctl enable consul.service
systemctl start consul.service
```

Point DNS to Consul's DNS
```
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/consul.conf <<- EOF
[Resolve]
DNS=127.0.0.1
Domains=~consul
EOF
iptables --table nat --append OUTPUT --destination localhost --protocol udp --match udp --dport 53 --jump REDIRECT --to-ports 8600
iptables --table nat --append OUTPUT --destination localhost --protocol tcp --match tcp --dport 53 --jump REDIRECT --to-ports 8600
systemctl restart systemd-resolved
```
### EKS -  Consul Helm Values
This chart installs Consul with the goal of supporting Service Discovery across multiple datacenters.  It enables connect-inject and mesh gateways to allow future Peering with remote Consul datacenters.  Peers can use Consul Prepared Queries for automatic failover of any service including onces monitored by ESM.
```
global:
  name: consul
  image: "hashicorp/consul-enterprise:1.16.0-ent"
  imageK8S: docker.mirror.hashicorp.services/hashicorp/consul-k8s-control-plane:1.2.0
  enableConsulNamespaces: true
  enterpriseLicense:
    secretName: 'consul-ent-license'
    secretKey: 'key'
    enableLicenseAutoload: true
  datacenter: dc1
  peering:
    enabled: true
  adminPartitions:
    enabled: true
    name: default

  # TLS configures whether Consul components use TLS.
  tls:
    enabled: true
    httpsOnly: false  # Metrics are exposed on 8500 only (http).  Anonymous policy requires Agent "read" if ACL enabled.
    enableAutoEncrypt: true  #Required if gossipEncryption uses autoGenerate: true
  acls:
    manageSystemACLs: true
  gossipEncryption:
    autoGenerate: true
  metrics:
    enabled: true
    enableGatewayMetrics: true
    enableAgentMetrics: true
    agentMetricsRetentionTime: "59m"

server:
  replicas: 3
  bootstrapExpect: 3
  exposeService:
    enabled: true
    type: LoadBalancer
    annotations: |
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb-ip"
  extraConfig: |
    {
      "log_level": "TRACE"
    }
  resources:
    requests:
      memory: "1461Mi" # 75% of 2GB Mem
      cpu: "1000m"
    limits:
      memory: "1461Mi"
      cpu: "1000m"
dns:
  enabled: true
  enableRedirection: true

syncCatalog:
  enabled: true
  toConsul: true
  toK8S: false
  k8sAllowNamespaces: ["*"]
  k8sDenyNamespaces: []
  consulNamespaces:
    mirroringK8S: true

# connectInject and meshGateway are required for Peering
connectInject:
  enabled: true
  default: false
meshGateway:
  enabled: true
  replicas: 1
  service:
    enabled: true
    type: LoadBalancer
    annotations: |
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb-ip"

ui:
  enabled: true
  service:
    enabled: true
    type: LoadBalancer
    annotations: |
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  metrics:
    enabled: true # by default, this inherits from the value global.metrics.enabled
    provider: "prometheus"
    baseURL: http://prometheus-server.default.svc.cluster.local
    #baseURL: http://prometheus-server.metrics.svc.cluster.local
```