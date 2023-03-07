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

# This is the name of the symlinked port that is specified in the various
# logger config files. We will create a link from it to wherever the
# actual port is.
SYMLINK_PORT=/dev/ttyCampbell

# Defaults that will be overwritten by the preferences file, if it
# exists.
DEFAULT_OPENRVDAS_PATH=/opt/openrvdas
DEFAULT_DIR_PATH=/opt/openrvdas/local/usap/palmer
#DEFAULT_HTTP_PROXY=proxy.lmg.usap.gov:3128 #$HTTP_PROXY
DEFAULT_HTTP_PROXY=$http_proxy

DEFAULT_ACTUAL_CAMPBELL_PORT=/dev/ttyUSB0
DEFAULT_INSTALL_SIMULATOR=no
DEFAULT_RUN_SIMULATOR=no

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

DEFAULT_OPENRVDAS_PATH=$OPENRVDAS_PATH
DEFAULT_DIR_PATH=$DIR_PATH
#DEFAULT_HTTP_PROXY=proxy.lmg.usap.gov:3128 #$HTTP_PROXY
DEFAULT_HTTP_PROXY=$HTTP_PROXY

DEFAULT_ACTUAL_CAMPBELL_PORT=$ACTUAL_CAMPBELL_PORT
DEFAULT_INSTALL_SIMULATOR=$INSTALL_SIMULATOR
DEFAULT_RUN_SIMULATOR=$RUN_SIMULATOR
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
    DATA_DIR=/data/openrvdas
    if [ ! -d $DATA_DIR ]; then
        echo "#########################################################################"
        echo "Creating data directory ${DATA_DIR}. Please enter sudo password if prompted."
        sudo mkdir -p /data/openrvdas
        sudo chown rvdas /data/openrvdas
        sudo chgrp rvdas /data/openrvdas
    fi
}

###########################################################################
# Create a symlink from the actual serial port to
function create_serial_port {
    echo "#########################################################################"
    echo "Creating symlink from actual serial port ($ACTUAL_CAMPBELL_PORT) to $SYMLINK_PORT."
    echo "Please enter sudo password if prompted."
    sudo ln -f -s $ACTUAL_CAMPBELL_PORT $SYMLINK_PORT
}

###########################################################################
# Set up supervisord file to start/stop all the relevant scripts.
function set_up_supervisor {
    echo "#####################################################################"
    # Don't want existing installations to be running while we do this
    echo Stopping supervisor prior to installation.
    supervisorctl stop all

    echo Setting up supervisord file...

    TMP_SUPERVISOR_CONF=/tmp/waterwall_logger.ini

    if [ $OS_TYPE == 'MacOS' ]; then
        SUPERVISOR_CONF=/usr/local/etc/supervisor.d/waterwall_logger.ini
        OPENRVDAS_CONF=/usr/local/etc/supervisor.d/openrvdas.ini
    # If CentOS/Ubuntu/etc, different distributions hide them
    # different places. Sigh.
    elif [ $OS_TYPE == 'CentOS' ]; then
        SUPERVISOR_CONF=/etc/supervisord.d/waterwall_logger.ini
        OPENRVDAS_CONF=/etc/supervisord.d/openrvdas.ini
    elif [ $OS_TYPE == 'Ubuntu' ]; then
        SUPERVISOR_CONF=/etc/supervisor/conf.d/waterwall_logger.conf
        OPENRVDAS_CONF=/etc/supervisor/conf.d/openrvdas.conf
    else
        echo "ERROR: Unknown OS/architecture \"$OS_TYPE\"."
        exit_gracefully
    fi

    ##########
    cat >> $TMP_SUPERVISOR_CONF <<EOF
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
chown=nobody:rvdas

[inet_http_server]
port=9001

[program:waterwall_logger]
command=${OPENRVDAS_PATH}/venv/bin/python logger/listener/listen.py --config_file ${DIR_PATH}/waterwall_logger+file+influx.yaml
environment=PATH="${OPENRVDAS_PATH}/venv/bin:/usr/bin:/usr/local/bin"
directory=${OPENRVDAS_PATH}
autostart=true
autorestart=true
startretries=3
killasgroup=true
stderr_logfile=/var/log/openrvdas/waterwall_logger.stderr
stderr_logfile_maxbytes=10000000 ; 10M
stderr_logfile_maxbackups=100
user=rvdas
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
command=${OPENRVDAS_PATH}/venv/bin/python logger/listener/listen.py --config_file ${DIR_PATH}/simulate_campbell.yaml
directory=${OPENRVDAS_PATH}
autostart=${AUTOSTART_SIMULATOR}
autorestart=true
startretries=3
killasgroup=true
stderr_logfile=/var/log/openrvdas/simulate_campbell.stderr
stderr_logfile_maxbytes=10000000 ; 10M
stderr_logfile_maxbackups=100
user=rvdas
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
read -p "OpenRVDAS path? ($DEFAULT_OPENRVDAS_PATH) " OPENRVDAS_PATH
OPENRVDAS_PATH=${OPENRVDAS_PATH:-$DEFAULT_OPENRVDAS_PATH}

read -p "Path to Palmer-specific code? ($DEFAULT_DIR_PATH) " DIR_PATH
DIR_PATH=${DIR_PATH:-$DEFAULT_DIR_PATH}
echo
echo "During installation, we will create a symlink from $SYMLINK_PORT to"
echo "the actual serial port the Campbell is connected to."
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
else
    RUN_SIMULATOR='no'
fi
echo
read -p "HTTP/HTTPS proxy to use ($DEFAULT_HTTP_PROXY)? " HTTP_PROXY
HTTP_PROXY=${HTTP_PROXY:-$DEFAULT_HTTP_PROXY}
echo

#########################################################################
# Save defaults in a preferences file for the next time we run.
save_default_variables

#########################################################################
# Set up proxy, if defined
[ -z $HTTP_PROXY ] || echo Setting up proxy $HTTP_PROXY
[ -z $HTTP_PROXY ] || export http_proxy=$HTTP_PROXY
[ -z $HTTP_PROXY ] || export https_proxy=$HTTP_PROXY

#########################################################################
# Do the actual things.

set_up_data_directory

create_serial_port

set_up_supervisor

echo "#########################################################################"
echo Installation complete - happy logging!
echo
