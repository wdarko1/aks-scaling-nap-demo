## Setup
1. Login using `az login`
1. Make sure `kubectl` is installed
1. Make sure `hey` is installed (https://github.com/rakyll/hey)
1. Run `./run.sh`

## Exposed endpoints
1. `/workout`: generates long strings and stores them in memory
1. `/metrics`: Prometheus metrics
1. `/stats`: .NET stats