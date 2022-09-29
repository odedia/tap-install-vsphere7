#!/bin/bash

mkdir -p generated

export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export INSTALL_REGISTRY_USERNAME=$(cat values.yaml | grep tanzunet -A 3 | awk '/username:/ {print $2}')
export INSTALL_REGISTRY_PASSWORD=$(cat values.yaml  | grep tanzunet -A 3 | awk '/password:/ {print $2}')

kubectl create ns tap-install
tanzu secret registry add tap-registry \
  --username ${INSTALL_REGISTRY_USERNAME} --password ${INSTALL_REGISTRY_PASSWORD} \
  --server ${INSTALL_REGISTRY_HOSTNAME} \
  --export-to-all-namespaces --yes --namespace tap-install
tanzu package repository add tanzu-tap-repository \
  --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$1 \
  --namespace tap-install
tanzu package repository get tanzu-tap-repository --namespace tap-install

ytt -f tap-values-view.yaml -f values.yaml -f values-view.yaml -f run-cluster-build.yaml -f run-cluster-iterate.yaml  --ignore-unknown-comments > generated/tap-values-view.yaml

tanzu package installed update --install tap -p tap.tanzu.vmware.com -v $1 --values-file generated/tap-values-view.yaml -n tap-install

until [ `kubectl get ns metadata-store --ignore-not-found | wc -l | tr -d ' '` = "2" ]; do echo "Waiting for metadata-store namespace to be created..."; sleep 5; done

# install external dns
kubectl create ns tanzu-system-ingress
ytt --ignore-unknown-comments -f values.yaml -f values-view.yaml -f ingress-config/ | kubectl apply -f-
ytt --ignore-unknown-comments -f values.yaml -f values-view.yaml -f ingress-config-view-cluster | kubectl apply -f-
