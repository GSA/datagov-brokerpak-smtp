#!/bin/bash

set -e

export SERVICE_INFO=$(echo "eden --client user --client-secret pass --url http://127.0.0.1:8080 credentials -b binding -i ${INSTANCE_NAME:-instance-${USER}}")

domain=`$SERVICE_INFO | jq -r '.domain_arn | split("/")[1]'`

echo "Running tests on ${domain}..."

if [ "$domain" = "test.com" ]; then
  export output=`$SERVICE_INFO | jq '. | select(.required_records != null)'`
  if [ -z "$output" ]; then
    echo "Failed"
  else
    echo "Records outputted successfully"
  fi
else

  echo "Is dmarc valid?"
  checkdmarc $domain | jq '.dmarc'
  checkdmarc $domain | jq --exit-status '.dmarc.valid'

  echo "Is spf valid?"
  checkdmarc $domain | jq '.spf'
  checkdmarc $domain | jq --exit-status '.spf.valid'

fi
