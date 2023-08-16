#!/bin/bash
SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

echo "Using Context: $(kubectl config current-context)"
echo
echo
if [[ -z ${CONSUL_HTTP_TOKEN} ]]; then
	CONSUL_HTTP_TOKEN="$(kubectl -n consul get secret consul-bootstrap-acl-token -o json | jq -r '.data.token'| base64 -d)"
	echo "Setting CONSUL_HTTP_TOKEN=${CONSUL_HTTP_TOKEN}"
else
	echo "CONSUL_HTTP_TOKEN=${CONSUL_HTTP_TOKEN}"
fi

if [[ -z ${CONSUL_HTTP_ADDR} ]]; then
	CONSUL_HTTP_ADDR="$(kubectl -n consul get svc consul-ui -o json | jq -r '.status.loadBalancer.ingress[].hostname'):80"
	echo "Setting CONSUL_HTTP_ADDR=${CONSUL_HTTP_ADDR}"
else
	echo "CONSUL_HTTP_ADDR=${CONSUL_HTTP_ADDR}"
fi
DATACENTER=$(curl --silent ${CONSUL_HTTP_ADDR}/v1/catalog/datacenters | jq -r '.[]')

list () {
	echo
	echo "curl --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" http://${CONSUL_HTTP_ADDR}/v1/query"
	curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" http://${CONSUL_HTTP_ADDR}/v1/query | jq -r
}

create () {
	curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" http://${CONSUL_HTTP_ADDR}/v1/query \
    --request POST \
    --data @- <<-EOF
{
  "Name": "schema-registry",
  "Service": {
    "Service": "schema-registry",
    "Failover": {
		"Targets": [
			{"Peer": "dc1-default"},
			{"Peer": "dc2-default"}
		]
    }
  }
}
EOF

}

delete () {
	echo
	echo "Delete PQ"
	PQ_ID=$(curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" http://${CONSUL_HTTP_ADDR}/v1/query | jq -r '.[].ID')
	echo "curl --request DELETE --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" http://${CONSUL_HTTP_ADDR}/v1/query/${PQ_ID}"
	curl --request DELETE --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" http://${CONSUL_HTTP_ADDR}/v1/query/${PQ_ID}
	echo
	echo "Listing PQ to verify its empty"
	curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" http://${CONSUL_HTTP_ADDR}/v1/query | jq -r
}

#Cleanup if any param is given on CLI
if [[ ! -z $1 ]]; then
	delete
else
    create
	#list
fi