#!/bin/bash

# Usage - run commands from repo root:
# To check if new changes to the extension cause changes to any snapshots:
#   BUILD_EXTENSION=true aws-vault exec sandbox-account-admin -- ./integration_tests/run.sh
# To regenerate snapshots:
#   UPDATE_SNAPSHOTS=true aws-vault exec sandbox-account-admin -- ./integration_tests/run.sh

LOGS_WAIT_SECONDS=45

set -e

script_utc_start_time=$(date -u +"%Y%m%dT%H%M%S")

if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "No AWS credentials were found in the environment."
    echo "Note that only Datadog employees can run these integration tests."
    exit 1
fi

if [ -n "$BUILD_EXTENSION" ]; then
    echo "Building extension that will be deployed with our test functions"
    # This version number is arbitrary and won't be used by AWS
    VERSION=123 ./scripts/build_binary_and_layer.sh
else
    echo "Not building extension, ensure it has already been built or re-run with 'BUILD_EXTENSION=true'"
fi

cd "./integration_tests"

# build and zip recorder extension
cd recorder-extension
    GOOS=linux GOARCH=amd64 go build -o extensions/recorder-extension main.go
    zip -rq ext.zip extensions/* -x ".*" -x "__MACOSX" -x "extensions/.*"
cd ..

# build Go Lambda function
cd src
env GOOS=linux go build -ldflags="-s -w" -o ../bootstrap traceGo.go
cd ..

function getLatestLayerVersion() {
    layerName=$1
    lastVersion=$(aws lambda list-layer-versions --layer-name $layerName --region sa-east-1 | jq -r ".LayerVersions | .[0] |  .Version")
    if [ lastVersion == "null" ]; then
        exit 1
    else
        echo $lastVersion
    fi
}

if [ -z "$NODE_LAYER_VERSION" ]; then
   echo "NODE_LAYER_VERSION not found, getting the latest one"
   export NODE_LAYER_VERSION=$(getLatestLayerVersion "Datadog-Node14-x")
   echo "NODE_LAYER_VERSION set to: $NODE_LAYER_VERSION"
fi

if [ -z "$PYTHON_LAYER_VERSION" ]; then
   echo "PYTHON_LAYER_VERSION not found, getting the latest one"
   export PYTHON_LAYER_VERSION=$(getLatestLayerVersion "Datadog-Python38")
   echo "PYTHON_LAYER_VERSION set to: $PYTHON_LAYER_VERSION"
fi

# random 8-character ID to avoid collisions with other runs
stage=$(xxd -l 4 -c 4 -p < /dev/random)

# always remove the stacks before exiting, no matter what
function remove_stack() {
    echo "Removing stack for stage : ${stage}"
    NODE_LAYER_VERSION=${NODE_LAYER_VERSION} \
    PYTHON_LAYER_VERSION=${PYTHON_LAYER_VERSION} \
    serverless remove --stage ${stage} 
}

# making sure the remove_stack function will be called no matter what
trap remove_stack EXIT

# deploying the stack
NODE_LAYER_VERSION=${NODE_LAYER_VERSION} \
PYTHON_LAYER_VERSION=${PYTHON_LAYER_VERSION} \
serverless deploy --stage ${stage}

# invoking functions
metric_function_names=("enhanced-metric-node" "enhanced-metric-python" "no-enhanced-metric-node" "no-enhanced-metric-python" "timeout-node" "timeout-python")
log_function_names=("log-node" "log-python")
trace_function_names=("simple-trace-node" "simple-trace-python" "simple-trace-go")

all_functions=("${metric_function_names[@]}" "${log_function_names[@]}" "${trace_function_names[@]}")

set +e # Don't exit this script if an invocation fails or there's a diff

for function_name in "${all_functions[@]}"; do
    NODE_LAYER_VERSION=${NODE_LAYER_VERSION} \
    PYTHON_LAYER_VERSION=${PYTHON_LAYER_VERSION} \
    serverless invoke --stage ${stage} -f ${function_name}
    # two invocations are needed since enhanced metrics are computed with the REPORT log line (which is trigered at the end of the first invocation)
    return_value=$(serverless invoke --stage ${stage} -f ${function_name})

    # Compare new return value to snapshot
    diff_output=$(echo "$return_value" | diff - "./snapshots/expectedInvocationResult")
    if [ $? -eq 1 ] && [ ${function_name:0:7} != timeout ]; then
        echo "Failed: Return value for $function_name does not match snapshot:"
        echo "$diff_output"
        mismatch_found=true
    else
        echo "Ok: Return value for $function_name matches snapshot"
    fi
done

echo "Sleeping $LOGS_WAIT_SECONDS seconds to wait for logs to appear in CloudWatch..."
sleep $LOGS_WAIT_SECONDS

for function_name in "${all_functions[@]}"; do
    echo "Fetching logs for ${function_name} on ${stage}"
    retry_counter=0
    while [ $retry_counter -lt 10 ]; do
        raw_logs=$(NODE_LAYER_VERSION=${NODE_LAYER_VERSION} PYTHON_LAYER_VERSION=${PYTHON_LAYER_VERSION} serverless logs --stage ${stage} -f $function_name --startTime $script_utc_start_time)
        fetch_logs_exit_code=$?
        if [ $fetch_logs_exit_code -eq 1 ]; then
            echo "Retrying fetch logs for $function_name..."
            retry_counter=$(($retry_counter + 1))
            sleep 10
            continue
        fi
        break
    done

    # Replace invocation-specific data like timestamps and IDs with XXX to normalize across executions
    if [[ " ${metric_function_names[@]} " =~ " ${function_name} " ]]; then
        # Normalize metrics
        logs=$(
            echo "$raw_logs" | \
            grep "\[sketch\]" | \
            perl -p -e "s/(ts\":)[0-9]{10}/\1XXX/g" | \
            perl -p -e "s/(min\":)[0-9\.e\-]{2,20}/\1XXX/g" | \
            perl -p -e "s/(max\":)[0-9\.e\-]{2,20}/\1XXX/g" | \
            perl -p -e "s/(cnt\":)[0-9\.e\-]{2,20}/\1XXX/g" | \
            perl -p -e "s/(avg\":)[0-9\.e\-]{2,20}/\1XXX/g" | \
            perl -p -e "s/(sum\":)[0-9\.e\-]{2,20}/\1XXX/g" | \
            perl -p -e "s/(k\":\[)[0-9\.e\-]{1,20}/\1XXX/g" | \
            perl -p -e "s/(datadog-nodev)[0-9]+\.[0-9]+\.[0-9]+/\1X\.X\.X/g" | \
            perl -p -e "s/(datadog_lambda:v)[0-9]+\.[0-9]+\.[0-9]+/\1X\.X\.X/g" | \
            perl -p -e "s/(dd_extension_version:)[0-9]+/\1XXX/g" | \
            perl -p -e "s/(dd_lambda_layer:datadog-python)[0-9_]+\.[0-9]+\.[0-9]+/\1X\.X\.X/g" | \
            perl -p -e "s/(serverless.lambda-extension.integration-test.count)[0-9\.]+/\1/g" | \
            perl -p -e "s/$stage/XXXXXX/g" | \
            sort
        )
    elif [[ " ${log_function_names[@]} " =~ " ${function_name} " ]]; then
        # Normalize logs
        logs=$(
            echo "$raw_logs" | \
            grep "\[log\]" | \
            perl -p -e "s/(timestamp\":)[0-9]{13}/\1TIMESTAMP/g" | \
            perl -p -e "s/(\"REPORT |START |END ).*/\1XXX\"}}/g" | \
            perl -p -e "s/(\"HTTP ).*/\1\"}}/g" | \
            perl -p -e "s/(,\"request_id\":\")[a-zA-Z0-9\-,]+\"//g" | \
            perl -p -e "s/(dd_extension_version:)[0-9]+/\1XXX/g" | \
            perl -p -e "s/$stage/STAGE/g" | \
            perl -p -e "s/(\"message\":\").*(XXX LOG)/\1\2\3/g" | \
            grep XXX
        )
    else
        # Normalize traces
        logs=$(
            echo "$raw_logs" | \
            grep "\[trace\]" | \
            perl -p -e "s/(ts\":)[0-9]{10}/\1XXX/g" | \
            perl -p -e "s/((startTime|endTime|traceID|trace_id|span_id|parent_id|start|system.pid)\":)[0-9]+/\1XXX/g" | \
            perl -p -e "s/(duration\":)[0-9]+/\1XXX/g" | \
            perl -p -e "s/((datadog_lambda|dd_trace)\":\")[0-9]+\.[0-9]+\.[0-9]+/\1X\.X\.X/g" | \
            perl -p -e "s/(,\"request_id\":\")[a-zA-Z0-9\-,]+\"/\1XXX\"/g" | \
            perl -p -e "s/(,\"runtime-id\":\")[a-zA-Z0-9\-,]+\"/\1XXX\"/g" | \
            perl -p -e "s/(,\"dd_extension_version\":\")[0-9]+\"/\1XXX\"/g" | \
            perl -p -e "s/(,\"system.pid\":\")[a-zA-Z0-9\-,]+\"/\1XXX\"/g" | \
            perl -p -e "s/$stage/XXXXXX/g" | \
            sort
        )
    fi

    function_snapshot_path="./snapshots/${function_name}"

    if [ ! -f $function_snapshot_path ]; then
        # If no snapshot file exists yet, we create one
        echo "Writing logs to $function_snapshot_path because no snapshot exists yet"
        echo "$logs" >$function_snapshot_path
    elif [ -n "$UPDATE_SNAPSHOTS" ]; then
        # If $UPDATE_SNAPSHOTS is set to true write the new logs over the current snapshot
        echo "Overwriting log snapshot for $function_snapshot_path"
        echo "$logs" >$function_snapshot_path
    else
        # Compare new logs to snapshots
        diff_output=$(echo "$logs" | diff - $function_snapshot_path)
        if [ $? -eq 1 ]; then
            echo "Failed: Mismatch found between new $function_name logs (first) and snapshot (second):"
            echo "$diff_output"
            mismatch_found=true
        else
            echo "Ok: New logs for $function_name match snapshot"
        fi
    fi

done

if [ "$mismatch_found" = true ]; then
    echo "FAILURE: A mismatch between new data and a snapshot was found and printed above."
    exit 1
fi

echo "SUCCESS: No difference found between snapshots and new return values or logs"