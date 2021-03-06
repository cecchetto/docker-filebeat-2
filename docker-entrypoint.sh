#!/bin/sh
set -e

if [ "$1" = 'start' ]; then

  CONTAINERS_FOLDER=/tmp/containers
  NAMED_PIPE=/tmp/pipe

  setConfiguration() {
    KEY=$1
    VALUE=$2
    sed -i "s/{{$KEY}}/$VALUE/g" ${FILEBEAT_HOME}/filebeat.yml
  }

  getRunningContainers() {
    curl --no-buffer -s -XGET --unix-socket /var/run/docker.sock http:/containers/json | jq '.[].Id' | sed 's/\"//g'
  }

  getContainerName() {
    curl --no-buffer -s -XGET --unix-socket /var/run/docker.sock http:/containers/$1/json | jq '.Name' | sed 's/\"//g' | sed 's;/;;'
  }

  createContainerFile() {
    touch "$CONTAINERS_FOLDER/$1"
  }

  removeContainerFile() {
    rm "$CONTAINERS_FOLDER/$1"
  }

  collectContainerLogs() {
    local CONTAINER=$1
    echo "Processing $CONTAINER..."
    createContainerFile $CONTAINER
    CONTAINER_NAME=`getContainerName $CONTAINER`
    curl -s --no-buffer -XGET --unix-socket /var/run/docker.sock "http:/containers/$CONTAINER/logs?stderr=1&stdout=1&tail=1&follow=1&timestamps=1" |
      sed -e ':a;N;$!ba;s/\n//g' |
      sed -e 's/^.*\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T\)/\1/' |
      sed "s;^;[$CONTAINER_NAME] ;" > $NAMED_PIPE
    echo "Disconnected from $CONTAINER."
    removeContainerFile $CONTAINER
  }

  if [ -n "${LOGSTASH_HOST+1}" ]; then
    setConfiguration "LOGSTASH_HOST" "$LOGSTASH_HOST"
  else
    echo "LOGSTASH_HOST is needed"
    exit 1
  fi

  if [ -n "${LOGSTASH_PORT+1}" ]; then
    setConfiguration "LOGSTASH_PORT" "$LOGSTASH_PORT"
  else
    echo "LOGSTASH_PORT is needed"
    exit 1
  fi

  sed -i "s#{{INDEX}}#${INDEX:=filebeat}#g" ${FILEBEAT_HOME}/filebeat.yml
  sed -i "s#{{LOG_LEVEL}}#${LOG_LEVEL:=error}#g" ${FILEBEAT_HOME}/filebeat.yml
  sed -i "s#{{SHIPPER_NAME}}#${SHIPPER_NAME:=`hostname`}#g" ${FILEBEAT_HOME}/filebeat.yml
  sed -i "s#{{SHIPPER_TAGS}}#${SHIPPER_TAGS}#g" ${FILEBEAT_HOME}/filebeat.yml

  rm -rf "$CONTAINERS_FOLDER"
  rm -rf "$NAMED_PIPE"
  mkdir "$CONTAINERS_FOLDER"
  mkfifo -m a=rw "$NAMED_PIPE"

  echo "Initializing Filebeat..."
  cat $NAMED_PIPE | ${FILEBEAT_HOME}/filebeat -e &

  while true; do
    CONTAINERS=`getRunningContainers` && :
    for CONTAINER in $CONTAINERS; do
      if ! ls $CONTAINERS_FOLDER | grep -q $CONTAINER; then
        collectContainerLogs $CONTAINER &
      fi
    done
    sleep ${PERIOD:=5}
  done

else
  exec "$@"
fi
