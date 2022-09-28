echo "Welcome to installation values preperation script"
echo "-------------------------------------------------\n"
echo "\nCreate a vSphere namespace called tap-ns."
echo "\nIf you're creating a production environment, also create a vSphere namespace called tap-prod-ns."
echo "\nReview the yamls under cluster-provisioning folder, since you might need to change it a bit for your env."
echo "They are currently setup for H2O environments."
echo "----------------------------------------------\n\n"
read -p "vCenter endpoint (sample-wcp.h2o-4-1111.site.com): " VCENTER_ENDPOINT
read -p "TAP Version to install (1.3.0): " TAP_VERSION

echo "\n\n*** You cannot install packages inside H2O env from projects.registry.vmware.com since it's unreachable :D. \nPlease provide another registry with write access such as gcr.io, your own harbor instance etc. ***"
read -p "Target repo with harbor install package (your-registry.com/tanzu-standard/pkg): " REPO_WITH_HARBOR_PACKAGE
echo "Please disconnect from VPN and run the following command to copy the package to the target registry:\n"
echo "\n imgpkg copy -b projects.registry.vmware.com/tkg/packages/standard/repo:v1.5.4-update.1 --to-repo=$REPO_WITH_HARBOR_PACKAGE"
read -p "Target OS (darwin / linux): " TARGET_OS
read -p "Deploy to prod? (Y/n): " DEPLOY_TO_PROD
if [ "$DEPLOY_TO_PROD" == "Y" ]
then
  read -p "vCenter production endpoint (prod-wcp.h2o-4-1112.site.com): " VCENTER_PROD_ENDPOINT
fi

cat <<EOF > install-values.yaml
install-values:
  vcenter_endpoint: $VCENTER_ENDPOINT
  repo_with_harbor_package_install: $REPO_WITH_HARBOR_PACKAGE
  tap_version: $TAP_VERSION
  target_os: $TARGET_OS
  vcenter_production_endpoint: $VCENTER_PROD_ENDPOINT
EOF

echo "General values"
echo "--------------\n"

read -p "Tanzunet Username (user@gmail.com): " TANZU_USERNAME
read -p "Tanzunet Password (12345): " TANZU_PASSWORD
echo "Create an IAM User in AWS with permissions for Route 53"
read -p "AWS Region (eu-west-1): " AWS_REGION
read -p "AWS Access key: " AWS_ACCESS_KEY
read -p "AWS Secret key: " AWS_SECRET_KEY

read -p "Container username (admin): " CONTAINER_USERNAME
read -p "Container password (password): " CONTAINER_PASSWORD
read -p "Developer namespace (demos): " DEVELOPER_NAMESPACE

read -p "Lets Encrypt ACME email for updates on expiring certificates (user@gmail.com): " ACME_EMAIL
read -p "Github Token for backstage (create one with read permissions at https://github.com/settings/tokens ): " GIT_BACKSTAGE_TOKEN

echo "\nLogin to Okta.com, and go to your org settings (usually https://dev-#######-admin.okta.com/admin/apps/active)"
echo "Create an app integration: Sign in method - OIDC OpenID Connect, Application type - Web Application.\n"
read -p "OpenID URL (for okta this is usually https://dev-########.okta.com/.well-known/openid-configuration): " OPENID_URL
read -p "OpenID ClientID: " OPENID_CLIENTID
read -p "OpenID Client Secret: " OPENID_CLIENTSECRET
echo "Create an S3 bucket and a corresponding IAM User according to: https://docs.vmware.com/en/VMware-Tanzu-Application-Platform/1.2/tap/GUID-tap-gui-techdocs-usage.html"
read -p "S3_BUCKET_NAME: " S3_BUCKET_NAME
read -p "S3_ACCESS_KEY: " S3_ACCESS_KEY
read -p "S3_SECRET_KEY: " S3_SECRET_KEY
echo "\nCreate a repository for gitops in github.com."
echo "Make sure you have the branch 'main' as the default branch, and 'prod' as another branch\n"
read -p "Gitops Repository name (tap-gitops): " GITOPS_REPO_NAME
read -p "Gitops Repository owner (your username in github such as 'odedia'): " GITOPS_REPO_OWNER
read -p "Github username for gitops (odedia): " GIT_OPS_USER
read -p "Github Token for gitops (create one with write permissions at https://github.com/settings/tokens): " GIT_OPS_TOKEN


echo "\nDomain setup"
echo "------------\n"

echo "Create a hosted zone at Route 53 (https://console.aws.amazon.com/route53)"
echo " for the iterate cluster and make sure your domain registrar points the NS records to this route 53 zone."
read -p "Iterate cluster sub-domain (iterate.mysite.com): " ITERATE_DOMAIN
read -p "Iterate cluster zone ID (ZAAAAAAAAAABBBBBBBBBB): " ITERATE_ZONE_ID


echo "\nCreate a hosted zone at Route 53 (https://console.aws.amazon.com/route53)"
echo "for the view cluster and make sure your domain registrar points the NS records to this route 53 zone."
read -p "View cluster sub-domain (view.mysite.com): " VIEW_DOMAIN
read -p "View cluster zone ID (ZAAAAAAAAAABBBBBBBBBB): " VIEW_ZONE_ID

cat <<EOF > values-view.yaml
#@data/values
---
ingress:
  domain: $VIEW_DOMAIN
aws:
  route_fifty_three_zone_id: $VIEW_ZONE_ID
EOF

cat <<EOF > values-iterate.yaml
#@data/values
---
ingress:
  domain: $ITERATE_DOMAIN
  tap-gui-domain: $VIEW_DOMAIN
aws:
  route_fifty_three_zone_id: $ITERATE_ZONE_ID
EOF

echo "\nCreate a hosted zone at Route 53 (https://console.aws.amazon.com/route53)"
echo "for the test cluster and make sure your domain registrar points the NS records to this route 53 zone."
read -p "Test cluster sub-domain (test.mysite.com): " TEST_DOMAIN
read -p "Test cluster zone ID (ZAAAAAAAAAABBBBBBBBBB): " TEST_ZONE_ID

cat <<EOF > values-test.yaml
#@data/values
---
ingress:
  domain: $TEST_DOMAIN
aws:
  route_fifty_three_zone_id: $TEST_ZONE_ID
EOF

if [ "$DEPLOY_TO_PROD" == "Y" ]
then
  echo "Create a hosted zone at Route 53 (https://console.aws.amazon.com/route53)"
  echo "for the production cluster and make sure your domain registrar points the NS records to this route 53 zone."
  read -p "Production cluster sub-domain (iterate.mysite.com): " PROD_DOMAIN
  read -p "Production cluster zone ID (ZAAAAAAAAAABBBBBBBBBB): " PROD_ZONE_ID
  echo "\n\n*** Uncomment the runClusters/prod section (lines 110-114) in tap-values-view.yaml!***\n\n"
else
  export PROD_DOMAIN = ""
  export PROD_ZONE_ID = ""
fi

cat <<EOF > values-prod.yaml
#@data/values
---
ingress:
  domain: $PROD_DOMAIN
aws:
  route_fifty_three_zone_id: $PROD_ZONE_ID
EOF


cat <<EOF > values.yaml
#@data/values
---
tanzunet:
  username: $TANZU_USERNAME
  password: $TANZU_PASSWORD
ingress:
  domain: from-overlay
  contour_tls_namespace: tanzu-system-ingress
  contour_tls_secret: contour-tls-delegation-cert
aws:
  region: $AWS_REGION
  route_fifty_three_zone_id: from-overlay
  credentials: # Note internal VMware users: CloudGate credentials will not have the necessary permissions to work
    accessKey: $AWS_ACCESS_KEY
    secretKey: $AWS_SECRET_KEY
container_registry:
  hostname: harbor.$ITERATE_DOMAIN
  username: $CONTAINER_USERNAME
  password: $CONTAINER_PASSWORD
developer_namespace: $DEVELOPER_NAMESPACE
acme:
  email: $ACME_EMAIL
backstage:
  authtoken: placeholder
  github_token: $GIT_BACKSTAGE_TOKEN
  openid:
    url: $OPENID_URL
    client_id: $OPENID_CLIENTID
    client_secret: $OPENID_CLIENTSECRET
    prompt: auto
  s3:
    bucket: $S3_BUCKET_NAME
    accessKey: $S3_ACCESS_KEY
    secretKey: $S3_SECRET_KEY
gitops:
  repo_name: $GITOPS_REPO_NAME
  repo_owner: $GITOPS_REPO_OWNER
  write_permissions_user: $GIT_OPS_USER
  github_token: $GIT_OPS_TOKEN
runclusters:
  iterate:
    url: placeholder
    token: placeholder
  test:
    url: placeholder
    token: placeholder
  build:
    url: placeholder
    token: placeholder
  prod:
    url: placeholder
    token: placeholder
EOF

eho "\n\nYou're all set! Run ./install-all.sh"