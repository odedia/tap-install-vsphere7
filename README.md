# Unofficial TAP installer for vSphere 7 with Tanzu

This installation guide should help you to install a multi-cluster setup of TAP with wildcard certificates and [external-dns](https://github.com/kubernetes-sigs/external-dns) to a a vSphere 7 with Tanzu environment. It will:

- Provision 4 vSphere 7 with Tanzu Kubernetes clusters: tap-iterate (iterate profile), tap-build (build profile), tap-view (view profile), tap-test (run profile for a QA/Testing env)
- Optionally provision a separate "production" cluster on a separate (or the same...) vSphere with Tanzu environment.
- Install Harbor registry on the iterate cluster
- Take care of all auth tokens, SecretExports and all the boilerplate that is required to get a multi-cluster setup working
- Have signed Let's encrypt certificates for all environments
- Deploy 3 sample applications end-to-end: Hello World, Todos App, Acme Fitness
- Hopefully this installation is fully idempotent, meaning you can rerun the script over and over and it will just update relevant resources. Please open issues or submit PRs if you see otherwise.
- Nothing fancy regarding Infrastructure as Code, Github Actions, or other advanced use cases: I tried to make this as simple and as readable.

## Requirements:
- At least one vSphere 7 with Tanzu environment. Since some demo environments are extremely limited in available IP addresses, the installation defaults to a single control-plane node and a single worker node per cluster (each with a LOT of CPU and memory), but you can customize the Tanzu Kubernetes Cluster yaml files as you see fit under the `cluster-provisioning` folder. 
- Access to AWS S3 (for tech docs), AWS IAM (for configuring routes and S3 buckets) and AWS Route53 (to create hosted zones). Even though the clusters are on-prem (and may even be behind a VPN), we utilize Route 53 for DNS forwarding and Let's Encrypt certificate generation.
- Access to a domain registrar that can forward NS records to AWS Route53. I *highly* recommend domains.google.

## Installation instructions:
1. Create a vSphere with Tanzu namespace called `tap-ns`. Give yourself proper permissions.
2. If you're deploying to a prod environment, create a vSphere with Tanzu namespace called `tap-prod-ns` in that environment. Note that it can be the same environment for demo purposes if you have the capacity.
run ./prepare-install-properties.sh and follow the instructions. In the end of the script you'll be asked to run ./install-all.sh. That's it!

## Call for action
Would appriciate PRs around the following topics:
- Currently the DNS wildcard forwarding has to be done manually. The script tells you what to do and waits for approval. If you are good at using ExternalDNS, please update the yamls and submit a PR.
- Currently ytt overlays are *really* hacky. They basically non-existant, there's an extry at the top YTT values file with `from-overlay` value that needs to be overridden by other yaml files. If you're good with YTT overlays, please fix these and submit a PR. Thanks!

