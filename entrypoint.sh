#!/bin/bash -e

AWS_REGION="${AWS_REGION:-us-east-1}"
if [ "${APP_ENV}" != "" ]; then
  (>&2 echo "Using deprecated APP_ENV, please swap to SERVICE_ENV")
  export SERVICE_ENV="${APP_ENV}"
fi
if [ "${APP_NAME}" != "" ]; then
  (>&2 echo "Using deprecated APP_NAME, please swap to SERVICE_NAME")
  export SERVICE_NAME="${APP_NAME}"
fi
if [ "${APP_PRODUCT}" != "" ]; then
  (>&2 echo "Using deprecated APP_PRODUCT, please swap to SERVICE_PRODUCT")
  export SERVICE_PRODUCT="${APP_PRODUCT}"
fi

# This will return everything before a - chararacter.
# "peer-something-thing" => "peer"
CT_SERVICE_ENV="${SERVICE_ENV%%-*}"

MISBEHAVING_NOTICE="may be misbehaving. In a perfect world, our monitoring detected this problem and Platform Engineering was alerted... but just in case, please let us know."

if [ ${CONSUL_ADDR} ]
then
  if consul-template -consul-addr=$CONSUL_ADDR -template=/consul-template/${CT_SERVICE_ENV}/export-consul.ctmpl:/tmp/export-consul.sh -once -max-stale=0
  then
    # We'll want to source the export-consul.sh immediately for the dev environment only so env vars
    # from consul that are needed for dev vault bootstrapping are available to the vault template.
    # We also want to delay other environments from sourcing export-consul.sh until the vault template gets generated
    # so consul env vars don't override vault env vars.
    if [ "$CT_SERVICE_ENV" == "dev" ]; then source /tmp/export-consul.sh; fi
  else
    (>&2 echo "Consul $MISBEHAVING_NOTICE")
    exit 1
  fi
else
  (>&2 echo "CONSUL_ADDR are not set skipping Consul exports")
fi

if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]
then
  KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  vault_token="null"
  attempts=1
  while [ "${attempts}" -le 10 ]; do
    echo "Attempt number ${attempts} to get vault token..."
    vault_token=$(curl --request POST \
      --data '{"jwt": "'"$KUBE_TOKEN"'", "role": "'"$SERVICE_NAME"'"}' \
      $VAULT_ADDR/v1/auth/kubernetes/login | jq -r '.auth.client_token');
    if [[ "${vault_token}" != "null" ]]; then
       break
    fi
    ((attempts+=1))
    sleep 3
  done

  if [[ "${vault_token}" == "null" ]]; then
    echo "Failed to get vault token via kubernetes"
    exit 1
  fi
  export VAULT_TOKEN=${vault_token}
fi

if [ "${ENCRYPTED_VAULT_TOKEN}" ] && [ ! "${VAULT_TOKEN}" ]
then
  export VAULT_TOKEN=$(echo $ENCRYPTED_VAULT_TOKEN | base64 -d | aws kms decrypt --ciphertext-blob fileb:///dev/stdin --output text --query Plaintext --region $AWS_REGION | base64 -d)
fi

if [ ! "${VAULT_TOKEN}" ] && [ "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}" ]
then
  export VAULT_TOKEN=$(vault login -method=aws -token-only)
fi

if [ ${VAULT_TOKEN} ] && [ ${CONSUL_ADDR} ] && [ ${VAULT_ADDR} ]
then
  if consul-template -consul-addr=$CONSUL_ADDR -vault-addr=$VAULT_ADDR -template=/consul-template/${CT_SERVICE_ENV}/export-vault.ctmpl:/tmp/export-vault.sh -once -max-stale=0
  then
    if [ "$CT_SERVICE_ENV" == "dev" ]; then source /tmp/export-vault.sh; fi
  else
    (>&2 echo "Vault $MISBEHAVING_NOTICE")
    exit 1
  fi
else
  (>&2 echo "VAULT_TOKEN or VAULT_ADDR are not set, skipping Vault exports")
fi

# Source the consul and vault export scripts after both have been created 
# so vault env vars take precedence over consul ones in non-dev environments
if [ "$CT_SERVICE_ENV" != "dev" ]; then
  source /tmp/export-consul.sh;
  source /tmp/export-vault.sh;
fi

rm -f /tmp/export-vault.sh
rm -f /tmp/export-consul.sh

exec "$@"
