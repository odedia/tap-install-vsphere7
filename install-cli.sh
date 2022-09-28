#!/bin/bash

case "${1:linux}" in
	darwin) PRODUCT_ID=1310083;;
	linux) PRODUCT_ID=1310085;;
esac

if [ "`ls tanzu-framework-$1-amd64.tar 2> /dev/null | wc -l | tr -d ' '`" = "0" ]
then
	pivnet download-product-files --product-slug='tanzu-application-platform' --release-version='1.3.0-build.26' --product-file-id=$PRODUCT_ID
	mkdir tanzu
	tar -xvf "tanzu-framework-$1-amd64.tar" -C tanzu
	export TANZU_CLI_NO_INIT=true
	cd tanzu
	install "cli/core/v0.25.0/tanzu-core-$1_amd64" /usr/local/bin/tanzu
	tanzu version

	tanzu plugin install --local cli all
	tanzu plugin list
	cd ..
else
	echo "tanzu-framework-$1-amd64.tar already exists, continuing with existing tarball. Delete if you want a new version.\n"
fi