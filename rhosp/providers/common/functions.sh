#!/bin/bash

function is_registry_insecure() {
    echo "DEBUG: is_registry_insecure: $@"
    local registry=`echo $1 | sed 's|^.*://||' | cut -d '/' -f 1`
    if ! curl -sI --connect-timeout 60 https://$registry/ ; then
        echo "DEBUG: is_registry_insecure: $registry is insecure"
        return 0
    fi
    echo "DEBUG: is_registry_insecure: $registry is secure"
    return 1
}

function collect_stack_details() {
    local log_dir=$1
    [ -n "$log_dir" ] || {
        echo "WARNING: empty log_dir provided.. logs collection skipped"
        return
    }
    if [ ! -e ~/stackrc ] ; then
        echo "WARNING: there is no ~/stackrc. Stack was not deployed."
        return
    fi
    source ~/stackrc
    # collect stack details
    echo "INFO: collect stack outputs"
    openstack stack output show -f json --all overcloud | sed 's/\\n/\n/g' > ${log_dir}/stack_outputs.log
    echo "INFO: collect stack environment"
    openstack stack environment show -f json overcloud | sed 's/\\n/\n/g' > ${log_dir}/stack_environment.log

    # ensure stack is not failed
    local status=$(openstack stack show -f json overcloud | jq ".stack_status")
    if [[ ! "$status" =~ 'COMPLETE' ]] ; then
        echo "ERROR: stack status $status"
        echo "ERROR: openstack stack failures list"
        openstack stack failures list --long overcloud | sed 's/\\n/\n/g' | tee ${log_dir}/stack_failures.log

        echo "INFO: collect failed resources"
        rm -f ${log_dir}/stack_failed_resources.log
        local resource
        local stack
        openstack stack resource list --filter status=FAILED -n 10 -f json overcloud | jq -r -c ".[] | .resource_name+ \" \" + .stack_name" | while read resource stack ; do
            echo "ERROR: $resource $stack" >> ./stack_failed_resources.log
            openstack stack resource show -f shell $stack $resource | sed 's/\\n/\n/g' >> ${log_dir}/stack_failed_resources.log
            echo -e "\n\n" >> ./stack_failed_resources.log
        done

        echo "INFO: collect failed deployments"
        rm -f ${log_dir}/stack_failed_deployments.log
        local id
        openstack software deployment list --format json | jq -r -c ".[] | select(.status != \"COMPLETE\") | .id" | while read id ; do
            openstack software deployment show --format shell $id | sed 's/\\n/\n/g' >> ${log_dir}/stack_failed_deployments.log
            echo -e "\n\n" >> ./stack_failed_deployments.log
        done
    fi
}

function get_ctlplane_ips() {
    local name=${1:-}
    if [[ "$USE_PREDEPLOYED_NODES" == true ]]; then
        [[ "$name" == 'controller' ]] && echo "${overcloud_cont_prov_ip//,/ }" && return
        [[ "$name" == 'contrailcontroller' ]] && echo "${overcloud_ctrlcont_prov_ip//,/ }" && return
        [[ "$name" == 'novacompute' ]] && echo "${overcloud_compute_prov_ip//,/ }" && return
        [[ "$name" == 'contraildpdk' ]] && echo "${overcloud_dpdk_prov_ip//,/ }" && return
        [[ "$name" == 'contrailsriov' ]] && echo "${overcloud_sriov_prov_ip//,/ }" && return
        [[ "$name" == 'storage' ]] && echo "${overcloud_ceph_prov_ip//,/ }" && return
        [ -z "$name" ] && echo "${overcloud_cont_prov_ip//,/ } ${overcloud_ctrlcont_prov_ip//,/ } ${overcloud_compute_prov_ip//,/ } ${overcloud_dpdk_prov_ip//,/ } ${overcloud_sriov_prov_ip//,/ } ${overcloud_ceph_prov_ip//,/ }" && return
        echo "ERROR: unsupported node role $name"
        exit 1;
    fi
    [[ -z "$OS_AUTH_URL" ]] && source ~/stackrc
    if [[ -n "$name" ]]; then
        openstack server list -c Networks -f value --name "\-${name}-" | awk -F '=' '{print $NF}' | xargs
    else
        openstack server list -c Networks -f value | awk -F '=' '{print $NF}' | xargs
    fi
}

function get_first_controller_ctlplane_ip() {
    get_ctlplane_ips 'controller' | awk '{print $1}'
}

function get_vip() {
    local vip_name=$1
    ssh $ssh_opts $SSH_USER_OVERCLOUD@$openstack_node sudo hiera -c /etc/puppet/hiera.yaml $vip_name
}

function get_openstack_node_ips() {
    local openstack_node=$1
    local name=$2
    local network=$3
    if [[ "${USE_PREDEPLOYED_NODES,,}" == true ]]; then
        # TODO: modify as network isolation be implemented for predeployed nodes
        get_ctlplane_ips $name
    fi
    ssh $ssh_opts $SSH_USER_OVERCLOUD@$openstack_node \
         cat /etc/hosts | grep overcloud-${name}-[0-9]\.${network} | awk '{print $1}'| xargs
}

function _print_fqdn() {
    [ -z "$2" ] || printf "%s.$1 " ${2//,/ }
}

function get_openstack_node_names() {
    local openstack_node=$1
    local name=$2
    local network=$3
    if [[ "${USE_PREDEPLOYED_NODES,,}" == true ]]; then
        local suffix="${network}.${domain}"
        [[ "$name" == 'controller' ]] && _print_fqdn $suffix $overcloud_cont_instance && return
        [[ "$name" == 'contrailcontroller' ]] && _print_fqdn $suffix $overcloud_ctrlcont_instance && return
        [[ "$name" == 'novacompute' ]] && _print_fqdn $suffix $overcloud_compute_instance && return
        [[ "$name" == 'contraildpdk' ]] && _print_fqdn $suffix $overcloud_dpdk_instance && return
        [[ "$name" == 'contrailsriov' ]] && _print_fqdn $suffix $overcloud_sriov_instance && return
        [[ "$name" == 'storage' ]] && _print_fqdn $suffix $overcloud_ceph_instance && return
        echo "ERROR: unsupported node role $name"
        exit 1;
    fi
    ssh $ssh_opts $SSH_USER_OVERCLOUD@$openstack_node \
         cat /etc/hosts | grep overcloud-${name}-[0-9]\.${network} | awk '{print $2}'| xargs
}

function update_undercloud_etc_hosts() {
    # patch hosts to resole overcloud by fqdn
    echo "INFO: remove from undercloud /etc/hosts old overcloud fqdns if any"
    sudo sed -i "/overcloud-/d" /etc/hosts
    echo "INFO: update /etc/hosts with overcloud ips & fqdns"
    local openstack_node=$(get_first_controller_ctlplane_ip)
    ssh $ssh_opts $SSH_USER_OVERCLOUD@$openstack_node sudo grep "overcloud\-" /etc/hosts 2>/dev/null | sudo tee -a /etc/hosts
    if [[ -z "$overcloud_compute_instance" && ( -z "$overcloud_ctrlcont_instance" || $CONTROL_PLANE_ORCHESTRATOR == 'operator' ) ]] ; then
        # User first Controller for AIO case.
        # Openstack & contrail control plane & agent (compute) are on same node.
        # And VIPs are not working properly because of vrouter.
        local ctlplane_vip=$openstack_node
        local public_vip=$(get_openstack_node_ips $openstack_node controller external | awk '{print $1}')
        local internal_api_vip=$(get_openstack_node_ips $openstack_node controller internalapi | awk '{print $1}')
    else
        local ctlplane_vip=$fixed_vip
        local public_vip=$(get_vip public_virtual_ip $openstack_node)
        local internal_api_vip=$(get_vip internal_api_virtual_ip $openstack_node)
    fi
    [ -n "$public_vip" ] || public_vip=$ctlplane_vip
    [ -n "$internal_api_vip" ] || internal_api_vip=$ctlplane_vip
    echo "INFO: remove from undercloud /etc/hosts old overcloud fqdns for vips if any"
    sudo sed -i "/overcloud.${domain}/d" /etc/hosts
    sudo sed -i "/overcloud.internalapi.${domain}/d" /etc/hosts
    sudo sed -i "/overcloud.ctlplane.${domain}/d" /etc/hosts
    echo "INFO: update /etc/hosts for overcloud vips & fqdns"
    cat <<EOF | sudo tee -a /etc/hosts
# Overcloud VIPs and Nodes
${public_vip} overcloud.${domain}
${internal_api_vip} overcloud.internalapi.${domain}
${ctlplane_vip} overcloud.ctlplane.${domain}
EOF
    echo "INFO: updated undercloud /etc/hosts"
    sudo cat /etc/hosts

    if [[ $CONTROL_PLANE_ORCHESTRATOR == 'operator' ]] ; then
        # copy FQDN to tf node
        local ssh_user=${EXTERNAL_CONTROLLER_SSH_USER:-$SSH_USER}
        local addr=$overcloud_ctrlcont_prov_ip
        [ -z "$ssh_user" ] || addr="$ssh_user@$addr"
        cat <<EOE | ssh $ssh_opts $addr
# remove old records
sudo sed "/overcloud.${domain}\|overcloud.\(internalapi\|ctlplane\).${domain}/d" /etc/hosts
cat <<EOF | sudo tee -a /etc/hosts
# Overcloud VIPs and Nodes
${public_vip} overcloud.${domain}
${internal_api_vip} overcloud.internalapi.${domain}
${ctlplane_vip} overcloud.ctlplane.${domain}
EOF
EOE
    fi
}

function collect_overcloud_env() {
    local openstack_node=$(get_first_controller_ctlplane_ip)

    if [[ -n "$EXTERNAL_CONTROLLER_NODES" ]] ; then
        local ext_nodes="${EXTERNAL_CONTROLLER_NODES//,/ }"
        local first_ext_node=$(echo $ext_nodes | cut -d ' ' -f 1)
        DEPLOYMENT_ENV['CONFIG_API_VIP']="$first_ext_node"
        DEPLOYMENT_ENV['ANALYTICS_API_VIP']="$first_ext_node"
        CONTROLLER_NODES="$ext_nodes"
        DEPLOYMENT_ENV['CONTROL_NODES']="$ext_nodes"
    else
        DEPLOYMENT_ENV['CONFIG_API_VIP']="overcloud.internalapi.${domain}"
        DEPLOYMENT_ENV['ANALYTICS_API_VIP']="overcloud.internalapi.${domain}"
        # agent and contrail conroller to be on same network fo vdns test for ipa case
        # so, use tenant
        CONTROLLER_NODES="$(get_openstack_node_names $openstack_node contrailcontroller tenant)"
        # control nodes are for net isolation case when tenant is on different networks
        # (for control it is needed to use IP instead of fqdn (tls always uses fqdns))
        DEPLOYMENT_ENV['CONTROL_NODES']="$(get_openstack_node_ips $openstack_node contrailcontroller tenant)"
    fi

    # control nodes are for net isolation case when tenant is on different networks
    # (for control it is needed to use IP instead of fqdn (tls always uses fqdns))
    if [ -z "${DEPLOYMENT_ENV['CONTROL_NODES']}" ] ; then
        # Openstack and Contrail Controllers are on same nodes (aio)
        DEPLOYMENT_ENV['CONTROL_NODES']="$(get_openstack_node_ips $openstack_node controller tenant)"
    fi

    # agent and contrail conroller to be on same network fo vdns test for ipa case
    # so, use tenant
    if [ -z "$CONTROLLER_NODES" ] ; then
        # Openstack and Contrail Controllers are on same nodes (aio)
        CONTROLLER_NODES="$(get_openstack_node_names $openstack_node controller tenant)"
    else
        # Openstack nodes are separate from contrail
        DEPLOYMENT_ENV['OPENSTACK_CONTROLLER_NODES']="$(get_openstack_node_names $openstack_node controller internalapi)"
    fi

    AGENT_NODES="$(get_openstack_node_names $openstack_node novacompute tenant)"
    if [ -z "$AGENT_NODES" ] ; then
        # Agents and Contrail Controllers are on same nodes (aio)
        AGENT_NODES="$CONTROLLER_NODES"
    fi
    DEPLOYMENT_ENV['DPDK_AGENT_NODES']=$(get_openstack_node_names $openstack_node contraildpdk tenant)
    local sriov_agent_nodes=$(get_openstack_node_names $openstack_node contrailsriov tenant)
    [ -z "${DEPLOYMENT_ENV['DPDK_AGENT_NODES']}" ] || AGENT_NODES+=" ${DEPLOYMENT_ENV['DPDK_AGENT_NODES']}"
    [ -z "$sriov_agent_nodes" ] || AGENT_NODES+=" $sriov_agent_nodes"

    if [[ -f ~/overcloudrc ]] ; then
        source ~/overcloudrc
        DEPLOYMENT_ENV['AUTH_URL']="${OS_AUTH_URL}"
        DEPLOYMENT_ENV['AUTH_PASSWORD']="${OS_PASSWORD}"
        DEPLOYMENT_ENV['AUTH_REGION']="${OS_REGION_NAME}"
    fi
    DEPLOYMENT_ENV['SSH_USER']="$SSH_USER_OVERCLOUD"
    if [[ -n "$ENABLE_TLS" ]] ; then
        DEPLOYMENT_ENV['SSL_ENABLE']='true'
        local cafile=$(openstack stack environment show -f json overcloud | jq -rc '.parameter_defaults.ContrailCaCertFile')
        if [ -z "$cafile" ] ; then
            if [[ "$ENABLE_TLS" == 'ipa' ]] ; then
                cafile='/etc/ipa/ca.crt'
            else
                cafile='/etc/contrail/ssl/certs/ca-cert.pem'
            fi
        fi
        DEPLOYMENT_ENV['SSL_KEY']="$(ssh $ssh_opts $SSH_USER_OVERCLOUD@$openstack_node sudo base64 -w 0 /etc/contrail/ssl/private/server-privkey.pem 2>/dev/null)"
        DEPLOYMENT_ENV['SSL_CERT']="$(ssh $ssh_opts $SSH_USER_OVERCLOUD@$openstack_node sudo base64 -w 0 /etc/contrail/ssl/certs/server.pem 2>/dev/null)"
        DEPLOYMENT_ENV['SSL_CACERT']="$(ssh $ssh_opts $SSH_USER_OVERCLOUD@$openstack_node sudo base64 -w 0 $cafile 2>/dev/null)"
    fi
    DEPLOYMENT_ENV['HUGE_PAGES_1G']=$vrouter_huge_pages_1g
    local node
    for node in $sriov_agent_nodes; do
        [ -z "${DEPLOYMENT_ENV['SRIOV_CONFIGURATION']}" ] || DEPLOYMENT_ENV['SRIOV_CONFIGURATION']+=';'
        DEPLOYMENT_ENV['SRIOV_CONFIGURATION']+="$node:$sriov_physical_network:$sriov_physical_interface:$sriov_vf_number";
    done
}

function collect_deployment_log() {
    set +e
    #Collecting undercloud logs
    local host_name=$(hostname -s)
    create_log_dir
    mkdir ${TF_LOG_DIR}/${host_name}
    collect_system_stats $host_name
    collect_openstack_logs $host_name
    pushd  ${TF_LOG_DIR}/${host_name}
    collect_docker_logs $CONTAINER_CLI_TOOL
    popd
    collect_stack_details ${TF_LOG_DIR}/${host_name}
    if [[ -e ~/undercloud.conf ]] ; then
        cp ~/undercloud.conf ${TF_LOG_DIR}/${host_name}/
    fi

    #Collecting overcloud logs
    local ip=''
    for ip in $(get_ctlplane_ips); do
        scp $ssh_opts $my_dir/../common/collect_logs.sh $SSH_USER_OVERCLOUD@$ip:
        cat <<EOF | ssh $ssh_opts $SSH_USER_OVERCLOUD@$ip
[[ "$DEBUG" == true ]] && set -x
set +e
export TF_LOG_DIR="/home/$SSH_USER_OVERCLOUD/logs"
cd /home/$SSH_USER_OVERCLOUD
./collect_logs.sh create_log_dir
./collect_logs.sh collect_docker_logs $CONTAINER_CLI_TOOL
./collect_logs.sh collect_system_stats
./collect_logs.sh collect_openstack_logs
./collect_logs.sh collect_tf_status
./collect_logs.sh collect_tf_logs
./collect_logs.sh collect_core_dumps

[[ ! -f /var/log/ipaclient-install.log ]] || {
    sudo cp /var/log/ipaclient-install.log \$TF_LOG_DIR
    sudo chown $SSH_USER_OVERCLOUD:$SSH_USER_OVERCLOUD \$TF_LOG_DIR/ipaclient-install.log
    sudo chmod 644 \$TF_LOG_DIR/ipaclient-install.log
}
EOF
        local source_name=$(ssh $ssh_opts $SSH_USER_OVERCLOUD@$ip hostname -s)
        mkdir ${TF_LOG_DIR}/${source_name}
        rsync -a --safe-links -e "ssh $ssh_opts" $SSH_USER_OVERCLOUD@$ip:logs/ ${TF_LOG_DIR}/${source_name}/
    done
    if [[ "$ENABLE_TLS" == 'ipa' ]] ; then
        scp $ssh_opts $my_dir/../common/collect_logs.sh $SSH_USER@$ipa_mgmt_ip:
        cat <<EOF | ssh $ssh_opts $SSH_USER@${ipa_mgmt_ip}
[[ "$DEBUG" == true ]] && set -x
set +e
export TF_LOG_DIR="/home/$SSH_USER/logs"
cd /home/$SSH_USER
./collect_logs.sh create_log_dir
./collect_logs.sh collect_system_stats
./collect_logs.sh collect_core_dumps
[[ ! -f /var/log/ipaclient-install.log ]] || {
    sudo cp /var/log/ipaclient-install.log \$TF_LOG_DIR
    sudo chown $SSH_USER:$SSH_USER \$TF_LOG_DIR/ipaclient-install.log
    sudo chmod 644 \$TF_LOG_DIR/ipaclient-install.log
}
[[ ! -f /var/log/ipaserver-install.log ]] || {
    sudo cp /var/log/ipaserver-install.log \$TF_LOG_DIR
    sudo chown $SSH_USER:$SSH_USER \$TF_LOG_DIR/ipaserver-install.log
    sudo chmod 644 \$TF_LOG_DIR/ipaserver-install.log
}
EOF
        mkdir ${TF_LOG_DIR}/ipa
        rsync -a --safe-links -e "ssh $ssh_opts" $SSH_USER@$ip:logs/ ${TF_LOG_DIR}/ipa/
    fi

    # Save to archive all yaml files and tripleo templates
    tar -czf ${TF_LOG_DIR}/tht.tgz -C ~ *.yaml tripleo-heat-templates
    tar -czf ${WORKSPACE}/logs.tgz -C ${TF_LOG_DIR}/.. logs
}

function add_vlan_interface() {
    local vlan_id=$1
    local phys_dev=$2
    local ip_addr=$3
    local net_mask=$4

    if sudo grep -q "VID: $vlan_id" /proc/net/vlan/*; then
        echo "INFO vlan $vlan_id is already exists. Skipping"
    else

cat <<EOF | sudo tee /etc/sysconfig/network-scripts/ifcfg-${vlan_id}
# This file is autogenerated by tf-devstack
ONBOOT=yes
BOOTPROTO=static
HOTPLUG=no
NM_CONTROLLED=no
PEERDNS=no
USERCTL=yes
VLAN=yes
DEVICE=$vlan_id
PHYSDEV=$phys_dev
IPADDR=$ip_addr
NETMASK=$net_mask
EOF
        echo "INFO: ifup for /etc/sysconfig/network-scripts/ifcfg-${vlan_id}"
        sudo cat /etc/sysconfig/network-scripts/ifcfg-${vlan_id}
        sudo ifdown ${vlan_id} || true
        sudo ifup ${vlan_id}
    fi
}

function wait_ssh() {
    local addr=$1
    local ssh_key=${2:-''}
    if [[ -n "$ssh_key" ]] ; then
        ssh_key=" -i $ssh_key"
    fi
    local interval=5
    local max=100
    local silent_cmd=1
    [[ "$DEBUG" != true ]] || silent_cmd=0
    if ! wait_cmd_success "ssh $ssh_opts $ssh_key ${SSH_USER}@${addr} uname -n" $interval $max $silent_cmd ; then
      echo "ERROR: Could not connect to VM $addr"
      exit 1
    fi
    echo "INFO: VM $addr is available"
}

function expand() {
    while read -r line; do
        if [[ "$line" =~ ^export ]]; then
            line="${line//\\/\\\\}"
            line="${line//\"/\\\"}"
            line="${line//\`/\\\`}"
            eval echo "\"$line\""
        else
            echo $line
        fi
    done
}

function prepare_rhosp_env_file() {
    local target_env_file=$1
    local env_file=$(mktemp)
    source $my_dir/../../config/common.sh
    cat $my_dir/../../config/common.sh | expand >> $env_file || true
    source $my_dir/../../config/${RHEL_MAJOR_VERSION}_env.sh
    cat $my_dir/../../config/${RHEL_MAJOR_VERSION}_env.sh | grep '^export' | expand | envsubst >> $env_file || true
    source $my_dir/../../config/${PROVIDER}_env.sh
    cat $my_dir/../../config/${PROVIDER}_env.sh | grep '^export' | expand | envsubst >> $env_file || true
    cat <<EOF >> $env_file

export DEBUG=$DEBUG
export PROVIDER=$PROVIDER
export ADMIN_PASSWORD="$ADMIN_PASSWORD"
export NTP_SERVERS="$NTP_SERVERS"
export ENVIRONMENT_OS=$ENVIRONMENT_OS
export OPENSTACK_VERSION="$OPENSTACK_VERSION"
export RHOSP_VERSION="$RHOSP_VERSION"
export RHOSP_MAJOR_VERSION="$RHOSP_MAJOR_VERSION"
export RHEL_VERSION="$RHEL_VERSION"
export RHEL_MAJOR_VERSION="$RHEL_MAJOR_VERSION"
export USE_PREDEPLOYED_NODES=$USE_PREDEPLOYED_NODES
export ENABLE_RHEL_REGISTRATION=$ENABLE_RHEL_REGISTRATION
export ENABLE_NETWORK_ISOLATION=$ENABLE_NETWORK_ISOLATION
export OPENSTACK_CONTAINER_REGISTRY="$OPENSTACK_CONTAINER_REGISTRY"
export OPENSTACK_CONTAINER_TAG="$OPENSTACK_CONTAINER_TAG"
export ENABLE_TLS=$ENABLE_TLS
export EXTERNAL_CONTROLLER_NODES="$EXTERNAL_CONTROLLER_NODES"
export EXTERNAL_CONTROLLER_SSH_USER="$EXTERNAL_CONTROLLER_SSH_USER"
export CONTROL_PLANE_ORCHESTRATOR=$CONTROL_PLANE_ORCHESTRATOR
export L3MH_CIDR="$L3MH_CIDR"
export VROUTER_GATEWAY="${VROUTER_GATEWAY}"
export SSL_CAKEY="$SSL_CAKEY"
export SSL_CACERT="$SSL_CACERT"
export RHOSP_EXTRA_HEAT_ENVIRONMENTS="$RHOSP_EXTRA_HEAT_ENVIRONMENTS"
EOF
    if [[ "$ENABLE_TLS" == 'local' ]] ; then
        if [ -z "$SSL_CAKEY" ] || [ -z "$SSL_CACERT" ] ; then
            echo "ERROR: For ENABLE_TLS=$ENABLE_TLS SSL_CAKEY and SSL_CACERT must be provided"
            exit -1
        fi
    fi
    #Removing duplicate lines
    awk '!a[$0]++' $env_file > $target_env_file
}

function add_node_to_ipa(){
    local name=$1
    local zone=$2
    local addr=$3
    local services="$4"
    local host="$5"
    ipa dnsrecord-find --name=${name} ${zone} || ipa dnsrecord-add --a-ip-address=$addr ${zone} ${name}
    ipa host-find ${name}.${zone} || ipa host-add ${name}.${zone}
    local s
    for s in $services ; do
        local principal="${s}/${name}.${zone}@${domain^^}"
        if ! ipa service-find $principal ; then
            ipa service-add $principal
            ipa service-add-host --hosts $host $principal
        fi
    done
}

function ensure_fqdn() {
    local domain=${1}
    if [ -z "$domain" ] ; then
        echo "ERROR: domain must be set"
        exit 1
    fi
    local cur_fqdn="$(hostname -f)"
    local exp_fqdn="$(hostname -s).${domain}"
    echo "INFO: cur_fqdn=$cur_fqdn exp_fqdn=$exp_fqdn"
    if [[ "$cur_fqdn" != "$exp_fqdn" ]] ; then
        echo "INFO: cur fqdn doesnt match to expected: $cur_fqdn != $exp_fqdn"
        sudo hostnamectl set-hostname $exp_fqdn
    fi
    echo "INFO: fqdn: $(hostname -f) host domain: $(hostname -d)"
}

function check_nodedata() {
    local agent_node_addr=$1
    local user=${2:-$SSH_USER}

    [ -z "$user" ] || agent_node_addr="$user@$agent_node_addr"
    local container='contrail_vrouter_agent'
    local inspect
    if ! inspect=$(ssh $SSH_OPTIONS $agent_node_addr "sudo $CONTAINER_CLI_TOOL inspect $container" 2>/dev/null)  ; then
        echo "No container $container on $agent_node_addr"
        return 1
    elif ! echo "$inspect" | grep 'test=test' &>/dev/null ; then
        echo "Node data didn't appear in $container container on $agent_node_addr"
        return 1
    fi
    echo "Node data was succesfully found in $container container on $agent_node_addr"
    return 0
}

function get_first_agent_node() {
    local agent_nodes="$(get_ctlplane_ips novacompute)"
    if [ -z "$agent_nodes" ] ; then
        # AIO
        agent_nodes="$(get_ctlplane_ips controller)"
    fi
    if [ -z "$agent_nodes" ] ; then
        echo "No agent nodes were found"
        return 1
    fi
    echo "$agent_nodes" | cut -d, -f1
}
