#!/bin/bash -e

# OpenRVDAS is available as open source under the MIT License at
#   https:/github.com/oceandatatools/openrvdas
#
# This script tweaks a standard OpenRVDAS installation to run Palmer Station
# specific code and configurations. It should be run as the user
# who will be running OpenRVDAS (e.g. 'rvdas'):
#
#     /opt/openrvdas/local/usap/palmer/install_waterwall.sh
#
# The script has been designed to be idempotent, that is, if can be
# run over again with no ill effects.
#
# Once installed, you should be able to start/stop/disable the
# relevant services using supervisorctl, either via the command line
# or via the webconsole at localhost:9001
#
# This script is somewhat rudimentary and has not been extensively
# tested. If it fails on some part of the installation, there is no
# guarantee that fixing the specific issue and simply re-running will
# produce the desired result.  Bug reports, and even better, bug
# fixes, will be greatly appreciated.

PREFERENCES_FILE='.install_waterwall_preferences'

#
OPENRVDAS_PATH=/opt/openrvdas
DIR_PATH=/opt/openrvdas/local/usap/palmer

DEFAULT_ACTUAL_CAMPBELL_PORT=/dev/ttyUSB0
DEFAULT_INSTALL_SIMULATOR=no
DEFAULT_SIMULATOR_WRITE_PORT=/dev/ttyUSB1
DEFAULT_RUN_SIMULATOR=no

DEFAULT_DATA_DIR=/data/openrvdas

RVDAS_USER=$USER

###########################################################################
###########################################################################
function exit_gracefully {
    echo Exiting.
    return -1 2> /dev/null || exit -1  # exit correctly if sourced/bashed
}

###########################################################################
###########################################################################
function get_os_type {
    if [[ `uname -s` == 'Darwin' ]];then
        OS_TYPE=MacOS

    elif [[ `uname -s` == 'Linux' ]];then
        if [[ ! -z `grep "NAME=\"Ubuntu\"" /etc/os-release` ]] || [[ ! -z `grep "NAME=\"Debian" /etc/os-release` ]] || [[ ! -z `grep "NAME=\"Raspbian" /etc/os-release` ]];then
            OS_TYPE=Ubuntu
        elif [[ ! -z `grep "NAME=\"CentOS Stream\"" /etc/os-release` ]] || [[ ! -z `grep "NAME=\"CentOS Linux\"" /etc/os-release` ]] || [[ ! -z `grep "NAME=\"Red Hat Enterprise Linux Server\"" /etc/os-release` ]] || [[ ! -z `grep "NAME=\"Red Hat Enterprise Linux Workstation\"" /etc/os-release` ]];then
            OS_TYPE=CentOS
            if [[ ! -z `grep "VERSION_ID=\"7" /etc/os-release` ]];then
                OS_VERSION=7
            elif [[ ! -z `grep "VERSION_ID=\"8" /etc/os-release` ]];then
                OS_VERSION=8
            elif [[ ! -z `grep "VERSION_ID=\"9" /etc/os-release` ]];then
                OS_VERSION=9
            else
                echo "Sorry - unknown CentOS/RHEL Version! - exiting."
                exit_gracefully
            fi
        else
            echo Unknown Linux variant!
            exit_gracefully
        fi
    else
        echo Unknown OS type: `uname -s`
        exit_gracefully
    fi
    echo Recognizing OS type as $OS_TYPE
}

###########################################################################
###########################################################################
# Read any pre-saved default variables from file
function set_default_variables {
    # Read in the preferences file, if it exists, to overwrite the defaults.
    if [ -e $PREFERENCES_FILE ]; then
        echo Reading pre-saved defaults from "$PREFERENCES_FILE"
        source $PREFERENCES_FILE
    fi
}

###########################################################################
###########################################################################
# Save defaults in a preferences file for the next time we run.
function save_default_variables {
    cat > $PREFERENCES_FILE <<EOF
# Defaults written by/to be read by utils/install_influxdb.sh

DEFAULT_ACTUAL_CAMPBELL_PORT=$ACTUAL_CAMPBELL_PORT
DEFAULT_INSTALL_SIMULATOR=$INSTALL_SIMULATOR
DEFAULT_SIMULATOR_WRITE_PORT=$SIMULATOR_WRITE_PORT
DEFAULT_RUN_SIMULATOR=$RUN_SIMULATOR

DEFAULT_DATA_DIR=$DATA_DIR
EOF
}

#########################################################################
#########################################################################
# Return a normalized yes/no for a value
yes_no() {
    QUESTION=$1
    DEFAULT_ANSWER=$2

    while true; do
        read -p "$QUESTION ($DEFAULT_ANSWER) " yn
        case $yn in
            [Yy]* )
                YES_NO_RESULT=yes
                break;;
            [Nn]* )
                YES_NO_RESULT=no
                break;;
            "" )
                YES_NO_RESULT=$DEFAULT_ANSWER
                break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

###########################################################################
# Create a symlink from the actual serial port to
function set_up_data_directory {
    if [ ! -d $DATA_DIR ]; then
        echo "#########################################################################"
        echo "Creating data directory ${DATA_DIR}."
        echo "Please enter sudo password if prompted."
        sudo mkdir -p $DATA_DIR
        sudo chown $RVDAS_USER $DATA_DIR
        sudo chgrp wheel $DATA_DIR
    fi
}

###########################################################################
# Create the config files we'll be using, by copying actual serial port location
# into the dist config files.
function create_config_files {
    echo "#########################################################################"
    echo "Creating config files."
    if [ ! -d ${DIR_PATH}/configs ]; then
        echo "Creating configs subdirectory."
        mkdir ${DIR_PATH}/configs
    fi
    for CONFIG_DIST_PATH in ${DIR_PATH}/dist/*.yaml.dist; do
        CONFIG_DIST=$(echo $CONFIG_DIST_PATH|sed -e "s/.*dist\///g")
        CONFIG=$(echo $CONFIG_DIST|sed -e "s/.yaml.dist/.yaml/")
        echo "    Copying $CONFIG_DIST -> $CONFIG"
        # Make replacements
        cat $CONFIG_DIST_PATH \
          | sed "s:%SERIAL_READ_PORT%:${SERIAL_READ_PORT}:g" \
          | sed "s:%SIMULATOR_WRITE_PORT%:${SIMULATOR_WRITE_PORT}:g" \
          | sed "s:%DATA_DIR%:${DATA_DIR}:g" \
          > ${DIR_PATH}/configs/${CONFIG}
    done
}

###########################################################################
# Set up supervisord file to start/stop all the relevant scripts.
function set_up_supervisor {
    echo "#####################################################################"
    # Don't want existing installations to be running while we do this
    echo Stopping supervisor prior to installation.
    supervisorctl stop all || echo "Unable to stop supervisor?!?"

    echo Setting up supervisord file...
    TMP_SUPERVISOR_CONF=/tmp/waterwall_logger.ini

    if [ $OS_TYPE == 'MacOS' ]; then
        RVDAS_GROUP=wheel
        SUPERVISOR_CONF=/usr/local/etc/supervisor.d/waterwall_logger.ini
        OPENRVDAS_CONF=/usr/local/etc/supervisor.d/openrvdas.ini
    # If CentOS/Ubuntu/etc, different distributions hide them
    # different places. Sigh.
    elif [ $OS_TYPE == 'CentOS' ]; then
        RVDAS_GROUP=$RVDAS_USER
        SUPERVISOR_CONF=/etc/supervisord.d/waterwall_logger.ini
        OPENRVDAS_CONF=/etc/supervisord.d/openrvdas.ini
    elif [ $OS_TYPE == 'Ubuntu' ]; then
        RVDAS_GROUP=$RVDAS_USER
        SUPERVISOR_CONF=/etc/supervisor/conf.d/waterwall_logger.conf
        OPENRVDAS_CONF=/etc/supervisor/conf.d/openrvdas.conf
    else
        echo "ERROR: Unknown OS/architecture \"$OS_TYPE\"."
        exit_gracefully
    fi

    ##########
    cat > $TMP_SUPERVISOR_CONF <<EOF
; This file, when used to replace /etc/supervisor/conf.d/openrvdas.conf,
; will directly run the waterwall_logger+file+influx.yaml logger instead off
; starting a logger_manager and allowing the user to select different logger
; configurations. It is simpler, and therefore more robust, than running the
; full Django-backed OpenRVDAS GUI.logger
;
; The logger can still be started and stopped via the supervisorctl web
; interface at hostname:9001

; First, override the default socket permissions to allow user
; rvdas to run supervisorctl
[unix_http_server]
file=/var/run/supervisor.sock   ; (the path to the socket file)
chmod=0770              ; socket file mode (default 0700)
chown=nobody:${RVDAS_GROUP}

[inet_http_server]
port=9001

[program:waterwall_logger]
command=${OPENRVDAS_PATH}/venv/bin/python logger/listener/listen.py --config_file ${DIR_PATH}/configs/waterwall_logger+file+influx.yaml
environment=PATH="${OPENRVDAS_PATH}/venv/bin:/usr/bin:/usr/local/bin"
directory=${OPENRVDAS_PATH}
autostart=true
autorestart=true
startretries=3
killasgroup=true
stderr_logfile=/var/log/openrvdas/waterwall_logger.stderr
stderr_logfile_maxbytes=10000000 ; 10M
stderr_logfile_maxbackups=100
user=${RVDAS_USER}
EOF

    # If user wants the simulator installed, add it to the
    # supervisorctl config file here.
    if [[ $INSTALL_SIMULATOR == 'yes' ]];then
        if [[ $RUN_SIMULATOR == 'yes' ]];then
            AUTOSTART_SIMULATOR=true
        else
            AUTOSTART_SIMULATOR=false
        fi

        # Create the config file in /tmp
        cat >> $TMP_SUPERVISOR_CONF <<EOF

[program:simulate_campbell]
command=${OPENRVDAS_PATH}/venv/bin/python logger/listener/listen.py --config_file ${DIR_PATH}/configs/simulate_campbell.yaml
directory=${OPENRVDAS_PATH}
autostart=${AUTOSTART_SIMULATOR}
autorestart=true
startretries=3
killasgroup=true
stderr_logfile=/var/log/openrvdas/simulate_campbell.stderr
stderr_logfile_maxbytes=10000000 ; 10M
stderr_logfile_maxbackups=100
user=${RVDAS_USER}
EOF
    fi  # end of if [[ $INSTALL_SIMULATOR == 'yes' ]]

    # Copy newly-created config file into the supervisord directory
    # and disable the existing OpenRVDAS config, if it hasn't already
    # been disabled.
    sudo cp -f $TMP_SUPERVISOR_CONF $SUPERVISOR_CONF
    if [[ -e $OPENRVDAS_CONF ]]; then
        sudo mv $OPENRVDAS_CONF ${OPENRVDAS_CONF}.bak
    fi

    echo Done setting up supervisor files. Reloading...
    supervisorctl reload
}

###########################################################################

###########################################################################
###########################################################################
# Start of actual script
###########################################################################
###########################################################################

# Figure out what type of OS we've got running
get_os_type

# Read from the preferences file in $PREFERENCES_FILE, if it exists
set_default_variables

if [ "$(whoami)" == "root" ]; then
    echo "ERROR: installation script must NOT be run as root."
    exit_gracefully
fi

# Set creation mask so that everything we install is, by default,
# world readable/executable.
umask 022

echo "#####################################################################"
echo Palmer Station customization script.
echo "#####################################################################"
echo
echo "This script will customize a standard OpenRVDAS installation to work"
echo "with the Palmer Station waterwall."
echo
echo "For the script to work properly, OpenRVDAS must be installed at the default"
echo "location of ${OPENRVDAS_PATH}, and the Palmer-specific code must be either"
echo "installed or linked to ${DIR_PATH}."

# Check that installations are where we expect them
if [ ! -f "${OPENRVDAS_PATH}/INSTALL.md" ]; then
    echo "ERROR: Did not find OpenRVDAS installation at \"${OPENRVDAS_PATH}\" - exiting."
    exit_gracefully
fi
if [ ! -f "${DIR_PATH}/install_waterwall.sh" ]; then
    echo "ERROR: Did not find Palmer code installation at \"${DIR_PATH}\" - exiting."
    exit_gracefully
fi

echo
echo "During installation, we will create copies of logger config files that"
echo "point to the actual serial port location on your machine that the Campbell"
echo "is connected to."
echo
read -p "Actual Campbell serial port? ($DEFAULT_ACTUAL_CAMPBELL_PORT) " ACTUAL_CAMPBELL_PORT
ACTUAL_CAMPBELL_PORT=${ACTUAL_CAMPBELL_PORT:-$DEFAULT_ACTUAL_CAMPBELL_PORT}
echo
echo "Do you want to install a 'simulator' script (simulate_campbell.py) that feeds"
echo "canned data to the logger's serial port? If installed, the simulator can be"
echo "activated/deactivated via supervisorctl."
echo
yes_no "Install simulator? " $DEFAULT_INSTALL_SIMULATOR
INSTALL_SIMULATOR=$YES_NO_RESULT
if [ $INSTALL_SIMULATOR == 'yes' ]; then
    yes_no "Should the simulator be run by default at system startup?" $DEFAULT_RUN_SIMULATOR
    RUN_SIMULATOR=$YES_NO_RESULT

    if [ $INSTALL_SIMULATOR == 'yes' ]; then
        echo
        echo "The simulator will write to a (different!) serial port that should be connected"
        echo "by cable to the serial port that the logger will be reading from."
        echo
        read -p "What serial port will the simulator be writing to?  ($DEFAULT_SIMULATOR_WRITE_PORT) " SIMULATOR_WRITE_PORT
        SIMULATOR_WRITE_PORT=${SIMULATOR_WRITE_PORT:-$DEFAULT_SIMULATOR_WRITE_PORT}
    fi
else
    RUN_SIMULATOR='no'
fi

echo
read -p "Directory to write logged data to? ($DEFAULT_DATA_DIR) " DATA_DIR
DATA_DIR=${DATA_DIR:-$DEFAULT_DATA_DIR}
echo

#########################################################################
# Save defaults in a preferences file for the next time we run.
save_default_variables

#########################################################################
# Do the actual things.

set_up_data_directory

create_config_files

set_up_supervisor

echo "#########################################################################"
echo Installation complete - happy logging!
echo
