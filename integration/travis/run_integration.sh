#!/bin/bash

# Usage: ./run_integration [OPTIONS...]
#   --auth={http-basic,one-user}    Use the specified authentication scheme. Default is one-user.
#   --executor={cook,mesos}         Use the specified job executor. Default is mesos.

set -ev

export PROJECT_DIR=`pwd`

PYTEST_MARKS=''
COOK_AUTH=one-user
COOK_EXECUTOR=mesos
CONFIG_FILE=scheduler_travis_config.edn

while (( $# > 0 )); do
  case "$1" in
    --auth=*)
      COOK_AUTH="${1#--auth=}"
      shift
      ;;
    --executor=*)
      COOK_EXECUTOR="${1#--executor=}"
      shift
      ;;
    *)
      echo "Unrecognized option: $1"
      exit 1
  esac
done

case "$COOK_AUTH" in
  http-basic)
    export COOK_HTTP_BASIC_AUTH=true
    ;;
  one-user)
    export COOK_EXECUTOR_PORTION=1
    ;;
  *)
    echo "Unrecognized auth scheme: $COOK_AUTH"
    exit 1
esac

case "$COOK_EXECUTOR" in
  cook)
    echo "$(date +%H:%M:%S) Cook executor has been enabled"
    COOK_EXECUTOR_COMMAND="${TRAVIS_BUILD_DIR}/travis/cook-executor-local/cook-executor-local"
    # Build cook-executor
    ${TRAVIS_BUILD_DIR}/travis/build_cook_executor.sh
    ;;
  mesos)
    COOK_EXECUTOR_COMMAND=""
    ;;
  *)
    echo "Unrecognized executor: $EXECUTOR"
    exit 1
esac

function wait_for_cook {
    COOK_PORT=${1:-12321}
    while ! curl -s localhost:${COOK_PORT} >/dev/null;
    do
        echo "$(date +%H:%M:%S) Cook is not listening on ${COOK_PORT} yet"
        sleep 2.0
    done
    echo "$(date +%H:%M:%S) Connected to Cook on ${COOK_PORT}!"
    curl -s localhost:${COOK_PORT}/info
    echo
}
export -f wait_for_cook

# Start minimesos
cd ${TRAVIS_BUILD_DIR}/travis
./minimesos up
$(./minimesos info | grep MINIMESOS)
export COOK_ZOOKEEPER="${MINIMESOS_ZOOKEEPER_IP}:2181"
export MINIMESOS_ZOOKEEPER=${MINIMESOS_ZOOKEEPER%;}

./datomic-free-0.9.5394/bin/transactor $(pwd)/datomic_transactor.properties &

# Start three cook schedulers. We want one cluster with two cooks to run MasterSlaveTest, and a second cluster to run MultiClusterTest.
# The basic tests will run against cook-framework-1
cd ${TRAVIS_BUILD_DIR}/scheduler
## on travis, ports on 172.17.0.1 are bindable from the host OS, and are also
## available for processes inside minimesos containers to connect to
export COOK_EXECUTOR_COMMAND=${COOK_EXECUTOR_COMMAND}
# Start one cook listening on port 12321, this will be the master of the "cook-framework-1" framework
LIBPROCESS_IP=172.17.0.1 COOK_DATOMIC="datomic:free://localhost:4334/cook-jobs" COOK_PORT=12321 COOK_FRAMEWORK_ID=cook-framework-1 COOK_LOGFILE="log/cook-12321.log" lein run ${PROJECT_DIR}/travis/${CONFIG_FILE} &
# Start a second cook listening on port 22321, this will be the master of the "cook-framework-2" framework
LIBPROCESS_IP=172.17.0.1 COOK_DATOMIC="datomic:mem://cook-jobs" COOK_PORT=22321 COOK_ZOOKEEPER_LOCAL=true COOK_ZOOKEEPER_LOCAL_PORT=4291 COOK_FRAMEWORK_ID=cook-framework-2 COOK_LOGFILE="log/cook-22321.log" lein run ${PROJECT_DIR}/travis/${CONFIG_FILE} &

# Wait for the cooks to be listening
timeout 180s bash -c "wait_for_cook 12321" || curl_error=true
if [ "$curl_error" = true ]; then
  echo "$(date +%H:%M:%S) Timed out waiting for cook to start listening, displaying cook log"
  cat ${TRAVIS_BUILD_DIR}/scheduler/log/cook-12321.log
  exit 1
fi

# Start a third cook listening on port 12322, this will be a slave on the "cook-framework-1" framework
LIBPROCESS_IP=172.17.0.1 COOK_DATOMIC="datomic:free://localhost:4334/cook-jobs" COOK_PORT=12322 COOK_FRAMEWORK_ID=cook-framework-1 COOK_LOGFILE="log/cook-12322.log" lein run ${PROJECT_DIR}/travis/${CONFIG_FILE} &

timeout 180s bash -c "wait_for_cook 12322" || curl_error=true
if [ "$curl_error" = true ]; then
  echo "$(date +%H:%M:%S) Timed out waiting for cook to start listening, displaying cook log"
  cat ${TRAVIS_BUILD_DIR}/scheduler/log/cook-12322.log
  exit 1
fi
timeout 180s bash -c "wait_for_cook 22321" || curl_error=true
if [ "$curl_error" = true ]; then
    echo "$(date +%H:%M:%S) Timed out waiting for cook to start listening, displaying cook log"
    cat ${TRAVIS_BUILD_DIR}/scheduler/log/cook-22321.log
    exit 1
fi

# Ensure the Cook Scheduler CLI is available
command -v cs

# Run the integration tests
cd ${PROJECT_DIR}
export COOK_MULTI_CLUSTER=
export COOK_MASTER_SLAVE=
export COOK_SLAVE_URL=http://localhost:12322
pytest -n4 -v --color=no --timeout-method=thread --boxed -m "${PYTEST_MARKS}" || test_failures=true

# If there were failures, dump the executor logs
if [ "$test_failures" = true ]; then
  echo "Displaying scheduler logs"
  ${TRAVIS_BUILD_DIR}/travis/show_scheduler_logs.sh
  exit 1
fi
