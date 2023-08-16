.PHONY: all init deploy plan destroy fmt clean
.PHONY: consul consul-info awslb consul-demo consul-dns consul-esm peer
SHELL:= /bin/bash
all: infra consul consul-demo
consul-demo: consul-dns consul-esm peer consul-info

fmt:
	@terraform fmt -recursive

init: fmt
	@terraform init

infra: init
	@terraform apply -auto-approve
	@echo "Source the following script to connect to all EKS clusters"
	@echo
	@echo "source ../../scripts/kubectl_connect_eks.sh ."

consul: awslb server

awslb:
	@../../scripts/install_awslb_controller.sh .

server:
	@terraform -chdir="consul_helm_values" init
	@terraform -chdir="consul_helm_values" apply -auto-approve

consul-info:
	@echo "Login to each Consul Server UI"
	@kubectl config use-context consul1
	@ ../../scripts/setConsulEnv.sh .
	@echo
	@kubectl config use-context consul2
	@ ../../scripts/setConsulEnv.sh .
	@echo
	@echo "README.md Next Steps..."
	@echo "Deploy fake-service, register external service, Test failover"

consul-dns:
	@kubectl config use-context consul1
	@ ../../scripts/patch_coredns_to_fwd_to_consul.sh
	@kubectl config use-context consul2
	@ ../../scripts/patch_coredns_to_fwd_to_consul.sh

consul-esm:
	@kubectl config use-context consul1
	@ ../../scripts/setConsulEnv.sh .
	@ ../../esm/k8s-with-agent/deploy.sh -f ../../esm/k8s-with-agent/svc-ext-dc1.json
	@kubectl config use-context consul2
	@ ../../scripts/setConsulEnv.sh .
	@ ../../esm/k8s-with-agent/deploy.sh -f ../../esm/k8s-with-agent/svc-ext-dc2.json

peer:
	@ ../../esm/peering/peer_dc1_to_dc2.sh

consul-clean:
	@ ../../examples/apps-2vpc-dataplane-ap-def/fake-service/deploy.sh delete
	@-terraform -chdir="consul_helm_values" destroy -auto-approve
	@- helm uninstall -n kube-system aws-load-balancer-controller eks/aws-load-balancer-controller
	@terraform destroy -auto-approve

destroy: init consul-clean
	@terraform destroy -auto-approve 

clean:
	-rm -rf .terraform/
	-rm .terraform.lock.hcl
	-rm terraform.tfstate*