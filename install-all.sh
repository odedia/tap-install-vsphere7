export VCENTER_ENDPOINT=$(cat install-values.yaml | grep install-values -A 5 | awk '/vcenter_endpoint:/ {print $2}')
export TAP_VERSION=$(cat install-values.yaml | grep install-values -A 5 | awk '/tap_version:/ {print $2}')
export REPO_WITH_HARBOR_INSTALL=$(cat install-values.yaml | grep install-values -A 5 | awk '/repo_with_harbor_package_install:/ {print $2}')
export TARGET_OS=$(cat install-values.yaml | grep install-values -A 5 | awk '/target_os:/ {print $2}')
export VCENTER_PRODUCTION_ENDPOINT=$(cat install-values.yaml | grep install-values -A 5 | awk '/vcenter_production_endpoint:/ {print $2}')

kubectl config delete-context tap-ns 1  > /dev/null 2>&1
kubectl config delete-context tap-iterate  > /dev/null 2>&1
kubectl config delete-context tap-build  > /dev/null 2>&1
kubectl config delete-context tap-test > /dev/null 2>&1
kubectl config delete-context tap-prod  > /dev/null 2>&1

echo "\n\nInstalling iterate cluster...\n"

export DOMAIN=$(cat values-iterate.yaml  | grep domain | awk '/domain:/ {print $2}')

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns

kubectl config use-context tap-ns

kubectl apply -f ./cluster-provisioning/tap-iterate.yaml

until [ `kubectl get tkc tap-iterate -ojson | jq -r .status.phase` = "running" ]; do echo "Waiting for iterate cluster provisioning..."; sleep 10; done

sh install-cli.sh $TARGET_OS

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns \
--tanzu-kubernetes-cluster-name tap-iterate

kubectl config use-context tap-iterate

kubectl create clusterrolebinding default-tkg-admin-privileged-binding --clusterrole=psp:vmware-system-privileged --group=system:authenticated

sh install-cluster-essentials.sh $TARGET_OS

sh install-iterate.sh $TAP_VERSION

until [ `kubectl get secret -n tanzu-system-ingress cnr-contour-tls-delegation-cert --ignore-not-found | wc -l | tr -d ' '` = "2" ]; do echo "Waiting for certificates to propagate..."; sleep 10; done

kubectl get secret -n tanzu-system-ingress cnr-contour-tls-delegation-cert -oyaml > tmp.yaml

sed -r 's/cnr-contour-tls-delegation-cert/harbor-tls/;s/tanzu-system-ingress/tanzu-system-registry/' tmp.yaml > ./generated/harbor-tls.yaml

rm tmp.yaml

kubectl create namespace tanzu-system-registry

kubectl delete -f ./generated/harbor-tls.yaml 2> /dev/null
kubectl create -f ./generated/harbor-tls.yaml

kubectl create ns tanzu-standard

tanzu package repository add tanzu-standard \
  --url $REPO_WITH_HARBOR_INSTALL:v1.5.4-update.1  \
  --namespace tanzu-standard

ytt -f ./additional-config/harbor-values.yaml -f values.yaml --ignore-unknown-comments > ./generated/harbor-values.yaml

tanzu package installed update --install harbor \
    --namespace tanzu-standard \
    --package-name harbor.tanzu.vmware.com \
    --version 2.3.3+vmware.1-tkg.1 \
    --values-file ./generated/harbor-values.yaml

export EXTERNAL_IP=`kubectl get svc envoy -n tanzu-system-ingress -ojson | jq -r '.status.loadBalancer.ingress[0].ip'`

export AWS_ZONE_ID=$(cat values-iterate.yaml | grep aws: -A 2 | awk '/route_fifty_three_zone_id:/ {print $2}')

echo "\n\n Setting routing values for iterate cluster at Route53 for *.${DOMAIN} and *.apps.${DOMAIN} to: \n\n"  ${EXTERNAL_IP} "\n\n"

sed -r "s/APPS_FQDN/*.apps.${DOMAIN}/;s/ROOT_FQDN/*.${DOMAIN}/;s/INGRESS_IP_ADDRESS/${EXTERNAL_IP}/" route53-template.json > generated/route53-iterate.json

export AWS_ACCESS_KEY=$(cat values.yaml | grep aws: -A 5 | awk '/accessKey:/ {print $2}')
export AWS_SECRET_KEY=$(cat values.yaml | grep aws: -A 5 | awk '/secretKey:/ {print $2}')

AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY aws route53 change-resource-record-sets --hosted-zone-id $AWS_ZONE_ID --change-batch file://generated/route53-iterate.json --no-cli-auto-prompt > /dev/null

export CONTAINER_REGISTRY_HOSTNAME=$(cat values.yaml | grep container_registry: -A 4 | awk '/hostname:/ {print $2}')
export CONTAINER_REGISTRY_USERNAME=$(cat values.yaml | grep container_registry: -A 4 | awk '/username:/ {print $2}')
export CONTAINER_REGISTRY_PASSWORD=$(cat values.yaml | grep container_registry: -A 4 | awk '/password:/ {print $2}')

until [ "`host $CONTAINER_REGISTRY_HOSTNAME`" = "`echo $CONTAINER_REGISTRY_HOSTNAME has address $EXTERNAL_IP`" ]; do echo "Waiting for DNS cache to be updated..."; sleep 10; done

curl -u "$CONTAINER_REGISTRY_USERNAME:$CONTAINER_REGISTRY_PASSWORD" -H 'content-type: application/json' -v "https://$CONTAINER_REGISTRY_HOSTNAME/api/v2.0/projects" -d '{"project_name": "apps","public": true,"storage_limit": 0}'
curl -u "$CONTAINER_REGISTRY_USERNAME:$CONTAINER_REGISTRY_PASSWORD" -H 'content-type: application/json' -v "https://$CONTAINER_REGISTRY_HOSTNAME/api/v2.0/projects" -d '{"project_name": "build-service","public": true,"storage_limit": 0}'

tanzu package repository add tbs-full-deps-repository \
  --url registry.tanzu.vmware.com/tanzu-application-platform/full-tbs-deps-package-repo:1.7.1 \
  -n tap-install

tanzu package installed update --install full-tbs-deps -p full-tbs-deps.tanzu.vmware.com -v 1.7.1 -n tap-install

./install-additional-packages.sh

kubectl apply -f ./additional-config/tap-gui-viewer-service-account-rbac.yaml

CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

CLUSTER_TOKEN=$(kubectl -n tap-gui get secret $(kubectl -n tap-gui get sa tap-gui-viewer -o=json \
| jq -r '.secrets[0].name') -o=json \
| jq -r '.data["token"]' \
| base64 --decode)

cat <<EOF > ./generated/run-cluster-iterate.yaml
#@data/values
---
runclusters:
  iterate:
    url: ${CLUSTER_URL}
    token: ${CLUSTER_TOKEN}
EOF

kapp -y deploy --app rmq-operator --file https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml 2> /dev/null

kubectl config set-context --current --namespace=demos

echo "installing git-https..."
ytt -f ./additional-config/git-secret.yaml -f values.yaml --ignore-unknown-comments | kubectl apply -f-


kubectl create namespace service-instances

kubectl apply -f ./additional-config/rabbitmq-resource-claims.yaml
kubectl apply -f ./additional-config/rabbitmqcluster-clusterinstanceclass.yaml
kubectl apply -f ./additional-config/rabbitmq-claim-policy.yaml

echo "\n\nInstalling build cluster...\n"

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns

kubectl config use-context tap-ns

kubectl apply -f ./cluster-provisioning/tap-build.yaml

until [ `kubectl get tkc tap-build -ojson | jq -r .status.phase` = "running" ]; do echo "Waiting for build cluster provisioning..."; sleep 10; done

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns \
--tanzu-kubernetes-cluster-name tap-build

kubectl config use-context tap-build

kubectl create clusterrolebinding default-tkg-admin-privileged-binding --clusterrole=psp:vmware-system-privileged --group=system:authenticated

sh install-cluster-essentials.sh $TARGET_OS

sh install-build.sh $TAP_VERSION

tanzu package repository add tbs-full-deps-repository \
  --url registry.tanzu.vmware.com/tanzu-application-platform/full-tbs-deps-package-repo:1.7.1 \
  -n tap-install

tanzu package installed update --install full-tbs-deps -p full-tbs-deps.tanzu.vmware.com -v 1.7.1 -n tap-install

kubectl config set-context --current --namespace=demos

kubectl apply -f ./additional-config/scan-policy.yaml
kubectl apply -f ./additional-config/tekton-pipeline.yaml
kubectl apply -f ./additional-config/tap-gui-viewer-service-account-rbac.yaml
ytt -f ./additional-config/git-secret.yaml -f values.yaml --ignore-unknown-comments | kubectl apply -f-

CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

CLUSTER_TOKEN=$(kubectl -n tap-gui get secret $(kubectl -n tap-gui get sa tap-gui-viewer -o=json \
| jq -r '.secrets[0].name') -o=json \
| jq -r '.data["token"]' \
| base64 --decode)

cat <<EOF > generated/run-cluster-build.yaml
#@data/values
---
runclusters:
  build:
    url: ${CLUSTER_URL}
    token: ${CLUSTER_TOKEN}
EOF

echo "\n\nInstalling view cluster...\n"


kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns

kubectl config use-context tap-ns

kubectl apply -f ./cluster-provisioning/tap-view.yaml

until [ `kubectl get tkc tap-view -ojson | jq -r .status.phase` = "running" ]; do echo "Waiting for view cluster provisioning..."; sleep 10; done

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns \
--tanzu-kubernetes-cluster-name tap-view

kubectl config use-context tap-view

kubectl create clusterrolebinding default-tkg-admin-privileged-binding --clusterrole=psp:vmware-system-privileged --group=system:authenticated

sh install-cluster-essentials.sh $TARGET_OS

sh install-view.sh $TAP_VERSION

until [ `kubectl get secret -n tanzu-system-ingress cnr-contour-tls-delegation-cert --ignore-not-found | wc -l | tr -d ' '` = "2" ]; do echo "Waiting for certificates to propagate..."; sleep 10; done

export DOMAIN=$(cat values-view.yaml  | grep domain | awk '/domain:/ {print $2}')

export EXTERNAL_IP=`kubectl get svc envoy -n tanzu-system-ingress -ojson | jq -r '.status.loadBalancer.ingress[0].ip'`

echo "\n\n Setting routing values for view cluster at Route53 for *.${DOMAIN} to: \n\n"  ${EXTERNAL_IP} "\n\n"

sed -r "s/APPS_FQDN/*.apps.${DOMAIN}/;s/ROOT_FQDN/*.${DOMAIN}/;s/INGRESS_IP_ADDRESS/${EXTERNAL_IP}/" route53-template.json > generated/route53-view.json

export AWS_ZONE_ID=$(cat values-view.yaml | grep aws: -A 2 | awk '/route_fifty_three_zone_id:/ {print $2}')
export AWS_ACCESS_KEY=$(cat values.yaml | grep aws: -A 5 | awk '/accessKey:/ {print $2}')
export AWS_SECRET_KEY=$(cat values.yaml | grep aws: -A 5 | awk '/secretKey:/ {print $2}')

AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY aws route53 change-resource-record-sets --hosted-zone-id  $AWS_ZONE_ID --change-batch file://generated/route53-view.json --no-cli-auto-prompt > /dev/null

CA_CERT=$(kubectl get secret -n metadata-store ingress-cert -o json | jq -r ".data.\"ca.crt\"")

METADATA_STORE_SECRET_NAME=`kubectl get sa -n metadata-store metadata-store-read-write-client -oyaml -ojson | jq -r '.secrets[0].name'`

AUTH_TOKEN=$(kubectl get secrets $METADATA_STORE_SECRET_NAME -n metadata-store -o jsonpath="{.data.token}" | base64 -d)


cat <<EOF > generated/values-view-auth.yaml
#@data/values
---
backstage:
  authtoken: Bearer ${AUTH_TOKEN}
EOF

ytt -f tap-values-view.yaml -f values.yaml -f values-view.yaml -f generated/values-view-auth.yaml -f generated/run-cluster-build.yaml -f generated/run-cluster-iterate.yaml  --ignore-unknown-comments > generated/tap-values-view.yaml

tanzu package installed update --install tap -p tap.tanzu.vmware.com -v $TAP_VERSION --values-file generated/tap-values-view.yaml -n tap-install

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns \
--tanzu-kubernetes-cluster-name tap-build

kubectl create ns metadata-store-secrets

cat <<EOF | kubectl apply -f-
---
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: store-ca-cert
  namespace: metadata-store-secrets
data:
  ca.crt: $CA_CERT
EOF

kubectl delete secret store-auth-token -n metadata-store-secrets 2> /dev/null
kubectl create secret generic store-auth-token --from-literal=auth_token=$AUTH_TOKEN -n metadata-store-secrets

kubectl apply -f ./additional-config/secret-export.yaml

echo "\n\nInstalling test cluster..."

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns

kubectl config use-context tap-ns

kubectl apply -f ./cluster-provisioning/tap-test.yaml

until [ `kubectl get tkc tap-test -ojson | jq -r .status.phase` = "running" ]; do echo "Waiting for test cluster provisioning..."; sleep 10; done

sh install-cli.sh $TARGET_OS

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns \
--tanzu-kubernetes-cluster-name tap-test

kubectl config use-context tap-test

kubectl create clusterrolebinding default-tkg-admin-privileged-binding --clusterrole=psp:vmware-system-privileged --group=system:authenticated

sh install-cluster-essentials.sh $TARGET_OS

sh install-test.sh $TAP_VERSION

kubectl config set-context --current --namespace=demos

kubectl apply -f ./additional-config/tap-gui-viewer-service-account-rbac.yaml
ytt -f ./additional-config/git-secret.yaml -f values.yaml --ignore-unknown-comments | kubectl apply -f-

./install-additional-packages.sh

export DOMAIN=$(cat values-test.yaml  | grep domain | awk '/domain:/ {print $2}')

CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

CLUSTER_TOKEN=$(kubectl -n tap-gui get secret $(kubectl -n tap-gui get sa tap-gui-viewer -o=json \
| jq -r '.secrets[0].name') -o=json \
| jq -r '.data["token"]' \
| base64 --decode)

cat <<EOF > generated/run-cluster-test.yaml
#@data/values
---
runclusters:
  test:
    url: ${CLUSTER_URL}
    token: ${CLUSTER_TOKEN}
EOF

export EXTERNAL_IP=`kubectl get svc envoy -n tanzu-system-ingress -ojson | jq -r '.status.loadBalancer.ingress[0].ip'`

echo "\n\n Setting routing values for test cluster at Route53 for *.${DOMAIN} and *.apps.${DOMAIN} to: \n\n"  ${EXTERNAL_IP} "\n\n"

sed -r "s/APPS_FQDN/*.apps.${DOMAIN}/;s/ROOT_FQDN/*.${DOMAIN}/;s/INGRESS_IP_ADDRESS/${EXTERNAL_IP}/" route53-template.json > generated/route53-test.json

export AWS_ZONE_ID=$(cat values-test.yaml | grep aws: -A 2 | awk '/route_fifty_three_zone_id:/ {print $2}')
export AWS_ACCESS_KEY=$(cat values.yaml | grep aws: -A 5 | awk '/accessKey:/ {print $2}')
export AWS_SECRET_KEY=$(cat values.yaml | grep aws: -A 5 | awk '/secretKey:/ {print $2}')

AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY aws route53 change-resource-record-sets --hosted-zone-id $AWS_ZONE_ID --change-batch file://generated/route53-test.json --no-cli-auto-prompt > /dev/null

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns \
--tanzu-kubernetes-cluster-name tap-view

kubectl config use-context tap-view

ytt -f tap-values-view.yaml -f values.yaml -f values-view.yaml -f generated/values-view-auth.yaml -f generated/run-cluster-build.yaml -f generated/run-cluster-iterate.yaml -f generated/run-cluster-test.yaml --ignore-unknown-comments > generated/tap-values-view.yaml

tanzu package installed update --install tap -p tap.tanzu.vmware.com -v $TAP_VERSION --values-file generated/tap-values-view.yaml -n tap-install

if [ "$VCENTER_PRODUCTION_ENDPOINT" == "" ]
then
  echo "\n\nSkipping production cluster..."
else
  echo "\n\nInstalling production cluster..."

  KUBECTL_VSPHERE_PASSWORD=$KUBECTL_VSPHERE_PASSWORD_PROD kubectl vsphere login \
  --server $VCENTER_PRODUCTION_ENDPOINT \
  --insecure-skip-tls-verify \
  --vsphere-username administrator@vsphere.local \
  --tanzu-kubernetes-cluster-namespace tap-prod-ns

  kubectl config use-context tap-prod-ns

  kubectl apply -f ./cluster-provisioning/tap-prod.yaml

  until [ `kubectl get tkc tap-prod -ojson | jq -r .status.phase` = "running" ]; do echo "Waiting for production cluster provisioning..."; sleep 10; done

  sh install-cli.sh $TARGET_OS

  KUBECTL_VSPHERE_PASSWORD=$KUBECTL_VSPHERE_PASSWORD_PROD kubectl vsphere login \
  --server $VCENTER_PRODUCTION_ENDPOINT \
  --insecure-skip-tls-verify \
  --vsphere-username administrator@vsphere.local \
  --tanzu-kubernetes-cluster-namespace tap-prod-ns \
  --tanzu-kubernetes-cluster-name tap-prod

  kubectl config use-context tap-prod

  kubectl create clusterrolebinding default-tkg-admin-privileged-binding --clusterrole=psp:vmware-system-privileged --group=system:authenticated

  sh install-cluster-essentials.sh $TARGET_OS

  sh install-prod.sh $TAP_VERSION

  kubectl config set-context --current --namespace=demos

  kubectl apply -f ./additional-config/tap-gui-viewer-service-account-rbac.yaml
  ytt -f ./additional-config/git-secret.yaml -f values.yaml --ignore-unknown-comments | kubectl apply -f-

  ./install-additional-packages.sh

  export DOMAIN=$(cat values-prod.yaml  | grep domain | awk '/domain:/ {print $2}')

  CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

  CLUSTER_TOKEN=$(kubectl -n tap-gui get secret $(kubectl -n tap-gui get sa tap-gui-viewer -o=json \
  | jq -r '.secrets[0].name') -o=json \
  | jq -r '.data["token"]' \
  | base64 --decode)

  cat <<EOF > generated/run-cluster-prod.yaml
#@data/values
---
runclusters:
  prod:
    url: ${CLUSTER_URL}
    token: ${CLUSTER_TOKEN}
EOF

  export EXTERNAL_IP=`kubectl get svc envoy -n tanzu-system-ingress -ojson | jq -r '.status.loadBalancer.ingress[0].ip'`

  echo "\n\n Setting routing values for production cluster at Route53 for *.${DOMAIN} and *.apps.${DOMAIN} to: \n\n"  ${EXTERNAL_IP} "\n\n"

  sed -r "s/APPS_FQDN/*.apps.${DOMAIN}/;s/ROOT_FQDN/*.${DOMAIN}/;s/INGRESS_IP_ADDRESS/${EXTERNAL_IP}/" route53-template.json > generated/route53-prod.json

  export AWS_ZONE_ID=$(cat values-prod.yaml | grep aws: -A 2 | awk '/route_fifty_three_zone_id:/ {print $2}')
  export AWS_ACCESS_KEY=$(cat values.yaml | grep aws: -A 5 | awk '/accessKey:/ {print $2}')
  export AWS_SECRET_KEY=$(cat values.yaml | grep aws: -A 5 | awk '/secretKey:/ {print $2}')

  AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY aws route53 change-resource-record-sets --hosted-zone-id $AWS_ZONE_ID --change-batch file://generated/route53-prod.json --no-cli-auto-prompt > /dev/null

  kubectl vsphere login \
  --server $VCENTER_ENDPOINT \
  --insecure-skip-tls-verify \
  --vsphere-username administrator@vsphere.local \
  --tanzu-kubernetes-cluster-namespace tap-ns \
  --tanzu-kubernetes-cluster-name tap-view

  kubectl config use-context tap-view

  ytt -f tap-values-view.yaml -f values.yaml -f values-view.yaml -f generated/values-view-auth.yaml -f generated/run-cluster-build.yaml -f generated/run-cluster-iterate.yaml -f generated/run-cluster-test.yaml -f generated/run-cluster-prod.yaml --ignore-unknown-comments > generated/tap-values-view.yaml

  tanzu package installed update --install tap -p tap.tanzu.vmware.com -v $TAP_VERSION --values-file generated/tap-values-view.yaml -n tap-install
fi

echo "\n\nDeploying apps to iterate cluster...\n"

export DOMAIN=$(cat values-iterate.yaml  | grep domain | awk '/domain:/ {print $2}')

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns \
--tanzu-kubernetes-cluster-name tap-iterate

kubectl config use-context tap-iterate

echo "\n\nDeploying Hello World\n\n"

kubectl apply -f https://raw.githubusercontent.com/odedia/tanzu-java-web-app/main/config/workload.yaml

echo "\n\nDeploying Todos App\n\n"

kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/db/clusterinstanceclass.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/db/todos-db.yaml

tanzu services claimable list --class todos-db
tanzu service claim create todos-db-claim \
  --resource-name todos-db \
  --resource-kind Postgres \
  --resource-api-version sql.tanzu.vmware.com/v1
tanzu services claims get todos-db-claim --namespace demos

kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/config/workload.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-ui/main/config/workload.yaml

ytt -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/gateway.yaml \
    -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/httpproxy.yaml \
    -f ./values.yaml -f ./values-iterate.yaml --ignore-unknown-comments  | kubectl apply -f-


kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/backend-route.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/ui-route.yaml


echo "\n\nDeploying Acme Fitness\n\n"

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/authserver.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/clientreg.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/authserver-httpproxy.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/gateway.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/scg-httpproxy.yaml \
    -f ./values.yaml -f ./values-iterate.yaml --ignore-unknown-comments | kubectl apply -f-

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/cart-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/catalog-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/frontend-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/identity-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/order-route.yaml | kubectl apply -f-

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-cart/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-catalog/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-identity/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-order/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-payment/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-shopping/config/workload.yaml \
    -f ./values.yaml -f ./values-iterate.yaml --ignore-unknown-comments | kubectl apply -f-

echo "\n\nSubmitting apps to build cluster...\n"

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns \
--tanzu-kubernetes-cluster-name tap-build

kubectl config use-context tap-build

echo "\n\nSubmitting Hello World\n\n"

kubectl apply -f https://raw.githubusercontent.com/odedia/tanzu-java-web-app/main/config/workload.yaml

echo "\n\nSubmitting Todos App\n\n"

kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/config/workload.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-ui/main/config/workload.yaml

echo "\n\nSubmitting Acme Fitness\n\n"

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-cart/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-catalog/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-identity/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-order/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-payment/config/workload.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-shopping/config/workload.yaml \
    -f ./values.yaml -f ./values-iterate.yaml --ignore-unknown-comments | kubectl apply -f-

echo "\n\nDeploying apps to test cluster...\n"

export DOMAIN=$(cat values-test.yaml  | grep domain | awk '/domain:/ {print $2}')

kubectl vsphere login \
--server $VCENTER_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-ns \
--tanzu-kubernetes-cluster-name tap-test

kubectl config use-context tap-test

echo "\n\nDeploying Hello World\n\n"

kubectl apply -f https://raw.githubusercontent.com/odedia/tanzu-java-web-app/main/config/delivery-test.yaml

echo "\n\nDeploying Todos App\n\n"

kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/db/clusterinstanceclass.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/db/todos-db.yaml

tanzu services claimable list --class todos-db
tanzu service claim create todos-db-claim \
  --resource-name todos-db \
  --resource-kind Postgres \
  --resource-api-version sql.tanzu.vmware.com/v1
tanzu services claims get todos-db-claim --namespace demos

kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/config/delivery-test.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-ui/main/config/delivery-test.yaml

ytt -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/gateway.yaml \
    -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/httpproxy.yaml \
    -f ./values.yaml -f ./values-test.yaml --ignore-unknown-comments  | kubectl apply -f-


kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/backend-route.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/ui-route.yaml


echo "\n\nDeploying Acme Fitness\n\n"

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/authserver.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/clientreg.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/authserver-httpproxy.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/gateway.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/scg-httpproxy.yaml \
    -f ./values.yaml -f ./values-test.yaml --ignore-unknown-comments | kubectl apply -f-

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/cart-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/catalog-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/frontend-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/identity-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/order-route.yaml | kubectl apply -f-

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-cart/config/delivery-test.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-catalog/config/delivery-test.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-identity/config/delivery-test.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-order/config/delivery-test.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-payment/config/delivery-test.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-shopping/config/delivery-test.yaml \
    -f ./values.yaml -f ./values-test.yaml --ignore-unknown-comments | kubectl apply -f-


if [ "$VCENTER_PRODUCTION_ENDPOINT" == "" ]
then
  echo "\n\nSkipping production cluster..."
else
echo "\n\nDeploying apps to production cluster...\n"

export DOMAIN=$(cat values-prod.yaml  | grep domain | awk '/domain:/ {print $2}')

KUBECTL_VSPHERE_PASSWORD=$KUBECTL_VSPHERE_PASSWORD_PROD kubectl vsphere login \
--server $VCENTER_PRODUCTION_ENDPOINT \
--insecure-skip-tls-verify \
--vsphere-username administrator@vsphere.local \
--tanzu-kubernetes-cluster-namespace tap-prod-ns \
--tanzu-kubernetes-cluster-name tap-prod

kubectl config use-context tap-prod

echo "\n\nDeploying Hello World\n\n"

kubectl apply -f https://raw.githubusercontent.com/odedia/tanzu-java-web-app/main/config/delivery-prod.yaml

echo "\n\nDeploying Todos App\n\n"

kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/db/clusterinstanceclass.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/db/todos-db.yaml

tanzu services claimable list --class todos-db
tanzu service claim create todos-db-claim \
  --resource-name todos-db \
  --resource-kind Postgres \
  --resource-api-version sql.tanzu.vmware.com/v1
tanzu services claims get todos-db-claim --namespace demos

kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/config/delivery-prod.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-ui/main/config/delivery-prod.yaml

ytt -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/gateway.yaml \
    -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/httpproxy.yaml \
    -f ./values.yaml -f ./values-iterate.yaml --ignore-unknown-comments  | kubectl apply -f-


kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/backend-route.yaml
kubectl apply -f https://raw.githubusercontent.com/odedia/todo-service/main/scg/ui-route.yaml


echo "\n\nDeploying Acme Fitness\n\n"

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/authserver.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/clientreg.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/authserver-httpproxy.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/gateway.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/scg-httpproxy.yaml \
    -f ./values.yaml -f ./values-iterate.yaml --ignore-unknown-comments | kubectl apply -f-

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/cart-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/catalog-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/frontend-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/identity-route.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/scg/routes/order-route.yaml | kubectl apply -f-

ytt -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-cart/config/delivery-prod.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-catalog/config/delivery-prod.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-identity/config/delivery-prod.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-order/config/delivery-prod.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-payment/config/delivery-prod.yaml \
    -f https://raw.githubusercontent.com/odedia/acme-fitness-store/main/apps/acme-shopping/config/delivery-prod.yaml \
    -f ./values.yaml -f ./values-iterate.yaml --ignore-unknown-comments | kubectl apply -f-
fi


