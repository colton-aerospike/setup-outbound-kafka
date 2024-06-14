# setup-outbound-kafka
Bash script that leverages `aerolab` to deploy an Aerospike Database cluster, kafka cluster, and Aerospike Kafka Source connectors.

## Installation
```bash
git clone https://github.com/colton-aerospike/setup-outbound-kafka && cd setup-outbound-kafka
```

## Requirements
Ensure you have [aerolab](https://github.com/aerospike/aerolab) installed on your machine and [jq](https://jqlang.github.io/jq/download/) for proper functionality.


## Usage
```bash
Usage: setup_outbound_kafka.sh [ -n CLUSTER_NAME ] [ -c NUM_AEROSPIKE_NODES ] [ -k NUM_KAFKA_NODES ] [ -o NUM_OUTBOUND_NODES ] [ -I INSTANCE_TYPE ] [ -O INSTANCE_TYPE ] [ -R ] [ -L ] [ -f ] [ -g ] [ -h ]

Options:
  -c  Number of Aerospike Server DB nodes (Default: 1)
  -k  Number of Kafka Broker nodes (Default: 1)
  -o  Number of Outbound Connector nodes (Default: 1)
  -I  Instance type for Kafka servers (Default: c2d-highcpu-8)
  -O  Instance type for outbound connectors (Default: c2d-highcpu-8)
  -n  Name of Aerolab cluster to configure DC to ship to outbound connector (Default: mydc)
  -R  Clean up clients and clusters deployed
  -L  Gather logs from all instances and store in the specified directory (Default: ./logs/)
  -f  Recreate files
  -g  Grow the instances horizontally (MUST have already running instances)
  -h  Display this help message
```
## Deployment Example
The below deploys 6 kafka-brokers, 6 outbound connectors, and 12 Aerospike server nodes
```bash
./setup_outbound_kafka.sh -k 6 -o 6 -c 12 -n mydc
```

## Grow the Instances
Scale the outbound connectors by 2 and kafka servers by 1 horizontally
```bash
setup_outbound_kafka.sh -o 2 -k 1 -g -n mydc
```

## Add single outbound connector only
```bash
setup_outbound_kafka.sh -o 1 -k 0 -n mydc
```

## Recreate Files
Make changes to the config files within the main body of the script then trigger the recreation of files to upload and run.
```bash
./setup_outbound_kafka.sh -f 
```

Re-deploy and restart the service(s).
```bash
aerolab client attach -lall --parallel -n kafka-server -- /opt/kafka-quickstart deploy
aerolab client attach -lall --parallel -n kafka-server -- /opt/kafka-quickstart restart
```

## Gather logs

```bash
setup_outbound_kafka.sh -l -n mydc -d my-logs
```

## Destroy the Deployments
```bash
./setup_outbound_kafka.sh -R -n mydc
``` 