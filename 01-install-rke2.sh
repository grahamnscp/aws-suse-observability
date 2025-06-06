#!/bin/bash

source ./params.sh
source ./utils/utils.sh
source ./utils/load-tf-output.sh

# -------------------------------------------------------------------------------------
# Functions:

#
function rke2installmaster1
{
  Log "function rke2installmaster1: started.."

  # first instance
  NODENAME=${NODE_NAME[1]}
  NODEIP=${NODE_PUBLIC_IP[1]}
  PRIVATEIP=${NODE_PRIVATE_IP[1]}
  NODEN=$(echo $NODENAME | cut -d. -f1)

  Log "\__Creating cluster config.yaml.."
  cat << EOF >./local/rke2-config.yaml
token: $RKE2_TOKEN
tls-san:
- $NODENAME
- $NODEIP
- rke.$DOMAINNAME
EOF
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo mkdir -p /etc/rancher/rke2"
  scp $SSH_OPTS ./local/rke2-config.yaml ${SSH_USERNAME}@${NODEIP}:~/config.yaml
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo cp config.yaml /etc/rancher/rke2/"

  Log "\__Installing RKE2 ($NODENAME).."
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo bash -c 'curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION_AI} sh - 2>&1 > /root/rke2-install.log 2>&1'"
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo systemctl enable rke2-server.service"
  Log "\__Starting rke2-server.service.."
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo systemctl start rke2-server.service"


  Log "\__Waiting for kubeconfig file to be created.."
  WAIT=30
  UP=false
  while ! $UP
  do
    ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo test -e /etc/rancher/rke2/rke2.yaml && exit 10 </dev/null"
    if [ $? -eq 10 ]; then
      Log " \__Cluster is now configured."
      UP=true
    else
      sleep $WAIT
    fi
  done

  Log "\__Downloading kube admin.conf locally.."
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo cp /etc/rancher/rke2/rke2.yaml ~/admin.conf"
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo chown ${SSH_USERNAME}:users ~/admin.conf"
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo chmod 600 ~/admin.conf"
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "echo export KUBECONFIG=~/admin.conf >> ~/.bashrc"

  # Local admin.conf
  mkdir -p ./local
  if [ -f ./local/admin.conf ] ; then rm ./local/admin.conf ; fi
  scp $SSH_OPTS ${SSH_USERNAME}@${NODEIP}:~/admin.conf ./local/admin.conf
  sed -i '' "s/127.0.0.1/rke.$DOMAINNAME/g" ./local/admin.conf
  chmod 600 ./local/admin.conf
  
  Log "\__adding kubectl link to bin.."
  KDIR=`ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "ls /var/lib/rancher/rke2/data/"`
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "cd /usr/local/bin ; sudo ln -s /var/lib/rancher/rke2/data/$KDIR/bin/kubectl kubectl"
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo bash -c 'echo export KUBECONFIG=/etc/rancher/rke2/rke2.yaml >> /root/.bashrc'"
  ssh $SSH_OPTS ${SSH_USERNAME}@${NODEIP} "sudo bash -c 'echo alias k=kubectl >> /root/.bashrc'"

  LogElapsedDuration
}


#
function rke2nodewait
{
  NODENUM=$1
  PUBLIC_IP=$2

  Log "function rke2nodewait: for node $NODENUM"

  # wait until cluster nodes ready
  Log "\__Waiting for RKE2 cluster node $NODENUM ($PUBLIC_IP) to be Ready.."
  READY=false
  while ! $READY
  do
    NRC=`kubectl --kubeconfig=./local/admin.conf get nodes 2>&1 | egrep 'NotReady|connection refused|no such host' | wc -l`
    if [ $NRC -eq 0 ]; then
      echo -n 0
      echo
      Log " \__RKE2 cluster nodes are Ready:"
      kubectl --kubeconfig=./local/admin.conf get nodes
      READY=true
    else
      echo -n ${NRC}.
      sleep 10
    fi
  done

  # wait until cluster fully up
  Log "\__Waiting for RKE2 cluster to be fully initialised.."
  sleep 30
  READY=false
  while ! $READY
  do
    NRC=`kubectl --kubeconfig=./local/admin.conf get pods --all-namespaces 2>&1 | egrep -v 'Running|Completed|NAMESPACE' | wc -l`
    if [ $NRC -eq 0 ]; then
      echo -n 0
      echo
      Log "\__RKE2 cluster node is now initialised."
      READY=true
    else
      echo -n ${NRC}.
      sleep 10
    fi
  done
}

# -------------------------------------------------------------------------------------

# Main
#

NODEN=$(echo ${NODE_NAME[1]} | cut -d. -f1)
LogStarted "Installing RKE2 node $NODEN (HOST: ${NODE_NAME[1]} IP: ${NODE_PUBLIC_IP[1]} ${NODE_PRIVATE_IP[1]}).."
rke2installmaster1

# wait until cluster nodes ready
rke2nodewait 1 ${NODE_PUBLIC_IP[1]}
LogElapsedDuration


LogCompleted "Done."
# -------------------------------------------------------------------------------------

# tidy up
exit 0
