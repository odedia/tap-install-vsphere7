tanzu package repository add scg-package-repository \
    --namespace tap-install \
    --url registry.tanzu.vmware.com/spring-cloud-gateway-for-kubernetes/scg-package-repository:1.1.7

tanzu package installed update --install spring-cloud-gateway \
    --namespace tap-install \
    --package-name spring-cloud-gateway.tanzu.vmware.com \
    --version 1.1.7

tanzu package repository add tanzu-data-services-repository \
  --url registry.tanzu.vmware.com/packages-for-vmware-tanzu-data-services/tds-packages:1.1.0 \
  -n tap-install

tanzu package installed update --install postgres-operator --package-name postgres-operator.sql.tanzu.vmware.com --version 1.8.0 \
  -n tap-install \
  -f ./additional-config/postgres-operator-values.yaml

helm repo add bitnami https://charts.bitnami.com/bitnami
helm upgrade --install redis bitnami/redis --version 16.12.2 --set "replica.replicaCount=0"
