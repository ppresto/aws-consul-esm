#!/bin/bash
SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
EXT_SERVICE_JSON="learn-ext.json"
#EXT_SERVICE_JSON="web-ext.json"

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
	CONSUL_HTTP_ADDR="$(kubectl -n consul get svc consul-expose-servers -o json | jq -r '.status.loadBalancer.ingress[].hostname'):8500"
	echo "Setting CONSUL_HTTP_ADDR=${CONSUL_HTTP_ADDR}"
else
	echo "CONSUL_HTTP_ADDR=${CONSUL_HTTP_ADDR}"
fi

ESM_DATA=$(curl ${CONSUL_HTTP_ADDR}/v1/catalog/service/consul-esm)

deploy () {
	# echo "Registering external service - learn"
	# curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data @${SCRIPT_DIR}/external.json ${CONSUL_HTTP_ADDR}/v1/catalog/register
	# sleep 2
	# echo

	# echo "Reading service catalog /learn"
	# curl ${CONSUL_HTTP_ADDR}/v1/catalog/service/learn | jq -r
	# echo

	echo "Check if consul-esm service returns metadata..."
	curl --silent ${CONSUL_HTTP_ADDR}/v1/catalog/service/consul-esm | jq -r
	echo

	echo "Deploying consul-esm service for remote connectivity"
	kubectl apply -f ${SCRIPT_DIR}/consul-esm-expose-server-0.yaml
	kubectl -n consul wait --for=condition=ready svc -l statefulset.kubernetes.io/pod-name=consul-server-0
	CONSUL_SERVER_0_URL="$(kubectl -n consul get svc consul-expose-server-0 -o json | jq -r '.status.loadBalancer.ingress[].hostname'):8500"

	echo
	echo "Deploying consul-esm"
	#kubectl apply -f ${SCRIPT_DIR}/consul-esm.yaml
	sed "s/CONSUL_SERVER_0_URL/${CONSUL_SERVER_0_URL}/g" ${SCRIPT_DIR}/consul-esm.yaml | kubectl apply -f -
	echo

	echo
	echo "Deploying ${EXT_SERVICE_JSON} - http-check"
	curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data @${SCRIPT_DIR}/${EXT_SERVICE_JSON} ${CONSUL_HTTP_ADDR}/v1/catalog/register
	sleep 2
	echo
	echo "WARN:  A new external service endpoint may take a few minutes to resolve in DNS"
}
node_data() {
  Node=$(cat ${SCRIPT_DIR}/${EXT_SERVICE_JSON} | jq -r '.Node')
  Address=$(cat ${SCRIPT_DIR}/${EXT_SERVICE_JSON} | jq -r '.Address')
  cat <<EOF
{
  "Node": "$Node",
  "Address": "$Address"
}
EOF
}

consul_esm_data() {
  Node="consul-server-0"
  Address="$(echo ${ESM_DATA} | jq -r '.[].Address')"
  ServiceID="$(echo ${ESM_DATA} | jq -r '.[].ServiceID')"
  #Instance="$(echo ${ESM_DATA} | jq -r '.[].Node')"
  cat <<EOF
{
  "Node": "$Node",
  "Address": "$Address",
  "ServiceID": "$ServiceID"
}
EOF
}
delete () {
	#Deregister learn1 as an entity (aka: node), not a service.
	# curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data '{"Node": "hashicorp","Address": "learn.hashicorp.com"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister

	Node=$(cat ${SCRIPT_DIR}/${EXT_SERVICE_JSON} | jq -r '.Node')
	Address=$(cat ${SCRIPT_DIR}/${EXT_SERVICE_JSON} | jq -r '.Address')
	ServiceID=$(cat ${SCRIPT_DIR}/${EXT_SERVICE_JSON} | jq -r '.Service.ID')
	
	# deregister node
	echo "Deleting Service Node"
	#echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data '{\"Datacenter\": \"dc1\",\"Node\": \"${Node}\"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister"
	echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data '{\"Node\": \"${Node}\",\"Address\": \"${Address}\"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister"
	curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data "$(node_data)" ${CONSUL_HTTP_ADDR}/v1/catalog/deregister
	
	#curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data '{"Node": "${Node}","Address": "${Address}"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister
	echo $(node_data)
	sleep 5

	#Deregister service entity
	echo "Deleting Service consul-esm"
	curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data "$(consul_esm_data)"  ${CONSUL_HTTP_ADDR}/v1/catalog/deregister
	#echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data "$(consul_esm_data)"  ${CONSUL_HTTP_ADDR}/v1/catalog/deregister"
	echo $(consul_esm_data)
	
	#curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT ${CONSUL_HTTP_ADDR}/v1/agent/service/deregister/web1
	# curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT ${CONSUL_HTTP_ADDR}/v1/agent/check/deregister/http-check
	# curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT ${CONSUL_HTTP_ADDR}/v1/agent/check/deregister/externalNodeHealth
	kubectl delete -f ${SCRIPT_DIR}/consul-esm.yaml
	kubectl delete -f ${SCRIPT_DIR}/consul-esm-expose-server-0.yaml
}

#Cleanup if any param is given on CLI
if [[ ! -z $1 ]]; then
	delete
else
    deploy
fi