#!/bin/bash

if [[ -z ${CONSUL_HTTP_TOKEN} ]]; then
	echo "Set CONSUL_HTTP_TOKEN Env Var"
	exit 1
fi

if [[ -z ${CONSUL_HTTP_ADDR} ]]; then
	CONSUL_HTTP_ADDR="k8s-consul-consulex-7705bc95be-bf790a9835fb29aa.elb.us-west-2.amazonaws.com:8500"
fi

echo "Register external service 'learn'"
curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data @external.json ${CONSUL_HTTP_ADDR}/v1/catalog/register
sleep 2
echo
echo "read service catalog"
curl ${CONSUL_HTTP_ADDR}/v1/catalog/service/learn | jq -r

echo "Check if consul-esm service returns metadata..."
curl ${CONSUL_HTTP_ADDR}/v1/catalog/service/consul-esm

echo
echo "nohup ./consul-esm -config-file=./consul-esm-config.hcl"
sudo nohup ./consul-esm -config-file=./consul-esm-config.hcl &