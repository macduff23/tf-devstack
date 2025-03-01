#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

cd
source stackrc
source rhosp-environment.sh

source $my_dir/../../common/common.sh
source $my_dir/../../common/functions.sh
source $my_dir/../providers/common/functions.sh

if [[ "$ENABLE_TLS" == 'ipa' ]] ; then
   export overcloud_nameservers="[ \"$ipa_prov_ip\" ]"
else
   export overcloud_nameservers="[ \"8.8.8.8\", \"8.8.4.4\" ]"
fi

export undercloud_registry=${prov_ip}:8787
export undercloud_registry_contrail=$undercloud_registry
ns=$(echo ${CONTAINER_REGISTRY:-'docker.io/tungstenfabric'} | cut -s -d '/' -f2-)
[ -n "$ns" ] && undercloud_registry_contrail+="/$ns"


export vrouter_gateway_parameter=""
if [ -n "$VROUTER_GATEWAY" ] ; then
   vrouter_gateway_parameter="VROUTER_GATEWAY: ${VROUTER_GATEWAY}"
fi
if [[ "$USE_PREDEPLOYED_NODES" == true && -z "$vrouter_gateway_parameter" ]]; then
   #Explicitly set to prevent the use of a network interface gateway
  vrouter_gateway_parameter="VROUTER_GATEWAY: ${prov_ip}"
fi

if [[ "$ENABLE_RHEL_REGISTRATION" == false ]]; then
   export RHEL_REG_METHOD="disable"
else
   export RHEL_REG_METHOD="portal"
   #Getting orgID
   export RHEL_ORG_ID=$(sudo subscription-manager identity | grep "org ID" | sed -e 's/^.*: //')
fi

export SSH_PRIVATE_KEY=`while read l ; do echo "      $l" ; done < .ssh/id_rsa`
export SSH_PUBLIC_KEY=`while read l ; do echo "      $l" ; done < .ssh/id_rsa.pub`

cd
rm -rf tripleo-heat-templates contrail-tripleo-heat-templates
cp -r /usr/share/openstack-tripleo-heat-templates/ tripleo-heat-templates
if ! fetch_deployer_no_docker "tf-tripleo-heat-templates-src" contrail-tripleo-heat-templates ; then
   echo "WARNING: failed to fetch tf-tripleo-heat-templates-src, use github"
   git clone https://github.com/tungstenfabric/tf-tripleo-heat-templates contrail-tripleo-heat-templates
fi

if [[ ! -d contrail-tripleo-heat-templates ]] ; then
   echo "ERROR: The directory with src contrail-tripleo-heat-templates is not found. Exit with error"
   exit 1
fi
pushd contrail-tripleo-heat-templates
rhosp_branch="stable/${OPENSTACK_VERSION}"
git checkout ${rhosp_branch}
if [[ $? != 0 ]] ; then
   echo "ERROR: Checkout to ${rhosp_branch} is finished with error"
   exit 1
fi
popd

cp -r contrail-tripleo-heat-templates/* tripleo-heat-templates

# detect dmi_uuids for NodeDataLookup
dmi_uuids=""
if [[ $PROVIDER == 'openstack' ]] ; then
   get_dmi_uuid="sudo dmidecode --s system-uuid | awk 'match(\$0, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/) { print substr(\$0, RSTART, RLENGTH) }'"
   for ip in ${overcloud_cont_prov_ip//,/ } ${overcloud_compute_prov_ip//,/ } ${overcloud_ctrlcont_prov_ip//,/ } ; do
      dmi_uuids+=$(ssh $ssh_opts $SSH_USER_OVERCLOUD@$ip $get_dmi_uuid)
      dmi_uuids+=" "
   done
else
   node_ids=$(openstack baremetal node list -f value -c UUID)
   for node_id in $node_ids ; do
      dmi_uuids+=$(openstack baremetal introspection data save $node_id | jq .extra.system.product.uuid | tr '[:upper:]' '[:lower:]' | sed 's/"//g')
      dmi_uuids+=" "
   done
fi
export dmi_uuids

#Creating rhosp specific contrail-parameters.yaml
$my_dir/../../common/jinja2_render.py < $my_dir/${RHOSP_MAJOR_VERSION}_misc_opts.yaml.j2 >misc_opts.yaml
if [[ -n "$EXTERNAL_CONTROLLER_NODES" ]] ; then
   cat <<EOF >>misc_opts.yaml
  ExternalContrailConfigIPs: ${EXTERNAL_CONTROLLER_NODES// /,}
  ExternalContrailControlIPs: ${EXTERNAL_CONTROLLER_NODES// /,}
  ExternalContrailAnalyticsIPs: ${EXTERNAL_CONTROLLER_NODES// /,}

  ExtraHostFileEntries:
EOF

   for node in ${EXTERNAL_CONTROLLER_NODES//,/ } ; do
      fqdn=$(ssh $node hostname -f)
      short=$(ssh $node hostname -s)
      cat <<EOF >>misc_opts.yaml
       - "$node    $fqdn    $short"
EOF
   done
fi

if [[ "$CONTROL_PLANE_ORCHESTRATOR" == 'operator' ]] ; then
  # For  operator case it is needed to force enable api ssl for neutron plugin
  # as operator is always with ssl
   cat <<EOF >>misc_opts.yaml
  ControllerExtraConfig:
    contrail_internal_api_ssl: True
  ComputeExtraConfig:
    contrail_internal_api_ssl: True
  ContrailDpdkExtraConfig:
    contrail_internal_api_ssl: True
  ContrailSriovExtraConfig:
    contrail_internal_api_ssl: True
  ContrailAioExtraConfig:
    contrail_internal_api_ssl: True
EOF
   if [[ "$ENABLE_TLS" == 'ipa' && -n "$SSL_CACERT" ]] ; then
      # For operator with selfCA and RHOSP w/ IPA use selfsigned ca file
      # distributed through inject-ca.yaml
      echo "  ContrailCaCertFile: '/etc/pki/tls/certs/ca-bundle.crt'" >>misc_opts.yaml
   fi
fi

if [[ "$ENABLE_TLS" == 'local' ]] ; then
   if [[ -z "$SSL_CACERT" || -z "$SSL_CAKEY" ]] ; then
      echo "ERROR: for ENABLE_TLS=$ENABLE_TLS SSL_CACERT and SSL_CAKEY must be provided"
      exit 1
   fi
   $my_dir/../../common/jinja2_render.py < $my_dir/contrail-tls-local.yaml.j2 >contrail-tls-local.yaml
fi
if [ -n "$SSL_CACERT" ] ; then
   $my_dir/../../common/jinja2_render.py < $my_dir/inject-ca.yaml.j2 >inject-ca.yaml
fi

echo "INFO: source file $my_dir/${RHOSP_MAJOR_VERSION}_prepare_heat_templates.sh"
source $my_dir/${RHOSP_MAJOR_VERSION}_prepare_heat_templates.sh
echo "INFO: using template $my_dir/${RHOSP_MAJOR_VERSION}_contrail-parameters.yaml.template"
cat $my_dir/${RHOSP_MAJOR_VERSION}_contrail-parameters.yaml.template | envsubst > contrail-parameters.yaml

#Changing tripleo-heat-templates/roles_data_contrail_aio.yaml
if [[ ( -z "$overcloud_ctrlcont_instance" || "$CONTROL_PLANE_ORCHESTRATOR" == 'operator' ) && -z "$overcloud_compute_instance" ]] ; then
   role_file=tripleo-heat-templates/roles/ContrailAio.yaml
   sed -i -re 's/Count:\s*[[:digit:]]+/Count: 0/' tripleo-heat-templates/environments/contrail/contrail-services.yaml
   sed -i -re 's/ContrailAioCount: 0/ContrailAioCount: 1/' tripleo-heat-templates/environments/contrail/contrail-services.yaml
else
   role_file=tripleo-heat-templates/roles_data_contrail_aio.yaml
fi
if [[ "$USE_PREDEPLOYED_NODES" == true ]]; then
   $my_dir/../../common/jinja2_render.py < $my_dir/ctlplane-assignments.yaml.j2 >ctlplane-assignments.yaml
   $my_dir/../../common/jinja2_render.py < $my_dir/hostname-map.yaml.j2 >hostname-map.yaml
   sed -i -re 's/disable_constraints: False/disable_constraints: True/' $role_file
fi

#Auto-detect physnet MTU for cloud environments
default_iface=`/sbin/ip route get 1 | grep -o "dev.*" | awk '{print $2}'`
default_iface_mtu=`/sbin/ip link show $default_iface | grep -o "mtu.*" | awk '{print $2}'`

if (( ${default_iface_mtu} < 1500 )); then
  echo -e "\n  NeutronGlobalPhysnetMtu: ${default_iface_mtu}" >> contrail-parameters.yaml
fi
