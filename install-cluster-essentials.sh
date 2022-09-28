#!/bin/bash

case "${1:linux}" in
	darwin) PRODUCT_ID=1263761;;
	linux) PRODUCT_ID=1105818;;
esac

if [ "`ls tanzu-cluster-essentials-$1-amd64-1.2.0.tgz 2> /dev/null | wc -l | tr -d ' '`" = "0" ]
then
	pivnet download-product-files --product-slug='tanzu-cluster-essentials' --release-version='1.2.0' --product-file-id=$PRODUCT_ID
else
	echo "tanzu-cluster-essentials-$1-amd64-1.2.0.tgz already exists, continuing with existing tarball. Delete if you want a new version.\n"
fi
mkdir tanzu-cluster-essentials

tar -xvf "tanzu-cluster-essentials-$1-amd64-1.2.0.tgz" -C tanzu-cluster-essentials

export INSTALL_BUNDLE=registry.tanzu.vmware.com/tanzu-cluster-essentials/cluster-essentials-bundle:1.2.0
export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export INSTALL_REGISTRY_USERNAME=$(cat values.yaml | grep tanzunet -A 3 | awk '/username:/ {print $2}')
export INSTALL_REGISTRY_PASSWORD=$(cat values.yaml  | grep tanzunet -A 3 | awk '/password:/ {print $2}')

cd tanzu-cluster-essentials
cp ../install-ce-fixed.sh ./install.sh
./install.sh
cd ..
