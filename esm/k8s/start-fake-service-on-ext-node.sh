#!/bin/bash

### Install fake-service
mkdir -p /opt/consul/fake-service/{central_config,bin,logs}
cd /opt/consul/fake-service/bin
wget https://github.com/nicholasjackson/fake-service/releases/download/v0.23.1/fake_service_linux_amd64.zip
unzip fake_service_linux_amd64.zip
chmod 755 /opt/consul/fake-service/bin/fake-service
chmod 1755 /opt/consul/fake-service/logs

# Start API Service
export MESSAGE="API RESPONSE"
export NAME="default-v1"
export SERVER_TYPE="http"
export LISTEN_ADDR="0.0.0.0:8080"
nohup ./bin/fake-service > logs/fake-service.out 2>&1 &