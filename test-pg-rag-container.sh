#!/bin/bash

set -vxeo pipefail

# change PODMAN to `docker` if you prefer
PODMAN=podman
REPO=pg_rag_container
TAG=test
CONTAINER=test_pg_rag
INIT_CONTAINER=init_test_pg_rag

PGUID=70
PGGID=70
UID_BUILD_ARG="--build-arg POSTGRES_USER_UID=$PGUID"
GID_BUILD_ARG="--build-arg POSTGRES_USER_GID=$PGGID"
BUILD_ARGS="$UID_BUILD_ARG $GID_BUILD_ARG"

# We generate a random password
SOOPER_SECRET=$RANDOM-$RANDOM-$RANDOM

# Environment & volume arguments
PASSWORD_ARG="-e POSTGRES_PASSWORD=$SOOPER_SECRET"
USERNS_ARG="--userns=keep-id:uid=${PGUID},gid=${PGGID}"
VOLUME_ARG="-v $(pwd)/pg_data:/var/lib/postgresql/data"

# Our test command
TEST_CMD="psql -n -a --set ON_ERROR_STOP=1 -f"


# 1) Build the new image
$PODMAN build . $BUILD_ARGS -t ${REPO}:${TAG}

# 2) Remove previous data so initdb doesn't complain about non-empty directory
rm -rf ./pg_data
mkdir -p ./pg_data
# initialize the database into the empty pg_data directory using an anonymous container
$PODMAN run -i --name=$INIT_CONTAINER \
    $USERNS_ARG \
    $VOLUME_ARG \
    $PASSWORD_ARG \
    ${REPO}:${TAG} \
    docker-ensure-initdb.sh
$PODMAN rm $INIT_CONTAINER

# 3) Copy test SQL and test data to local ./pg_data now that initdb is done
cp ./test_sql/test_*.sql ./pg_data/
for TEST_DATA_GZ in ./test_data/test*.gz; do
    TEST_DATA_FILE=$(basename "$TEST_DATA_GZ" .gz)
    gunzip -c "$TEST_DATA_GZ" > "./pg_data/$TEST_DATA_FILE"
done

# start the database in a new named container,
# mounting the already initialized pg_data, and
# removing any previous version with the same name
$PODMAN rm -f $CONTAINER || true
$PODMAN run -d --name=$CONTAINER \
    $USERNS_ARG \
    $VOLUME_ARG \
    $PASSWORD_ARG \
    ${REPO}:${TAG} \
    postgres

# 6) Run your test SQL scripts
for TEST_SQL in ./test_sql/test*.sql ; do
    F=$(basename "$TEST_SQL")
    SQL_PATH="/var/lib/postgresql/data/$F"
    $PODMAN exec -i $CONTAINER $TEST_CMD $SQL_PATH
done

if [ x$LEAVE_RUNNING == "xyes" ] ; then
        echo container $CONTAINER is running and has passed tests.
        exit 0
fi

# 7) Gracefully stop (kill) the container
# We can use "kill" or "stop" – whichever you prefer
$PODMAN kill -s INT $CONTAINER

# remove the test container
RUNNING=1
while [ $RUNNING -gt 0 ] ; do
        echo waiting for container $CONTAINER to shut down so we can remove it
        sleep 1
        RUNNING=$($PODMAN ps | grep $CONTAINER | wc -l)
done
$PODMAN rm $CONTAINER
rm -rf ./pg_data
