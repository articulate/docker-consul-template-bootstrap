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
    source /tmp/export-consul.sh
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
  export VAULT_TOKEN=$(curl --request POST \
    --data '{"jwt": "'"$KUBE_TOKEN"'", "role": "'"$SERVICE_NAME"'"}' \
    $VAULT_ADDR/v1/auth/kubernetes/login | jq -r '.auth.client_token')
fi

if [ ! "${VAULT_TOKEN}" ] && [ "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}" ]
then
  ROLE_NAME=$(curl -v 169.254.170.2$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI | jq -r '.RoleArn' | awk -F '/' '{ print $2 }')
  curl -X POST "http://$VAULT_ADDR/v1/auth/aws/login" -d '{"role":"${ROLE_NAME}","pkcs7":"'$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/pkcs7 | tr -d '\n')'","nonce":"5defbf9e-a8f9-3063-bdfc-54b7a42a1f95"}'



  export VAULT_TOKEN=$()
fi

if [ "${ENCRYPTED_VAULT_TOKEN}" ] && [ ! "${VAULT_TOKEN}" ]
then
  export VAULT_TOKEN=$(echo $ENCRYPTED_VAULT_TOKEN | base64 -d | aws kms decrypt --ciphertext-blob fileb:///dev/stdin --output text --query Plaintext --region $AWS_REGION | base64 -d)
fi

if [ ${VAULT_TOKEN} ] && [ ${CONSUL_ADDR} ] && [ ${VAULT_ADDR} ]
then
  if consul-template -consul-addr=$CONSUL_ADDR -vault-addr=$VAULT_ADDR -template=/consul-template/${CT_SERVICE_ENV}/export-vault.ctmpl:/tmp/export-vault.sh -once -max-stale=0
  then
    source /tmp/export-vault.sh
  else
    (>&2 echo "Vault $MISBEHAVING_NOTICE")
    exit 1
  fi
else
  (>&2 echo "VAULT_TOKEN or VAULT_ADDR are not set, skipping Vault exports")
fi

rm -f /tmp/export-vault.sh
rm -f /tmp/export-consul.sh

exec "$@"
