#!/bin/bash

# Copyright (c) Microsoft Corporation. All Rights Reserved.
# Licensed under the MIT license. See LICENSE file on the project webpage for details.

# print commands and arguments as they are executed
set -x

echo "Starting Open edX multiserver install on pid $$"
date
ps axjf

#############
# Parameters
#############

AZUREUSER=$1
PASSWORD=$2
HOMEDIR="/home/$AZUREUSER"
VMNAME=`hostname`
echo "User: $AZUREUSER"
echo "User home dir: $HOMEDIR"
echo "vmname: $VMNAME"

###################
# Common Functions
###################

ensureAzureNetwork()
{
  # ensure the host name is resolvable
  hostResolveHealthy=1
  for i in {1..120}; do
    host $VMNAME
    if [ $? -eq 0 ]
    then
      # hostname has been found continue
      hostResolveHealthy=0
      echo "the host name resolves"
      break
    fi
    sleep 1
  done
  if [ $hostResolveHealthy -ne 0 ]
  then
    echo "host name does not resolve, aborting install"
    exit 1
  fi

  # ensure the network works
  networkHealthy=1
  for i in {1..12}; do
    wget -O/dev/null http://bing.com
    if [ $? -eq 0 ]
    then
      # hostname has been found continue
      networkHealthy=0
      echo "the network is healthy"
      break
    fi
    sleep 10
  done
  if [ $networkHealthy -ne 0 ]
  then
    echo "the network is not healthy, aborting install"
    ifconfig
    ip a
    exit 2
  fi
}
ensureAzureNetwork

###################################################
# Configure SSH keys
###################################################
time sudo apt-get -y update && sudo apt-get -y upgrade
sudo apt-get -y install sshpass
ssh-keygen -f $HOMEDIR/.ssh/id_rsa -t rsa -N ''

#copy so ansible can ssh localhost if it decides to
cat $HOMEDIR/.ssh/id_rsa.pub >> $HOMEDIR/.ssh/authorized_keys && echo "Key copied to localhost"
#terrible hack for getting keys onto db server
cat $HOMEDIR/.ssh/id_rsa.pub | sshpass -p $PASSWORD ssh -o "StrictHostKeyChecking no" $AZUREUSER@10.0.0.20 'cat >> .ssh/authorized_keys && echo "Key copied MySQL"'
cat $HOMEDIR/.ssh/id_rsa.pub | sshpass -p $PASSWORD ssh -o "StrictHostKeyChecking no" $AZUREUSER@10.0.0.30 'cat >> .ssh/authorized_keys && echo "Key copied MongoDB"'

#make sure premissions are correct
sudo chown -R $AZUREUSER:$AZUREUSER $HOMEDIR/.ssh/

###################################################
# Update Ubuntu and install prereqs
###################################################

time sudo apt-get -y update && sudo apt-get -y upgrade
time sudo apt-get install -y build-essential software-properties-common python-software-properties curl git-core libxml2-dev libxslt1-dev libfreetype6-dev python-pip python-apt python-dev libxmlsec1-dev swig
time sudo pip install --upgrade pip
time sudo pip install --upgrade virtualenv

###################################################
# Pin specific version of Open edX (named-release/cypress for now)
###################################################
export OPENEDX_RELEASE='named-release/juniper'
cat >/tmp/extra_vars.yml <<EOL
---
edx_platform_version: "$OPENEDX_RELEASE"
certs_version: "$OPENEDX_RELEASE"
forum_version: "$OPENEDX_RELEASE"
xqueue_version: "$OPENEDX_RELEASE"
configuration_version: "master"
edx_ansible_source_repo: "https://github.com/srwiser/configuration"

EOL

###################################################
# Set database vars
###################################################
cat >/tmp/db_vars.yml <<EOL 
---
EDXAPP_MYSQL_USER_HOST: "%"
EDXAPP_MYSQL_HOST: "10.0.0.20"
EDXLOCAL_MYSQL_BIND_IP: "0.0.0.0"
XQUEUE_MYSQL_HOST: "10.0.0.20"
ORA_MYSQL_HOST: "10.0.0.20"
MONGO_BIND_IP: "0.0.0.0"
FORUM_MONGO_HOSTS: ["10.0.0.30"]
EDXAPP_MONGO_HOSTS: ["10.0.0.30"]
EDXAPP_MEMCACHE: ["10.0.0.20:11211"]
MEMCACHED_BIND_IP: "0.0.0.0"

EOL

###################################################
# Download configuration repo and start ansible
###################################################

cd /tmp
time git clone https://github.com/srwiser/configuration.git
cd configuration
time git checkout master
time sudo pip install -r requirements.txt
cd playbooks/appsemblerPlaybooks

#create inventory.ini file
echo "[mongo-server]" > inventory.ini
echo "10.0.0.30" >> inventory.ini
echo "" >> inventory.ini
echo "[mysql-server]" >> inventory.ini
echo "10.0.0.20" >> inventory.ini
echo "" >> inventory.ini
echo "[edxapp-primary-server]" >> inventory.ini
echo "localhost" >> inventory.ini

curl https://raw.githubusercontent.com/srwiser/openedx-azure-multiserver/master/server-vars.yml > /tmp/server-vars.yml

sudo ansible-playbook -i inventory.ini -u $AZUREUSER --private-key=$HOMEDIR/.ssh/id_rsa multiserver_deploy.yml -e@/tmp/server-vars.yml -e@/tmp/extra_vars.yml -e@/tmp/db_vars.yml

date
echo "Completed Open edX multiserver provision on pid $$"
