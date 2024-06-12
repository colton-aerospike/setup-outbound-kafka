#!/bin/bash
set -o errexit

function createOutboundAndKafkaClient {
    if [[ $GROW -eq 1 ]]; then
        INVENTORY=$(aerolab inventory list -j)
        if [[ $OUTBOUND_NODE_CT -gt 0 ]]; then
            OUTBOUND_DEPLOYED_CT=$(jq -r '.Clients[] | select(.ClientName | contains("outbound-connector")).PrivateIp' <<< "$INVENTORY" | wc -l)
            echo "Growing outbound-connectors by $OUTBOUND_NODE_CT"
            aerolab client grow none -n outbound-connector -c $OUTBOUND_NODE_CT --disk=pd-ssd:110 --instance $O_INSTANCE --zone $ZONE
        fi
        if [[ $KAFKA_NODE_CT -gt 0 ]]; then
            KAFKA_DEPLOYED_CT=$(jq -r '.Clients[] | select(.ClientName | contains("kafka-server")).PrivateIp' <<< "$INVENTORY" | wc -l)
            echo "Growing kafka-servers by $KAFKA_NODE_CT"
            aerolab client grow none -n kafka-server -c $KAFKA_NODE_CT --disk=pd-ssd:110 --disk=local-ssd --instance $K_INSTANCE --zone $ZONE
        fi
        if [[ $OUTBOUND_NODE_CT -gt 0 || $KAFKA_NODE_CT -gt 0 ]]; then
            recreateFiles 
            runInstallerScripts $OUTBOUND_DEPLOYED_CT $KAFKA_DEPLOYED_CT
            deployAerospikeCluster $OUTBOUND_NODE_CT
        fi
        return
    fi
    echo "Creating outbound-connector instance"
    aerolab client create none -n outbound-connector -c $OUTBOUND_NODE_CT --disk=pd-ssd:110 --instance $O_INSTANCE --zone $ZONE #--start-script=outbound-quickstart.sh
    echo "Creating kafka-server instance"
    aerolab client create none -n kafka-server -c $KAFKA_NODE_CT --disk=pd-ssd:110 --disk=local-ssd --instance $K_INSTANCE --zone $ZONE #--start-script=kafka-quickstart.sh
}

function createKafkaStartupScript {
    # Extract IP addresses using jq
    ips=$(jq -r '.Clients[] | select(.ClientName | contains("kafka-server")).PrivateIp' <<< "$INVENTORY")

    # Initialize arrays
    zookeepers=()
    zkservers=()

    server_number=1

    # Iterate through each IP address and append the ports
    for ip in $ips; do
        zookeepers+=("${ip}:2181")
        zkservers+=("server.${server_number}=${ip}:2888:3888")
        server_number=$((server_number + 1))
    done

    # Join the array elements into a comma-separated string and new line separated string
    zookeepers_string=$(IFS=,; echo "${zookeepers[*]}")
    zkserver_string=$(IFS=$'\n'; echo "${zkservers[*]}")

    cat <<EOF > kafka-quickstart.sh
#!/bin/bash

function getLatestKafkaURL {
    base_url="https://downloads.apache.org/kafka/"
    latest_version=\$(curl -s "\$base_url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -rV | head -n 1)
    scala_version=\$(curl -s "\$base_url\$latest_version/" | grep -oE '2\.[0-9]+' | sort -rV | head -n 1)
    kafka_url="\$base_url\$latest_version/kafka_\$scala_version-\$latest_version.tgz"
    echo "\$kafka_url"
}

function setupDiskAndMount {
    local device="\$1"
    local mount_point="\$2"
    
    mkfs.xfs \$device
    mkdir -p \$mount_point
    mount -o defaults,noatime \$device \$mount_point
    echo "\$device \$mount_point xfs defaults,noatime 0 0" >> /etc/fstab
}

function configureEnv {
    apt update && apt install -y default-jre curl
    kafka_url=\$(getLatestKafkaURL)

    # Setup the disk and mount point
    setupDiskAndMount /dev/nvme0n1 /data/kafka
    
    mkdir -p /var/log/kafka/
    mkdir -p /var/lib/zookeeper
    mkdir /kafka 
    cd /kafka
    
    curl "\$kafka_url" -o /tmp/kafka.tgz
    echo "\$kafka_url"
    tar xzvf /tmp/kafka.tgz --strip 1

    kafka_ip=\$(ip a s | egrep 'inet.*/32' | awk '{print \$2}' | cut -d'/' -f1)
    hostname=\$(hostname | cut -d- -f3)
    sed -i \
        -e "s/^#advertised.listener.*/advertised.listeners=PLAINTEXT:\/\/\$kafka_ip:9092/" \
        -e 's/^log.dirs=.*/log.dirs=\/data\/kafka/' \
        -e "s/^broker.id=0/broker.id=\$hostname/" \
        -e "s/^zookeeper.connect=.*/zookeeper.connect=$zookeepers_string/" \
        -e 's/^num.partitions=.*/num.partitions=40/' \
        /kafka/config/server.properties

    echo -e "replication.factor=3\ndelete.topic.enable = true" >> /kafka/config/server.properties

    sed -i 's/^dataDir=.*/dataDir=\/var\/lib\/zookeeper/' /kafka/config/zookeeper.properties
    echo -e "initLimit=10\nsyncLimit=5\n$zkserver_string" >> /kafka/config/zookeeper.properties

    echo \$hostname > /var/lib/zookeeper/myid

    touch /opt/kafka_installed
}


# Note to self: Can validate zookeeper sees all brokers by the following command:
# bin/zookeeper-shell.sh localhost:2181 ls /brokers/ids
function startServerAndZookeeper {
    if pgrep -f zookeeper.properties > /dev/null; then
        echo "Zookeeper already running."
    else
        # Start Zookeeper
        echo "Starting Zookeeper server..."
        nohup /kafka/bin/zookeeper-server-start.sh /kafka/config/zookeeper.properties > /var/log/kafka/zookeeper.log 2>&1 &
        sleep 5

        # Check if Zookeeper is running
        if pgrep -f zookeeper.properties > /dev/null; then
            echo "Zookeeper started successfully. PID: \$(pgrep -f zookeeper.properties)"
        else
            echo "Failed to start Zookeeper. Check /var/log/kafka/zookeeper.log for details."
            exit 1
        fi
    fi

    if pgrep -f server.properties > /dev/null; then
        echo "Kafka already running."
    else
        # Start Kafka
        echo "Starting Kafka server..."
        if pgrep -f server.properties > /dev/null; then
            echo "Kafka is already running. Ignoring."
        else
            nohup /kafka/bin/kafka-server-start.sh /kafka/config/server.properties > /var/log/kafka/kafka.log 2>&1 &
            sleep 10

            # Check if Kafka is running
            if pgrep -f server.properties > /dev/null; then
                echo "Kafka started successfully. PID: \$(pgrep -f server.properties)"
            else
                echo "Kafka didn't seem to start... Retrying in 5 seconds..."
                sleep 5
                nohup /kafka/bin/kafka-server-start.sh /kafka/config/server.properties > /var/log/kafka/kafka.log 2>&1 &
                sleep 5
                if pgrep -f server.properties > /dev/null; then
                    echo "Kafka started successfully on retry. PID: \$(pgrep -f server.properties)"
                else
                    echo "Failed to start Kafka. Check /var/log/kafka/kafka.log for details."
                    exit 1
                fi
            fi
        fi
    fi
}


function stopServerAndZookeeper {
    echo "Stopping Kafka and Zookeeper servers..."

    kafka_pids=\$(pgrep -f server.properties)
    zookeeper_pids=\$(pgrep -f zookeeper.properties)

    if [[ -n "\$kafka_pids" ]]; then
        echo "Killing Kafka PIDs: \$kafka_pids"
        kill -9 \$kafka_pids
    else
        echo "No Kafka server.properties process found."
    fi

    if [[ -n "\$zookeeper_pids" ]]; then
        echo "Killing Zookeeper PIDs: \$zookeeper_pids"
        kill -9 \$zookeeper_pids
    else
        echo "No Zookeeper zookeeper.properties process found."
    fi
}

function usage {
    echo "Usage: \$0 {deploy|start|stop}"
    echo ""
    echo "- deploy: Configure and deploy the environment"
    echo "- start: Start the Kafka and Zookeeper servers"
    echo "- stop: Stop the Kafka and Zookeeper servers"
}

function main {
    case "\$1" in
        deploy)
            configureEnv
            ;;
        start)
            startServerAndZookeeper
            ;;
        stop)
            stopServerAndZookeeper
            ;;
        restart)
            stopServerAndZookeeper
            sleep 10
            startServerAndZookeeper
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "\$@"

EOF
}


function createOutboundStartupScript {
    # Get the IP addresses and format them
    ips=$(jq -r '.Clients[] | select( .ClientName | contains("kafka-server")).PrivateIp' <<< "$INVENTORY")

    # Initialize an empty array
    producers=()

    # Iterate through each IP address and append the port
    for ip in $ips; do
        producers+=("    - ${ip}:9092")
    done

    # Join the array elements into a new line separated string
    producers_string=$(IFS=$'\n'; echo "${producers[*]}")
        cat <<EOF >outbound-quickstart.sh
#!/bin/bash
function configureEnv {
	apt update && apt install -y default-jre curl wget
	#wget https://download.aerospike.com/artifacts/enterprise/aerospike-kafka-outbound/5.0.1/aerospike-kafka-outbound-5.0.1.all.deb
    wget https://download.aerospike.com/artifacts/enterprise/aerospike-kafka-outbound/5.3.1/aerospike-kafka-outbound-5.3.1.all.deb
	#apt install ./aerospike-kafka-outbound-5.0.1.all.deb
    apt install ./aerospike-kafka-outbound-5.3.1.all.deb
	touch /opt/outbound_installed
}

function createOutboundYaml {
    cat <<EOF2 >/etc/aerospike-kafka-outbound/aerospike-kafka-outbound.yaml
# Change the configuration for your use case.
#
# Refer to https://www.aerospike.com/docs/connectors/enterprise/kafka/outbound/configuration/index.html
# for details.

# The connector's listening ports, TLS and network interface.
service:
  port: 8080

# Format of the Kafka destination message.
format:
  mode: flat-json
  metadata-key: metadata

# Aerospike record routing to a Kafka destination.

# Kafka producer initialization properties.
producer-props:
  request.timeout.ms: 3000
  bootstrap.servers:
$producers_string

# The logging properties.
logging:
  file: /var/log/aerospike-kafka-outbound/aerospike-kafka-outbound.log
  levels:
    root: info # Set default logging level to info.
    record-parser: info # The Aerospike record parser class.
    server: info # The server class logs.
    com.aerospike.connect: info # Set all the classes to default log level.

namespaces:
  test:
    routing:
      mode: static
      destination: first_kafka_topic
    format:
      mode: flat-json
      metadata-key: metadata
    sets:
      myset:
        routing:
          mode: static
          destination: test_topic
EOF2
}

function startOutbound {
    out_running=\$(pgrep -f aerospike-kafka-outbound)
    if [ -n "\$out_running" ]; then
        echo "Connector is already running. Exiting."
        exit 0
    fi
    
    nohup /opt/aerospike-kafka-outbound/bin/aerospike-kafka-outbound -f /etc/aerospike-kafka-outbound/aerospike-kafka-outbound.yaml > /var/log/aerospike-kafka-outbound/aerospike-kafka-outbound.log 2>&1 &

    # Wait a bit to ensure outbound starts
    sleep 5

    # Check if outbound is running
    if pgrep -f aerospike-kafka-outbound > /dev/null; then
        echo "Outbound Connector started successfully with PID \$(pgrep -f aerospike-kafka-outbound)"
    else
        echo "Outbound connector didn't seem to start... Retrying in 5 seconds..."
        sleep 5
        nohup /opt/aerospike-kafka-outbound/bin/aerospike-kafka-outbound -f /etc/aerospike-kafka-outbound/aerospike-kafka-outbound.yaml > /var/log/aerospike-kafka-outbound/aerospike-kafka-outbound.log 2>&1 &
        sleep 5
        if pgrep -f aerospike-kafka-outbound > /dev/null; then
            echo "Outbound Connector started successfully on retry. PID: \$(pgrep -f aerospike-kafka-outbound)"
        else
            echo "Failed to start Aerospike Outbound Connector. Check /var/log/aerospike-kafka-outbound/aerospike-kafka-outbound.log for details."
            exit 1
        fi
    fi
}

function main {
    case "\$1" in
        deploy)
            configureEnv && createOutboundYaml
            ;;
        start)
            startOutbound
            ;;
        stop)
            pid=\$(pgrep -f aerospike-kafka-outbound)
            echo "Stopping aerospike-kafka-outbound PID: \$pid"
            pkill -SIGTERM \$pid
            ;;
        restart)
            pid=\$(pgrep -f aerospike-kafka-outbound)
            echo "Stopping aerospike-kafka-outbound PID: \$pid"
            kill -9 \$pid
            sleep 10
            startOutbound
            ;;
        *)
            echo "Usage: \$0 {deploy|start|stop|restart}"
            exit 1
            ;;
    esac
}

main "\$@"
EOF
}

function uploadFiles {
    aerolab files upload -c -n kafka-server -lall kafka-quickstart.sh /opt/
    aerolab files upload -c -n outbound-connector -lall outbound-quickstart.sh /opt/
}

function runInstallerScripts {
    if [[ $GROW -eq 1 ]]; then
        OUTBOUND_DEPLOYED_CT=$1
        KAFKA_DEPLOYED_CT=$2
        echo "Deploying new instances!"
        [[ $OUTBOUND_NODE_CT -gt 0 ]] && aerolab client attach -l "$(($OUTBOUND_DEPLOYED_CT+1))-$(($OUTBOUND_DEPLOYED_CT+$OUTBOUND_NODE_CT))" --parallel -n outbound-connector -- bash /opt/outbound-quickstart.sh deploy
        [[ $KAFKA_NODE_CT -gt 0 ]] && aerolab client attach -l "$(($KAFKA_DEPLOYED_CT+1))-$(($KAFKA_DEPLOYED_CT+$KAFKA_NODE_CT))" --parallel -n kafka-server -- bash /opt/kafka-quickstart.sh deploy
        echo "Starting new instances!"
        [[ $KAFKA_NODE_CT -gt 0 ]] && aerolab client attach -l "$(($KAFKA_DEPLOYED_CT+1))-$(($KAFKA_DEPLOYED_CT+$KAFKA_NODE_CT))" --parallel -n kafka-server -- bash /opt/kafka-quickstart.sh start
        [[ $OUTBOUND_NODE_CT -gt 0 ]] && aerolab client attach -l "$(($OUTBOUND_DEPLOYED_CT+1))-$(($OUTBOUND_DEPLOYED_CT+$OUTBOUND_NODE_CT))" --parallel -n outbound-connector -- bash /opt/outbound-quickstart.sh start
        return
    fi
    aerolab client attach -lall --parallel -n kafka-server -- bash /opt/kafka-quickstart.sh deploy
    aerolab client attach -lall --parallel -n kafka-server -- bash /opt/kafka-quickstart.sh start
    aerolab client attach -lall --parallel -n outbound-connector -- bash /opt/outbound-quickstart.sh deploy
    aerolab client attach -lall --parallel -n outbound-connector -- bash /opt/outbound-quickstart.sh start
}

function recreateFiles {
    echo "Deleting old installer scripts."
    aerolab client attach -lall --parallel -n kafka-server -- rm /opt/kafka-quickstart.sh
    aerolab client attach -lall --parallel -n outbound-connector -- rm /opt/outbound-quickstart.sh
    echo "Recreating files..."
    INVENTORY=$(aerolab inventory list -j)
    createOutboundStartupScript
    createKafkaStartupScript
    uploadFiles
    echo "Done."
}

function deployAerospikeCluster {
    OUTBOUND_CT=$1
    if [[ $OUTBOUND_CT -eq 0 ]]; then
        echo "No new outbound connectors to scale. Skipping adding node-address-port for XDR DC."
        exit 0
    fi

    # Extract IP addresses using jq
    ips=$(jq -r '.Clients[] | select(.ClientName | contains("outbound-connector")).PrivateIp' <<< "$INVENTORY")

    # Initialize an empty array
    connectors=()

    # Iterate through each IP address and append the port
    for ip in $ips; do
        connectors+=("        node-address-port ${ip} 8080")
        asadm_ips=($ips)
    done

    # Join the array elements into a new line separated string
    connectors_string=$(IFS=$'\n'; echo "${connectors[*]}")
        
        cat <<EOF >aerospike.conf
service {
    proto-fd-max 15000
}
logging {
    file /var/log/aerospike.log {
        context any info
    }
}
network {
    service {
        address any
        port 3000
    }
    heartbeat {
        interval 150
        mode multicast
        multicast-group 239.1.99.222
        port 9918
        timeout 10
    }
    fabric {
        port 3001
    }
    info {
        port 3003
    }
}
namespace test {
    default-ttl 0
    replication-factor 2
    rack-id 2
    storage-engine device {
        file /opt/aerospike/data/bar.dat
        filesize 10G
        #flush-size 1048576
    }
    strong-consistency true
}

xdr {
    dc connector {
$connectors_string
        connector true
        namespace test {

        }     
    }
}
EOF

    if [[ $GROW -eq 1 && $CLUSTER_NODE_CT -ne 0 ]]; then
        ASDB_DEPLOYED_COUNT=$(jq -r '.Clusters[] | select(.ClusterName | contains("$CLUSTER_NAME")).PrivateIp' <<< "$INVENTORY" | wc -l)
        echo "Growing Aerospike Servers by $CLUSTER_NODE_CT"
        aerolab cluster grow -n $CLUSTER_NAME -c $CLUSTER_NODE_CT --instance c2d-highcpu-8 --zone $ZONE --disk=pd-ssd:110 --disk=local-ssd --start n -o aerospike.conf -v '7.0*' -d ubuntu -i 22.04
        aerolab aerospike stop -n $CLUSTER_NAME
        aerolab files upload -l all -n $CLUSTER_NAME aerospike.conf /etc/aerospike/
        aerolab aerospike start -n $CLUSTER_NAME
        sleep 5
        aerolab roster apply -n $CLUSTER_NAME -m test
        exit 0
    elif [[ $GROW -eq 1 ]]; then
        aerolab files upload -l all -n $CLUSTER_NAME aerospike.conf /etc/aerospike/

        # If we're growing the cluster then we want to only add the newly created IPs
        # otherwise we will trigger an error when applying the asadm command which we can avoid
        total_ips=${#asadm_ips[@]}
        start_index=$((total_ips - OUTBOUND_CT))
        if [ $start_index -lt 0 ]; then
            start_index=0
        fi
        last_n_ips=("${asadm_ips[@]:$start_index}")
        for conn in "${last_n_ips[@]}"; do
            aerolab attach asadm -n $CLUSTER_NAME -- "-e enable; manage config xdr dc connector add node $conn:8080"
        done
        exit 0
    fi
    echo "Creating Aerospike Cluster!"
    aerolab cluster create -n $CLUSTER_NAME -c $CLUSTER_NODE_CT --instance c2d-highcpu-8 --zone $ZONE --disk=pd-ssd:110 --disk=local-ssd --start n -o aerospike.conf -v '7.0*' -d ubuntu -i 22.04
    aerolab cluster partition create -n $CLUSTER_NAME --filter-type=nvme -p 24,24,24,24
    aerolab cluster partition conf -n $CLUSTER_NAME --filter-type=nvme --filter-partitions=1-4 --namespace test --configure=device
    aerolab aerospike start -n $CLUSTER_NAME
    sleep 5
    aerolab roster apply -n $CLUSTER_NAME -m test
}

function cleanUp {
    aerolab client destroy -f -n outbound-connector
    aerolab client destroy -f -n kafka-server
    aerolab cluster destroy -f -n $CLUSTER_NAME
    exit 0
}

function usage {
    echo "Usage: $0 [ -n CLUSTER_NAME ] [ -c NUM_AEROSPIKE_NODES ] [ -k NUM_KAFKA_NODES ] [ -o NUM_OUTBOUND_NODES ] [ -R ] [ -f ] [ -h ]"
    echo ""
    echo "-c) Number of Aerospike Server DB nodes (Default: 1)"
    echo "-k) Number of Kafka Broker nodes (Default: 1)"
    echo "-o) Number of Outbound Connector nodes (Default: 1)"
    echo "-I) Instance type for kafka-servers (Default: c2d-highcpu-8)"
    echo "-O) Instance type for outbound-connectors (Default: c2d-highcpu-8)"
    echo "-n) Name of aerolab cluster to configure DC to ship to outbound connector (Default: mydc)"
    echo "-R) Clean up clients and clusters deployed"
    echo "-f) Recreate files"
    echo "-g) Grow the instances horizontally. MUST have already running instances."
    echo "-h) Display this help message"
    exit 0
}

function exit_abnormal {
    usage
    exit 1
}

function parseArgs {
    CLUSTER_NAME="mydc"
    CLUSTER_NODE_CT=0
    KAFKA_NODE_CT=1
    OUTBOUND_NODE_CT=1
    CLEAN_UP=0
    RECREATE_FILES=0
    PRINT_USAGE=0
    GROW=0
    ERROR=0
    ERROR_MSG=""
    K_INSTANCE="c2d-highcpu-8"
    O_INSTANCE="c2d-highcpu-8"
    ZONE="us-central1-a"

    while getopts ":n:c:k:o:O:I:z:Rfgh" options; do
        case "${options}" in
            n)
                CLUSTER_NAME=${OPTARG}
                ;;
            I)
                K_INSTANCE=${OPTARG}
                ;;
            O)
                O_INSTANCE=${OPTARG}
                ;;
            z)
                ZONE=${OPTARG}
                ;;
            R)
                CLEAN_UP=1
                ;;
            c)
                CLUSTER_NODE_CT=${OPTARG}
                ;;
            k)
                KAFKA_NODE_CT=${OPTARG}
                ;;
            o)
                OUTBOUND_NODE_CT=${OPTARG}
                ;;
            f)
                RECREATE_FILES=1
                ;;
            g)
                GROW=1
                ;;
            h)
                ERROR=1
                ;;
            :)
                ERROR_MSG="Error: -${OPTARG} requires an argument."
                ERROR=1
                ;;
            *)
                ERROR_MSG="Error: Invalid option -${OPTARG}"
                ERROR=1
                ;;
        esac
    done
    ERROR_MSG=$(echo "$ERROR_MSG" | tr -d '"')
    echo "$CLUSTER_NAME $CLUSTER_NODE_CT $KAFKA_NODE_CT $OUTBOUND_NODE_CT $CLEAN_UP $RECREATE_FILES $GROW $ERROR $K_INSTANCE $O_INSTANCE $ZONE $ERROR_MSG"
}

function main {
    # Capture the output of parseArgs
    parsed_args=$(parseArgs "$@")
    # Read the parsed arguments into variables
    read -r CLUSTER_NAME CLUSTER_NODE_CT KAFKA_NODE_CT OUTBOUND_NODE_CT CLEAN_UP RECREATE_FILES GROW ERROR K_INSTANCE O_INSTANCE ZONE ERROR_MSG <<< "$parsed_args"

    # Check if we triggered an error
    if [[ $ERROR -eq 1 ]]; then
        echo "$ERROR_MSG"
        exit_abnormal
    fi

    # Validate cluster name
    for arg in "$CLUSTER_NAME" "$K_INSTANCE" "$O_INSTANCE" "$ZONE"; do
        if [[ -z "$arg" ]]; then
            echo "Error: $arg cannot be empty."
            exit_abnormal
        fi
    done

    # Validate integer arguments
    for arg in "$CLUSTER_NODE_CT" "$KAFKA_NODE_CT" "$OUTBOUND_NODE_CT" "$CLEAN_UP" "$RECREATE_FILES" "$GROW"; do
        if ! [[ "$arg" =~ ^[0-9]+$ ]]; then
            echo "Error: Argument '$arg' is not a valid integer."
            exit_abnormal
        fi
    done



    which aerolab > /dev/null || { echo "aerolab is not installed"; exit 1; }
    which jq > /dev/null || { echo "jq is not installed"; exit 1; }

    if [[ $RECREATE_FILES -eq 1 ]]; then 
        recreateFiles
        exit 0
    fi

    if [[ $CLEAN_UP -eq 1 ]]; then
        cleanUp
        exit 0
    fi

    createOutboundAndKafkaClient
    INVENTORY=$(aerolab inventory list -j)

    createKafkaStartupScript
    createOutboundStartupScript

    echo "Uploading install scripts!"
    uploadFiles
    echo "Running deployment installers!"
    runInstallerScripts

    deployAerospikeCluster $OUTBOUND_NODE_CT
    echo "Configured XDR DC to outbound connector"

    echo "Finished setting up Kafka and Outbound clients."
    echo ""
    echo "To verify records are shipping correctly insert data with aerolab and start a consumer:"
    echo "-    aerolab data insert -m test -s myset -z 10"
    echo "-    aerolab client attach -n kafka-server -- /kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic test_topic --from-beginning"
}

main "$@"
