#!/bin/bash

echo $(date) " - Starting Script"

set -e

export SUDOUSER=$1
export PASSWORD="$2"
export PRIVATEKEY=$3
export MASTER=$4
export MASTERPUBLICIPHOSTNAME=$5
export MASTERPUBLICIPADDRESS=$6
export INFRA=$7
export NODE=$8
export NODECOUNT=$9
export INFRACOUNT=${10}
export MASTERCOUNT=${11}
export ROUTING=${12}
export REGISTRYSA=${13}
export ACCOUNTKEY="${14}"
export TENANTID=${15}
export SUBSCRIPTIONID=${16}
export AADCLIENTID=${17}
export AADCLIENTSECRET="${18}"
export RESOURCEGROUP=${19}
export LOCATION=${20}
export METRICS=${21}
export LOGGING=${22}
export AZURE=${23}
export STORAGEKIND=${24}

# Determine if Commercial Azure or Azure Government
CLOUD=$( curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/location?api-version=2017-04-02&format=text" | cut -c 1-2 )
export CLOUD=${CLOUD^^}

export MASTERLOOP=$((MASTERCOUNT - 1))
export INFRALOOP=$((INFRACOUNT - 1))
export NODELOOP=$((NODECOUNT - 1))

# Run a loop playbook to ensure DNS Hostname resolution is working prior to continuing with script
echo $(date) " - Running DNS Hostname resolution check"
runuser -l $SUDOUSER -c "ansible-playbook ~/openshift-container-platform-playbooks/check-dns-host-name-resolution.yaml"
echo $(date) " - DNS Hostname resolution check complete"

# Setup NetworkManager to manage eth0
runuser -l $SUDOUSER -c "ansible-playbook /home/$SUDOUSER/openshift-ansible/playbooks/openshift-node/network_manager.yml"

echo $(date) " - Setting up NetworkManager on eth0"
# Configure resolv.conf on all hosts through NetworkManager

runuser -l $SUDOUSER -c "ansible all -b -o -m service -a \"name=dbus state=restarted\""
runuser -l $SUDOUSER -c "ansible all -b -o -m service -a \"name=NetworkManager state=restarted\""
runuser -l $SUDOUSER -c "ansible all -b -o -m service -a \"name=network state=restarted\""
echo $(date) " - NetworkManager configuration complete"

# Create /etc/origin/cloudprovider/azure.conf on all hosts if Azure is enabled
if [[ $AZURE == "true" ]]
then
	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/create-azure-conf.yaml"
	if [ $? -eq 0 ]
	then
		echo $(date) " - Creation of Cloud Provider Config (azure.conf) completed on all nodes successfully"
	else
		echo $(date) " - Creation of Cloud Provider Config (azure.conf) completed on all nodes failed to complete"
		exit 13
	fi
fi

# Initiating installation of OpenShift Origin prerequisites using Ansible Playbook
echo $(date) " - Running Prerequisites via Ansible Playbook"
runuser -l $SUDOUSER -c "ansible-playbook -f 10 /home/$SUDOUSER/openshift-ansible/playbooks/prerequisites.yml"
echo $(date) " - Prerequisites check complete"

# Initiating installation of OpenShift Origin using Ansible Playbook
echo $(date) " - Installing OpenShift Container Platform via Ansible Playbook"

runuser -l $SUDOUSER -c "ansible-playbook -f 10 /home/$SUDOUSER/openshift-ansible/playbooks/deploy_cluster.yml"
echo $(date) " - OpenShift Origin Cluster install complete"
echo $(date) " - Running additional playbooks to finish configuring and installing other components"

echo $(date) " - Modifying sudoers"

sed -i -e "s/Defaults    requiretty/# Defaults    requiretty/" /etc/sudoers
sed -i -e '/Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"/aDefaults    env_keep += "PATH"' /etc/sudoers

echo $(date) "- Re-enabling requiretty"

sed -i -e "s/# Defaults    requiretty/Defaults    requiretty/" /etc/sudoers

# Adding user to OpenShift authentication file
echo $(date) "- Adding OpenShift user"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/addocpuser.yaml"

# Assigning cluster admin rights to OpenShift user
echo $(date) "- Assigning cluster admin rights to user"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/assignclusteradminrights.yaml"

# Configure Docker Registry to use Azure Storage Account
echo $(date) "- Configuring Docker Registry to use Azure Storage Account"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/$DOCKERREGISTRYYAML"

if [[ $AZURE == "true" ]]
then
	# Execute setup-azure-master and setup-azure-node playbooks to configure Azure Cloud Provider
	echo $(date) "- Configuring OpenShift Cloud Provider to be Azure"

	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/setup-azure-master-origin.yaml"

	if [ $? -eq 0 ]
	then
	   echo $(date) " - Cloud Provider setup of master config on Master Nodes completed successfully"
	else
	   echo $(date) "- Cloud Provider setup of master config on Master Nodes failed to completed"
	   exit 7
	fi
	
	echo $(date) "- Sleep for 60"
	
	sleep 60
	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/setup-azure-node-master-origin.yaml"

	if [ $? -eq 0 ]
	then
	   echo $(date) " - Cloud Provider setup of node config on Master Nodes completed successfully"
	else
	   echo $(date) "- Cloud Provider setup of node config on Master Nodes failed to completed"
	   exit 8
	fi
	
	echo $(date) "- Sleep for 60"
	
	sleep 60
	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/setup-azure-node-origin.yaml"

	if [ $? -eq 0 ]
	then
	   echo $(date) " - Cloud Provider setup of node config on App Nodes completed successfully"
	else
	   echo $(date) "- Cloud Provider setup of node config on App Nodes failed to completed"
	   exit 9
	fi
	
	echo $(date) "- Sleep for 120"
	
	sleep 120
	
	echo $(date) " - Rebooting cluster to complete installation"
	runuser -l $SUDOUSER -c  "oc label --overwrite nodes $MASTER-0 openshift-infra=apiserver"
	runuser -l $SUDOUSER -c  "oc label --overwrite nodes --all logging-infra-fluentd=true logging=true"
	runuser -l $SUDOUSER -c  "ansible localhost -b -o -m service -a 'name=openvswitch state=restarted'"
	runuser -l $SUDOUSER -c  "ansible localhost -b -o -m service -a 'name=origin-master-api state=restarted'"
	runuser -l $SUDOUSER -c  "ansible localhost -b -o -m service -a 'name=origin-master-controllers state=restarted'"
	runuser -l $SUDOUSER -c  "ansible localhost -b -o -m service -a 'name=origin-node state=restarted'"
	runuser -l $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/reboot-master-origin.yaml"
	runuser -l $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/reboot-nodes.yaml"

	if [ $? -eq 0 ]
	then
	   echo $(date) " - Cloud Provider setup of OpenShift Cluster completed successfully"
	else
	   echo $(date) "- Cloud Provider setup did not complete"
	   exit 10
	fi
	
	# Create Storage Class
	echo $(date) "- Creating Storage Class"

	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/configurestorageclass.yaml"
	echo $(date) "- Sleep for 15"
	sleep 15
	
	# Installing Service Catalog, Ansible Service Broker and Template Service Broker
	
	echo $(date) "- Installing Service Catalog, Ansible Service Broker and Template Service Broker"
	runuser -l $SUDOUSER -c "ansible-playbook -f 10 /home/$SUDOUSER/openshift-ansible/playbooks/openshift-service-catalog/config.yml"
	echo $(date) "- Service Catalog, Ansible Service Broker and Template Service Broker installed successfully"
	
fi

# Configure Metrics

if [ $METRICS == "true" ]
then
	sleep 30	
	echo $(date) "- Determining Origin version from rpm"
	OO_VERSION="v"$(rpm -q origin | cut -d'-' -f 2 | head -c 3)
	echo $(date) "- Deploying Metrics"
	if [ $AZURE == "true" ]
	then
		runuser -l $SUDOUSER -c "ansible-playbook -f 10 /home/$SUDOUSER/openshift-ansible/playbooks/openshift-metrics/config.yml -e openshift_metrics_install_metrics=True -e openshift_metrics_cassandra_storage_type=dynamic -e openshift_metrics_image_version=$OO_VERSION"
	else
		runuser -l $SUDOUSER -c "ansible-playbook -f 10 /home/$SUDOUSER/openshift-ansible/playbooks/openshift-metrics/config.yml -e openshift_metrics_install_metrics=True -e openshift_metrics_image_version=$OO_VERSION"
	fi
	if [ $? -eq 0 ]
	then
	   echo $(date) " - Metrics configuration completed successfully"
	else
	   echo $(date) "- Metrics configuration failed"
	   exit 11
	fi
fi

# Configure Logging

if [ $LOGGING == "true" ] 
then
	sleep 60
	echo $(date) "- Deploying Logging"
	if [ $AZURE == "true" ]
	then
		runuser -l $SUDOUSER -c "ansible-playbook -f 10 /home/$SUDOUSER/openshift-ansible/playbooks/openshift-logging/config.yml -e openshift_logging_install_logging=True -e openshift_logging_es_pvc_dynamic=true -e openshift_master_dynamic_provisioning_enabled=True"
	else
		runuser -l $SUDOUSER -c "ansible-playbook -f 10 /home/$SUDOUSER/openshift-ansible/playbooks/openshift-logging/config.yml -e openshift_logging_install_logging=True"
	fi
	if [ $? -eq 0 ]
	then
	   echo $(date) " - Logging configuration completed successfully"
	else
	   echo $(date) "- Logging configuration failed"
	   exit 12
	fi
fi

# Delete yaml files
echo $(date) "- Deleting unecessary files"

rm -rf /home/${SUDOUSER}/openshift-container-platform-playbooks

echo $(date) "- Sleep for 30"

sleep 30

echo $(date) " - Script complete"
