#!/bin/bash

mkdir -p generated

export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export INSTALL_REGISTRY_USERNAME=$(cat values.yaml | grep tanzunet -A 3 | awk '/username:/ {print $2}')
export INSTALL_REGISTRY_PASSWORD=$(cat values.yaml  | grep tanzunet -A 3 | awk '/password:/ {print $2}')

kubectl run  nginx --image=nginx --wait && kubectl wait pod nginx --for condition=Ready --timeout=90s
kubectl exec -it nginx -- curl registry.tanzu.vmware.com
kubectl exec -it nginx -- curl registry.tanzu.vmware.com
kubectl exec -it nginx -- curl registry.tanzu.vmware.com
kubectl delete pod nginx

kubectl create ns tap-install
tanzu secret registry add tap-registry \
  --username ${INSTALL_REGISTRY_USERNAME} --password ${INSTALL_REGISTRY_PASSWORD} \
  --server ${INSTALL_REGISTRY_HOSTNAME} \
  --export-to-all-namespaces --yes --namespace tap-install
tanzu package repository add tanzu-tap-repository \
  --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$1 \
  --namespace tap-install
tanzu package repository get tanzu-tap-repository --namespace tap-install

ytt -f tap-values-run.yaml -f values.yaml -f values-prod.yaml --ignore-unknown-comments > generated/tap-values-prod.yaml


tanzu package install tap -p tap.tanzu.vmware.com -v $1 --values-file generated/tap-values-prod.yaml -n tap-install

# install external dns
kubectl create ns tanzu-system-ingress
ytt --ignore-unknown-comments -f values.yaml -f values-prod.yaml -f ingress-config/ | kubectl apply -f-

# configure developer namespace
DEVELOPER_NAMESPACE=$(cat values.yaml  | grep developer_namespace | awk '/developer_namespace:/ {print $2}')
kubectl create ns $DEVELOPER_NAMESPACE

export DEVELOPER_NAMESPACE=$(cat values.yaml  | grep developer_namespace | awk '/developer_namespace:/ {print $2}')
export CONTAINER_REGISTRY_HOSTNAME=$(cat values.yaml | grep container_registry -A 3 | awk '/hostname:/ {print $2}')
export CONTAINER_REGISTRY_USERNAME=$(cat values.yaml | grep container_registry -A 3 | awk '/username:/ {print $2}')
export CONTAINER_REGISTRY_PASSWORD=$(cat values.yaml | grep container_registry -A 3 | awk '/password:/ {print $2}')
tanzu secret registry delete registry-credentials --namespace ${DEVELOPER_NAMESPACE} --yes
tanzu secret registry add registry-credentials --username ${CONTAINER_REGISTRY_USERNAME} --password ${CONTAINER_REGISTRY_PASSWORD} --server ${CONTAINER_REGISTRY_HOSTNAME} --namespace ${DEVELOPER_NAMESPACE}

cat <<EOF | kubectl -n $DEVELOPER_NAMESPACE apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: tap-registry
  annotations:
    secretgen.carvel.dev/image-pull-secret: ""
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: e30K
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
secrets:
  - name: registry-credentials
  - name: git-https
imagePullSecrets:
  - name: registry-credentials
  - name: tap-registry
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-permit-deliverable
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: deliverable
subjects:
  - kind: ServiceAccount
    name: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-permit-workload
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: workload
subjects:
  - kind: ServiceAccount
    name: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: postgres-service-binding
  labels:
    resourceclaims.services.apps.tanzu.vmware.com/controller: "true" 
rules:
  - apiGroups: ["sql.tanzu.vmware.com"]
    resources: ["postgres"]
    verbs: ["get", "list", "watch","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: postgres-service-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: service-binding-postgres
subjects:
  - kind: ServiceAccount
    name: services-toolkit-controller-manager
    namespace: services-toolkit
EOF
