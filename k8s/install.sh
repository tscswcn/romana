#!/bin/bash

declare -A ROMANA_GATES
declare -A ROMANA_ROUTES

is_master () {
	[[ $INSTANCE_ID == $MASTER_ID ]] && return 0 || return 1
	
}

enable_crosscluster_login () {
   ssh-keygen -y -f $U_HOME/.ssh/id_rsa >> $U_HOME/.ssh/authorized_keys
}

get_romana_binaries () {
	for bin in root ipam agent tenant topology tenant; do 
		aws s3 cp s3://pani-infrastructure/binaries/latest/origin/$CORE_BRANCH/$bin /bin/$bin
		chmod +x /bin/$bin
	done
}

configure_romana () {
	echo "In configure_romana"

	if is_master; then
		test -f /home/ubuntu/romana.conf || cp /home/ubuntu/romana/k8s/romana.conf.example /home/ubuntu/romana.conf
		sed -i "s/__MASTER_IP__/$MASTER_IP/g" /home/ubuntu/romana.conf
		if ! test -f /tmp/romana_mysql.done; then
			mysql -u root -psecrete  < /home/ubuntu/romana/k8s/romana.sqldump
			touch /tmp/romana_mysql.done
		fi
		cp /home/ubuntu/romana/k8s/romana.rc /root/romana.rc
	else
		cp /home/ubuntu/romana/k8s/romana.agent.rc /root/romana.rc
	fi

	sysctl net.ipv4.conf.all.proxy_arp=1
	sysctl net.ipv4.conf.default.proxy_arp=1

	sed -i "s/__MASTER_IP__/$MASTER_IP/g" /root/romana.rc
}

configure_cni_plugin () {
	cp -r /home/ubuntu/romana/k8s/etc/cni /etc/
	mkdir -p /opt/cni/bin/
	cp -f /home/ubuntu/romana/k8s/romana.cni /opt/cni/bin/romana
	chmod +x /opt/cni/bin/romana
	sed -i "s/__MASTER_IP__/$MASTER_IP/g" /opt/cni/bin/romana
	GATE_IP=${ROMANA_GATES[$INSTANCE_ID]}
	sed -i "s+__GATE_SRC__+${GATE_IP%%/*}+g" /opt/cni/bin/romana
}

start_mysql () {
	is_master || return 0	

	mysqladmin password secrete 2>&1 > /dev/null
	service mysql restart
} 
	
create_topology_record () {
	IP=$1
	NAME=$2
	ROMANA_NET=$3
	AGENT_PORT=$4

        REQ='{"Ip" : "__IP__", "name": "__NAME__", "romana_ip" : "__ROMANA_IP__", "agent_port" : __PORT__ }'
        REQ=$(echo $REQ | sed "s/__IP__/$IP"/)
        REQ=$(echo $REQ | sed "s/__NAME__/$NAME/")
        REQ=$(echo $REQ | sed "s+__ROMANA_IP__+$ROMANA_NET+")
        REQ=$(echo $REQ | sed "s/__PORT__/$AGENT_PORT/")
        echo curl -v -H "Accept: application/json" -H "Content-Type: application/json" http://$MASTER_IP:9603/hosts -XPOST -d "$REQ"
        curl -v -H "Accept: application/json" -H "Content-Type: application/json" http://$MASTER_IP:9603/hosts -XPOST -d "$REQ"
}

configure_topology () {
	ROMANA_IDX=0
	for id in  $MASTER_ID $ASG_INSTANCES; do
		ROMANA_ROUTE="10.${ROMANA_IDX}.0.0/16"
		ROMANA_ROUTES[$id]="$ROMANA_ROUTE"
		ROMANA_GATE="10.${ROMANA_IDX}.0.1/16"
		ROMANA_GATES[$id]="$ROMANA_GATE"
		[[ "$id" == "$MASTER_ID" ]] && ip=$MASTER_IP || ip="${ASG_IPS[$id]}"

		# on slaves we only want to fill in arrays above
		# but on master actually want to create topology records
		if is_master; then
			create_topology_record "$ip" "$id" "$ROMANA_GATE" "9604"
		fi
		ROMANA_IDX=$(( ROMANA_IDX +1 ))
	done
}

configure_gate_and_routes () {
	echo "In configure_gate_and_routes"
	for id in $MASTER_ID $ASG_INSTANCES; do 
		if [[ "$id" == "$INSTANCE_ID" ]]; then
			echo "Creating gate for $id -> ${ROMANA_GATES[$id]}"
			create_romana_gateway "${ROMANA_GATES[$id]}"
		else
			[[ "$id" == "$MASTER_ID" ]] && ip=$MASTER_IP || ip="${ASG_IPS[$id]}"		
			echo "Creating route for $id ${ROMANA_ROUTES[$id]} -> ip"
			create_route "${ROMANA_ROUTES[$id]}" "$ip"
		fi
	done
}


register_node () {
	is_master && return 0 # master registered by default somehow

	sed -i "s/__NODE__/$INSTANCE_ID/g" /home/ubuntu/romana/k8s/etc/kubernetes/node.json
	until nc -z ${MASTER_IP} 8080; do
		echo "In register_node, waiting for master to show up"
		sleep 10
	done;
	kubectl -s "${MASTER_IP}:8080" create -f /home/ubuntu/romana/k8s/etc/kubernetes/node.json
}
	
create_romana_gateway () {
	if ! ip link | grep -q romana-gw; then
		ip link add romana-gw type dummy
	fi
	
	ifconfig romana-gw inet "$1" up
}

create_route () {
	ip ro add $1 via $2
}

get_kubernetes () {
	test -f /root/kubernetes.tar.gz || wget https://github.com/kubernetes/kubernetes/releases/download/v1.2.0-alpha.6/kubernetes.tar.gz -O /root/kubernetes.tar.gz
	test -d /root/kubernetes || tar -zxvf /root/kubernetes.tar.gz -C /root
	cd /root/kubernetes/cluster/ubuntu && ./download-release.sh
	ln -s /root/kubernetes/cluster/ubuntu/binaries/kubectl /bin/
	for i in etcd  etcdctl flanneld  kube-apiserver  kube-controller-manager  kube-scheduler; do 
		ln -s /root/kubernetes/cluster/ubuntu/binaries/master/$i /bin
	done
	for i in kubelet  kube-proxy; do 
		ln -s /root/kubernetes/cluster/ubuntu/binaries/minion/$i /bin
	done
	ln -s /root/kubernetes /home/ubuntu || :
}
	
configure_k8s_screen () {
	if is_master; then
		cp /home/ubuntu/romana/k8s/etc/kubernetes/k8s.rc /root/k8s.rc
	else
		cp /home/ubuntu/romana/k8s/etc/kubernetes/k8s.node.rc /root/k8s.rc
	fi

	sed -i "s/__MASTER_IP__/$MASTER_IP/g" /root/k8s.rc
	sed -i "s/__MASTER_ID__/$INSTANCE_ID/g" /root/k8s.rc

}
	
start_k8s_screen () {
	if ! screen -ls | grep -q k8s; then
		screen -AmdS k8s -c /root/k8s.rc
	fi
}

start_romana_screen () {
	if ! screen -ls | grep -q romana; then
		screen -AmdS romana -c /root/romana.rc
	fi
}

#main 
	enable_crosscluster_login
	get_kubernetes
	get_romana_binaries
	start_mysql
	configure_romana
	start_romana_screen
	configure_topology
	configure_cni_plugin
	configure_k8s_screen
	start_k8s_screen
	configure_gate_and_routes
	register_node
