#!/bin/bash
# Launch and manage simutrans servers
# Author: Greg Havekes

VERSION=1.1.0

# Import configuration
source head.conf

# Log levels : ERROR, WARN, INFO, DEBUG
log() {
  while read data; do
    if [[ $# -ne 1 ]]; then
      level=INFO
    else
      level=$1
    fi

    echo "${level}: ${data}" >> $LOG_FILE

    case $level in
      ERROR)
        echo "${PREFIX} | ERROR: ${data}"
        ;;
      INFO)
        echo "${PREFIX} | ${data}"
        ;;
      DEBUG)
        if [[ $VERBOSE -eq "true" ]]; then
          echo "${PREFIX} | DEBUG: ${data}"
        fi
        ;;
      *)
        echo "ERROR: Unkown log level"
        ;;
      esac
  done
}


# Basic info functions

usage() {
  echo -e "Usage:
    head.sh [-v] [instances|version|help] [status|start|stop|restart|reload|statuscode|revision <instance>]
Options:
    -v        verbose output"
}

version() {
  echo "Simuhead version $VERSION"
}

list_instances() {
  cd ${ROOTDIR}/instances/
  instances_list=($(ls -d1 */ | sed 's/.$//'))
  cd ${ROOTDIR}

  echo "Available instances:"

  for item in ${instances_list[@]}; do
    if [[ $item != "example" ]]; then
      if [[ -f instances/${item}/${item}.conf ]]; then
        instance_status_code=$(bash ${ROOTDIR}/head.sh statuscode ${item})
        
        if (( instance_status_code == 0 )); then
          instance_status="stopped"
        elif (( instance_status_code == 1 )); then
          instance_status="running"
        else
          instance_status=$instance_status_code
        fi

        echo "- $item (${instance_status})"
      fi
    fi
  done
}


# Parameters parsing

not_enough_params() {
  echo "ERROR: Not enough parmaters."
}

# Handle options
OPTIONS=v

while getopts $OPTIONS opt
do
  case $opt in
    v) VERBOSE=true ;;
  esac
done
shift $((OPTIND -1))

# Handle arguments
if [[ $# -eq 1 ]]; then
  action=$1
  case $action in
    help)
      usage
      exit 0
      ;;
    version)
      version
      exit 0
      ;;
    instances)
      list_instances
      exit 0
      ;;
    *)
      not_enough_params
      usage
      exit 1
      ;;
  esac
elif [[ $# -eq 2 ]]; then
  action=$1
  instance=$2
else
  not_enough_params
  usage
  exit 1
fi


# Instance config
instance_dir=${ROOTDIR}/instances/${instance}
instance_config=${instance_dir}/${instance}.conf

# Logs
log_dir=${ROOTDIR}/log/${instance}
if [[ ! -d $log_dir ]]; then
  mkdir ${log_dir}
  chown -R ${USER}:${USER} ${log_dir}
fi
LOG_FILE=${log_dir}/head.log

# Stdout prefix
PREFIX="Simuhead instance: ${instance}"


# Check instance config
if [[ -f $instance_config ]]; then
  source $instance_config
else
  echo "There is no config file for instance ${instance} in ${instance_config}" | log ERROR
  exit 1
fi

if [[ -z ${revision:+x} ]]; then
  echo "Please set the revision in the instance's config file: ${instance_config}" | log ERROR
  exit 1
fi

if [[ -z ${port:+x} ]]; then
  echo "Please set the port in the instance's config file: ${instance_config}" | log ERROR
  exit 1
fi
if [[ -z ${pak:+x} ]]; then
  echo "Please set the pak in the instance's config file: ${instance_config}" | log ERROR
  exit 1
fi
if [[ -z ${save:+x} ]]; then
  echo "Please set the save in the instance's config file: ${instance_config}" | log ERROR
  exit 1
fi

if [[ -z ${lang:+x} ]]; then
  echo "Please set the lang in the instance's config file: ${instance_config}" | log ERROR
  exit 1
fi

if [[ -z ${debug:+x} ]]; then
  # Debug defaults to 2
  debug=2
fi


# Installs
simutrans_dir=${ROOTDIR}/build/${instance}/r${revision}/simutrans

# PID files
pidfile=${ROOTDIR}/run/${instance}.pid


# Backup savegames
backup_savegames () {
  if [[ -e ${simutrans_dir}/server${port}-network.sve ]]; then
    backup_number=`find ${simutrans_dir}/save/ -maxdepth 1 -type d | wc -l`
    backup_dir=${simutrans_dir}/save/backup-${backup_number}

    mkdir $backup_dir
    mv ${simutrans_dir}/server${port}-*.sve $backup_dir
  fi
}

# Status of the server process
process_status() {
  # Check if the pid file exists and the process is running
  if [[ -e $pidfile ]]; then
    pid=$(cat $pidfile)
    if ps -p $pid > /dev/null
    then
      # Then the server is running
      echo $pid
    else
      # Remove pid file if process crashed
      rm $pidfile
      echo 0
    fi
  else
    # No pid file
    echo 0
  fi
}

# Load paksets, config and savegames
simutrans_load () {
  # Copying paksets
  echo "Extracting pakset..." | log DEBUG
  unzip -o "${instance_dir}/pak/*.zip" -d $simutrans_dir | log DEBUG

  # Copying config
  echo "Copying config file..." | log DEBUG
  cp -fv ${instance_dir}/config/simuconf.tab ${simutrans_dir}/config/ | log DEBUG

  # Copying savegames
  echo "Copying savegames..." | log DEBUG
  if [[ ! -d ${simutrans_dir}/save ]]; then
    mkdir ${simutrans_dir}/save
  fi
  cp -fv ${instance_dir}/save/*.sve ${simutrans_dir}/save/ | log DEBUG

  # Set permissions
  chown -R ${USER}:${USER} ${simutrans_dir} | log DEBUG
}

# Build and install
simutrans_install () {
  echo "Building r${revision}..." | log INFO
  echo "Build log in ${log_dir}/build-r${revision}.log" | log DEBUG
  cd ${ROOTDIR}/build
  ./build.sh $instance $revision > ${log_dir}/build-r${revision}.log 2>&1
  cd ${ROOTDIR}

  # Check if install was successful
  if [[ -e "${simutrans_dir}/sim" ]]; then
    simutrans_load
  else
    echo "Compilation and installation of revision ${revision} failed" | log ERROR
    exit 1;
  fi
}

# ACTION: status
simutrans_status () {
  pid=$(process_status)

  if [[ $pid -gt 1 ]]; then
    echo "Running with PID: ${pid}" | log INFO
  else
    echo "Not running" | log INFO
  fi
}

# ACTION: statuscode
simutrans_status_code () {
  pid=$(process_status)

  if [[ $pid -gt 1 ]]; then
    echo 1
  else
    echo 0
  fi
}

# ACTION: start
simutrans_start () {
  # Do nothing if already running
  pid=$(process_status)
  if [[ $pid -gt 1 ]]; then
    echo "Already running with PID: ${pid}"
    exit 0
  fi

  # Check for install
  if [[ ! -e "${simutrans_dir}/sim" ]]; then
    simutrans_install
  fi

  echo "Starting server..." | log INFO

  # Restore the game if possible, otherwise load provided savegame
  if [[ -e ${simutrans_dir}/server${port}-network.sve ]]; then
    sudo -H -u $USER bash -c "( ${simutrans_dir}/sim -server $port -debug $debug -lang $lang -objects $pak 2>&1 & echo \$! > $pidfile ) >> ${log_dir}/sim.log"
    echo "Using command: ${simutrans_dir}/sim -server $port -debug $debug -lang $lang -objects $pak" | log DEBUG
  else
    sudo -H -u $USER bash -c "( ${simutrans_dir}/sim -server $port -debug $debug -lang $lang -objects $pak -load $save 2>&1 & echo \$! > $pidfile ) >> ${log_dir}/sim.log"
    echo "Using command: ${simutrans_dir}/sim -server $port -debug $debug -lang $lang -objects $pak -load $save" | log DEBUG
  fi

  simutrans_status
}

# ACTION: stop
simutrans_stop () {
  pid=$(process_status)
  if [[ $pid -gt 1 ]]; then
    kill $pid
    rm $pidfile
    echo "Server stopped PID: ${pid}" | log INFO
  else
    echo "Already stopped" | log INFO
  fi
}

# ACTION: restart
simutrans_restart() {
  simutrans_stop
  sleep 1
  simutrans_start
}

# ACTION: reload
simutrans_reload() {
  simutrans_stop

  # Backup the saves
  backup_savegames

  # Check if we need to build a new revision
  if [[ ! -d $simutrans_dir ]]; then
    simutrans_install
  fi

  simutrans_load
  simutrans_start
}


# Action switching
case $action in
  status)
    simutrans_status
    ;;
  start)
    simutrans_start
    ;;
  stop)
    simutrans_stop
    ;;
  restart)
    simutrans_restart
    ;;
  reload)
    simutrans_reload
    ;;
  statuscode)
    simutrans_status_code
    ;;
  revision)
    echo $revision
    ;;
  *)
    echo "Action ${action} does not exist."
    usage
    exit 1
    ;;
esac
