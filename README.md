## Setup
1. Login using `az login`
1. Make sure `kubectl` is installed
1. Make sure `hey` is installed
1. Edit `./setup-infra.sh` to specify parameters
1. Run `./setup-infra.sh`
1. Update your Azure DNS name servers if necessary
1. Open <https://serverloader.[hostname]/workout> in a browser to generate and store a random string
1. Open <https://serverloader.[hostname]/stats> to show statistics
1. Run `hey -n 200000 -c 300 https://serverloader.<hostname>workout"` for a load test

## Clean-up
1. Run `az group delete -n <resource group name>`