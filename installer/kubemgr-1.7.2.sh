#!/usr/bin/env bash

set -x
set -e
root=$(id -u)
if [ "$root" -ne 0 ] ;then
    echo must run as root
    exit 1
fi
kube::common::os()
{

    ubu=$(cat /etc/issue|grep "Ubuntu 16.04"|wc -l)
    cet=$(cat cat /etc/centos-release|grep "CentOS"|wc -l)
    if [ "$ubu" == "1" ];then
        export OS="ubuntu"
    elif [ "$cet" == "1" ];then
        export OS="CentOS"
    else
       echo "unkown os...   exit"
       exit 1
    fi

}

kube::common::with_cidr()
{
    gw=$(ip route |grep default|cut -d ' ' -f 3)
    # startwith

    if [[ $gw = "172."* ]];then
        export SVC_CIDR="192.168.255.0/20" CONTAINER_CIDR="192.168.0.0/20" CLUSTER_DNS="192.168.255.10"
    fi

    if [[ $gw = "10."* ]] ;then
        export SVC_CIDR="172.19.0.0/20" CONTAINER_CIDR="172.16.0.0/16" CLUSTER_DNS="172.19.0.10"
    fi

    if [[ $gw = "192.168"* ]];then
        export SVC_CIDR="172.19.0.0/20" CONTAINER_CIDR="172.16.0.0/16" CLUSTER_DNS="172.19.0.10"
    fi

    echo SVC_CIDR=$SVC_CIDR, CONTAINER_CIDR=$CONTAINER_CIDR, CLUSTER_DNS=$CLUSTER_DNS
}

kube::rpm::connect2version()
{
    curl --retry 5 -sSL $OSS_URL/rpm/1.7.2/1.7.2-rpm.txt > pkg.tmp
    source pkg.tmp
    export RPM_OSSFS="$OSS_URL/rpm/ossfs-1.80/ossfs-1.80.0.rpm"
    export RPM_DOCKER_SELINUX="$OSS_URL/rpm/docker-1.12.6/docker-engine-selinux-1.12.6-1.el7.centos.noarch.rpm"
    export RPM_DOCKER="$OSS_URL/rpm/docker-1.12.6/docker-engine-1.12.6-1.el7.centos.x86_64.rpm"
    export CLOUD_DISK="$OSS_URL/rpm/1.7.2/alicloud-disk-1.7.2-1.0.x86_64.rpm"
}

kube::common::connect2repository()
{
    export KUBE_REPO_PREFIX="$REGISTRY_URL/google-containers"
    curl --retry 5 -sSL $OSS_URL/hyperkube/1.7.2/image.meta > image.tmp.meta
    source image.tmp.meta
    export KUBE_DISCOVERY_IMAGE="$REGISTRY_URL/google-containers/kube-discovery-amd64:1.0"
	export KUBE_ETCD_IMAGE="$REGISTRY_URL/google-containers/etcd-amd64:3.0.17"
}
kube::debain::connect2version()
{
    curl --retry 5 -sSL $OSS_URL/debian/1.7.2/1.7.2-debian.txt > pkg.tmp
    source pkg.tmp
    export RPM_OSSFS="$OSS_URL/debian/ossfs-1.80/ossfs-1.80.0.deb"
    export DOCKER="$OSS_URL/debian/docker-1.12.6/docker-engine_1.12.6-0%7Eubuntu-xenial_amd64.deb"
}
kube::common::classic_route_hack()
{
    ip route del 172.16.0.0/12 dev eth0
}

kube::common::install_docker()
{
    set +e
    kube::common::classic_route_hack
    which docker > /dev/null 2>&1
    i=$?
    if [ $i -ne 0 ]; then
        if [ "$1" == "CentOS" ];then
            kube::rpm::connect2version
            curl --retry 5 -sSL $RPM_DOCKER > docker-engine.rpm
            curl --retry 5 -sSL $RPM_DOCKER_SELINUX > docker-engine-selinux.rpm
            yum localinstall -y docker-engine.rpm docker-engine-selinux.rpm
        else
            apt update ; apt install -y -f gdebi
            kube::debain::connect2version
            curl --retry 5 -sSL $DOCKER > docker-engine.deb
            gdebi -n docker-engine.deb
        fi
        #curl --retry 5 -sSL http://acs-public-mirror.oss-cn-hangzhou.aliyuncs.com/docker-engine/daemon-build/1.12.5/internet_16.04 | sh -
	    sed -i "s#ExecStart=/usr/bin/dockerd#ExecStart=/usr/bin/dockerd --registry-mirror=https://pqbap4ya.mirror.aliyuncs.com --log-driver=json-file --log-opt max-size=100m --log-opt max-file=10#g" \
	    /lib/systemd/system/docker.service
	    systemctl enable docker.service
	    systemctl restart docker.service
    fi
    set -e
    echo docker has been installed
}

kube::common::pause_pod()
{
    pause=$(docker images |grep gcr.io/google_containers/pause-amd64:3.0|wc -l)
    if [ $pause -lt 1 ];then
        docker pull $REGISTRY_URL/google-containers/pause-amd64:3.0
        docker tag $REGISTRY_URL/google-containers/pause-amd64:3.0 gcr.io/google_containers/pause-amd64:3.0
    fi
}

kube::rpm::install_binaries()
{
    kube::rpm::connect2version
    yum install -y socat fuse fuse-libs nfs-utils nfs-utils-lib
    rm -rf /tmp/kube && mkdir -p /tmp/kube
    curl --retry 5 -sS -L "$KUBEADM_PKG" > /tmp/kube/kubeadm.rpm
    curl --retry 5 -sS -L "$KUBECTL_PKG" > /tmp/kube/kubectl.rpm
    curl --retry 5 -sS -L "$KUBELET_PKG" > /tmp/kube/kubelet.rpm
    curl --retry 5 -sS -L "$KUBECNI_PKG" > /tmp/kube/kube-cni.rpm
    curl --retry 5 -sS -L "$RPM_OSSFS"  > /tmp/kube/ossfs-1.80.rpm
    curl --retry 5 -sS -L "$CLOUD_DISK" > /tmp/kube/alicloud-disk.rpm

    rpm -ivh /tmp/kube/alicloud-disk.rpm /tmp/kube/kubectl.rpm /tmp/kube/kubelet.rpm /tmp/kube/kube-cni.rpm /tmp/kube/kubeadm.rpm /tmp/kube/ossfs-1.80.rpm

    systemctl enable kubelet.service

    sed -i "s#KUBELET_DNS_ARGS=--cluster-dns=10.96.0.10 --cluster-domain=cluster.local#KUBELET_DNS_ARGS=--cluster-dns=$CLUSTER_DNS --cluster-domain=cluster.local --cloud-provider=external --hostname-override=$NODE_ID#g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

    systemctl daemon-reload && systemctl start kubelet.service
}

kube::debian::install_binaries()
{
    kube::debain::connect2version

    apt install -y -f socat nfs-common gdebi


    rm -rf /tmp/kube && mkdir -p /tmp/kube
    curl --retry 5 -sS -L $KUBEADM_PKG > /tmp/kube/kubeadm.deb
    curl --retry 5 -sS -L $KUBECTL_PKG > /tmp/kube/kubectl.deb
    curl --retry 5 -sS -L $KUBELET_PKG > /tmp/kube/kubelet.deb
    curl --retry 5 -sS -L $KUBECNI_PKG > /tmp/kube/kube-cni.deb
    curl --retry 5 -sS -L "$RPM_OSSFS" > /tmp/kube/ossfs-1.80.deb

    gdebi -n /tmp/kube/kube-cni.deb
    gdebi -n /tmp/kube/kubelet.deb
    gdebi -n /tmp/kube/kubectl.deb
    gdebi -n /tmp/kube/kubeadm.deb
    gdebi -n /tmp/kube/ossfs-1.80.deb

    SKIP_FLIGHT_CHECK=--skip-preflight-checks

    #dpkg -i /tmp/kube/kubeadm.deb /tmp/kube/kubectl.deb /tmp/kube/kubelet.deb /tmp/kube/kube-cni.deb

    sed -i "s#KUBELET_DNS_ARGS=--cluster-dns=10.96.0.10 --cluster-domain=cluster.local#KUBELET_DNS_ARGS=--cluster-dns=$CLUSTER_DNS --enable-controller-attach-detach=false --cluster-domain=cluster.local --cloud-provider=external --hostname-override=$NODE_ID#g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

    systemctl daemon-reload && systemctl start kubelet.service
}

kube::common::install_binaries()
{
     ubu=$(cat /etc/issue|grep "Ubuntu 16.04"|wc -l)
     cet=$(cat cat /etc/centos-release|grep "CentOS"|wc -l)
     if [ "$ubu" == "1" ];then
        kube::debian::install_binaries
     elif [ "$cet" == "1" ];then
        # CentOS
        kube::rpm::install_binaries

        # set net.bridge.bridge-nf-call-iptables = 1 to allow bridge data to be send to iptables for further process.
        cnt=$(grep "net.bridge.bridge-nf-call-iptables" /usr/lib/sysctl.d/00-system.conf |wc -l)
        if [ $cnt -gt 0 ];then
            sed -i '/net.bridge.bridge-nf-call-iptables/d' /usr/lib/sysctl.d/00-system.conf
        fi
        sed -i '$a net.bridge.bridge-nf-call-iptables = 1' /usr/lib/sysctl.d/00-system.conf
        echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables

     else
        echo "unkown os...   exit"
        exit 1
     fi
}

kube::common::nodeid()
{
    region=$(curl --retry 5  -sSL http://100.100.100.200/latest/meta-data/region-id)
    insid=$(curl --retry 5  -sSL http://100.100.100.200/latest/meta-data/instance-id)
    if [ "" == "$region" -o "" == "$insid" ];then
        echo "can not get regionid and instanceid! curl --retry 5  -sSL http://100.100.100.200/latest/meta-data/region-id" && exit 256
    fi
    export NODE_ID=$region.$insid
}

kube::master_up()
{
    kube::common::nodeid

    kube::common::connect2repository

    kube::common::os

    kube::common::install_docker $OS

    kube::common::pause_pod

    kube::common::with_cidr

    if [ "$EXTRA_SANS" == "" ];then
        EXTRA_SANS=1.1.1.1
        echo "Warining: alicloud NAT address was not provided, use garbage instead 1.1.1.1"
    fi
    kube::common::install_binaries
    if [ "" == "$token" ];then
        export token=$(kubeadm token generate)
    fi
    echo TOKEN: $token
    kube::common::write_cloud_config
    kube::common::write_kubeadm_config

    kubeadm init $SKIP_FLIGHT_CHECK --config=/etc/kubeadm/kubeadm.config

    export KUBECONFIG=/etc/kubernetes/admin.conf
    echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> /etc/profile

    # generate cloud-controller-manager config
    head -6 /etc/kubernetes/controller-manager.conf > /etc/kubernetes/cloud-controller-manager.conf
    sed -i "s#172.16.0.0/16#$CONTAINER_CIDR#g" /etc/kubernetes/cloud-controller-manager.conf
    cat <<EOF >> /etc/kubernetes/cloud-controller-manager.conf
kind: Config
contexts:
- context:
    cluster: kubernetes
    user: system:cloud-controller-manager
  name: system:cloud-controller-manager@kubernetes
current-context: system:cloud-controller-manager@kubernetes
users:
- name: system:cloud-controller-manager
  user:
    tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
EOF

    # generate kubectl config
    sed "/server: https:/d" /etc/kubernetes/admin.conf > /etc/kubernetes/kube.conf
    sed -i "/- cluster:/a \    server: https://$EXTRA_SANS:6443" /etc/kubernetes/kube.conf

#    curl -ssL $OSS_URL/conf/flannel-vpc-rbac.yml> /etc/kubernetes/manifests/flannel-vpc-rbac.yml
    curl --retry 5 -LsS $OSS_URL/conf/flannel-vpc-rbac.yml > vpc.yml
    sed -i "s#172.16.0.0/16#$CONTAINER_CIDR#g" vpc.yml
    kubectl apply -f vpc.yml

    # kubectl apply -f $OSS_URL/conf/kubernetes-dashboard-1.6.0.yaml
    kubectl apply -f https://raw.githubusercontent.com/huychau/spring-mongodb/master/manifests/kubernetes-dashboard-1.6.0.yml

    kubectl apply -f $OSS_URL/conf/ingress-controller-summary.yml
    kubectl apply -f $OSS_URL/conf/heapster.yml

    kubectl apply -f $OSS_URL/conf/cloud-controller-manager.yml

    kubectl taint nodes --all node-role.kubernetes.io/master-
    #show pods
    kubectl --namespace=kube-system get po
    echo kubectl --namespace=kube-system get po

    # Install spring, mongodb
    kubectl apply -f https://raw.githubusercontent.com/huychau/spring-mongodb/master/manifests/mongo-pv.yml
    kubectl apply -f https://raw.githubusercontent.com/huychau/spring-mongodb/master/manifests/mongo-pvc.yml

    kubectl apply -f https://raw.githubusercontent.com/huychau/spring-mongodb/master/manifests/mongo-controller.yml

    kubectl apply -f https://raw.githubusercontent.com/huychau/spring-mongodb/master/manifests/api-deploy.yml
    kubectl apply -f https://raw.githubusercontent.com/huychau/spring-mongodb/master/manifests/api-service.yml

    kubectl apply -f https://raw.githubusercontent.com/huychau/spring-mongodb/master/manifests/ingress.yml


    # kubectl run nginx --image=$REGISTRY_URL/spacexnice/nginx:latest --replicas=2 --labels run=nginx
    # kubectl expose deployment nginx --port=80 --target-port=80 --type=LoadBalancer
}

kube::node_up()
{
    kube::common::nodeid

    kube::common::connect2repository

    kube::common::os

    kube::common::with_cidr

    kube::common::install_docker $OS

    kube::common::pause_pod

    kube::common::install_binaries

    kube::common::write_kubeadm_config
    kube::common::write_cloud_config
    if [ "" == "$ENDPOINT" ];then
        echo "--endpoint must be provided. "
        exit 1
    fi
    if [ "" == "$token" ];then
        echo "--token must be provided. "
        exit 1
    fi

    kubeadm join $SKIP_FLIGHT_CHECK --token $token $ENDPOINT --node-name $NODE_ID
}

kube::common::write_cloud_config()
{
    mkdir -p /etc/kubernetes/
    cat >/etc/kubernetes/cloud-config <<EOF
{
    "global": {
     "accessKeyID": "$KEY_ID",
     "accessKeySecret": "$KEY_SECRET",
     "kubernetesClusterTag": "kube"
   }
}
EOF

}

kube::common::write_kubeadm_config()
{
    mkdir -p /etc/kubeadm/
cat >/etc/kubeadm/kubeadm.config <<EOF
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
cloudProvider: external
selfHosted: false
networking:
  dnsDomain: cluster.local
  serviceSubnet: $SVC_CIDR
  podSubnet: $CONTAINER_CIDR
apiServerCertSANs:
  - $EXTRA_SANS
token: $token
nodeName: $NODE_ID
kubernetesVersion: v1.7.2
EOF
}
kube::tear_down()
{
    set +e
    kubeadm reset >/dev/null 2>&1
    ubu=$(cat /etc/issue|grep "Ubuntu 16.04"|wc -l)
    cet=$(cat cat /etc/centos-release|grep "CentOS"|wc -l)
    if [ "$ubu" == "1" ];then
        dpkg --purge kubectl kubeadm kubelet kubernetes-cni
        apt-get purge -y ossfs
        rm -rf /etc/kubernetes /var/lib/kubelet
    elif [ "$cet" == "1" ];then
        # CentOS
        yum remove -y kubectl kubeadm kubelet kubernetes-cni ossfs
    else
       echo "unkown os...   exit"
       exit 1
    fi
    rm -rf /var/lib/cni /etc/cni/ /run/flannel/subnet.env
    ip link del cni0
    set -e
}

export REGION=cn-hangzhou
export DISCOVERY=token://
main()
{

    while [[ $# -gt 1 ]]
    do
    key="$1"

    case $key in
        -k|--key-id)
            export KEY_ID=$2
            shift
        ;;
        -s|--key-secret)
            export KEY_SECRET=$2
            shift
        ;;
        -d|--discovery)
            export DISCOVERY=$2
            shift
        ;;
        -t|--node-type)
            export NODE_TYPE=$2
            shift
        ;;
        -r|--region)
            export REGION=$2
            shift
        ;;
	    -e|--endpoint)
	        export ENDPOINT=$2
            shift
	    ;;
	    --token)
            export token=$2
	        shift
	    ;;
	    --extra-sans)
            export EXTRA_SANS=$2
	        shift
	    ;;
	    --oss-region)
            export REGION=$2
	        shift
	    ;;
        *)
                # unknown option
            echo "unkonw option [$key]"
        ;;
    esac
    shift
    done

    if [ "" == "$KEY_ID" -o "" == "$KEY_SECRET" ];then
        if [ "$NODE_TYPE" != "down" ];then
            echo "--key-id and --key-secret must be provided!"
            exit 1
        fi
    fi
    if [ "$REGION" == "cn-hongkong" ];then
        export OSS_URL=http://aliacs-k8s-hk.oss-cn-hongkong.aliyuncs.com
        export REGISTRY_URL=registry.ap-southeast-1.aliyuncs.com
    else
        export REGION="cn-hangzhou"
        export OSS_URL=http://aliacs-k8s.oss-cn-hangzhou.aliyuncs.com
        export REGISTRY_URL=registry.cn-hangzhou.aliyuncs.com
    fi
    case $NODE_TYPE in
    "m" | "master" )
        kube::master_up
        ;;
    "n" | "node" )
        kube::node_up
        ;;
    "d" | "down" )
        kube::tear_down
        ;;
    *)
        echo "usage: $0 --node-type master --key-id xxxx --key-secret xxxx "
        echo "       $0 --node-type node --key-id xxxx --key-secret xxxx --token xxxx --endpoint 10.24.2.45:6443"
        echo "       $0 down   to tear down node or master"
        echo "       $0 master to setup master "
        echo "       $0 join   to join master with token "
        echo "       $0 down   to tear all down ,inlude all data! so becarefull"
        echo "       unkown command $0 $@"
        ;;
    esac
}
main $@
