#!/bin/bash

if [[ -z ${CONSUL_HTTP_TOKEN} ]]; then
	echo "Set CONSUL_HTTP_TOKEN Env Var"
	exit 1
fi

if [[ -z ${CONSUL_HTTP_ADDR} ]]; then
        CONSUL_HTTP_ADDR="k8s-consul-consulex-7705bc95be-bf790a9835fb29aa.elb.us-west-2.amazonaws.com:8500"
fi
sudo pkill consul-esm

#Deregister learn1 as an entity (aka: node), not a service.
curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data '{"Node": "hashicorp","Address": "learn.hashicorp.com"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister

#Deregister consul-esm: as an entity
curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data '{"Datacenter": "dc1","Node": "consul-server-0","ServiceID": "consul-esm:"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister

#Deregister consul-esm: service
curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT ${CONSUL_HTTP_ADDR}/v1/agent/service/deregister/consul-esm: