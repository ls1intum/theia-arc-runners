#!/bin/bash
set -e

NAMESPACE="squid"
SECRET_NAME="squid-ca-cert"
CN="Squid Proxy CA"

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get secret $SECRET_NAME -n $NAMESPACE > /dev/null 2>&1; then
    echo "Generating CA Certificate..."
    openssl req -new -newkey rsa:2048 -sha256 -days 3650 -nodes -x509 \
        -keyout squid-ca.key -out squid-ca.crt \
        -subj "/CN=$CN"

    kubectl create secret tls $SECRET_NAME \
        --cert=squid-ca.crt \
        --key=squid-ca.key \
        -n $NAMESPACE

    echo "CA Certificate created and stored in secret '$SECRET_NAME'"
    
    rm squid-ca.key squid-ca.crt
else
    echo "Secret '$SECRET_NAME' already exists."
fi
