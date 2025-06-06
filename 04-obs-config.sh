#!/bin/bash

source ./params.sh
source ./utils/utils.sh

# -------------------------------------------------------------------------------------

echo
LogStarted "Configuring SUSE Observability.."

# ----------------------------------------
Log "\_Configure sts cli.."
TOKEN_READY=false
while ! $TOKEN_READY
do
  ./utils/so-token-fetcher --url https://$OBS_HOSTNAME --username admin --password $OBS_ADMIN_PWD -auth-type default -o ./local/sts-token.txt
  if [ ! -f ./local/sts-token.txt ]; then
    R402=`./utils/so-token-fetcher --url https://$OBS_HOSTNAME --username admin --password $OBS_ADMIN_PWD -auth-type default -o ./local/sts-token.txt 2>&1 | wc -l |  sed 's/^ *//g'`
    echo "R402: '$R402'"
    if [ "$R402" == "1" ]; then
      LogError "so-token-fetcher received return code 402 - Observability License Key has probably expired!"
    fi
    sleep 30
  else
    TOKEN_READY=true
    STS_TOKEN=`cat ./local/sts-token.txt`
  fi
done
echo sts-token: $STS_TOKEN

mkdir -p ~/.config/stackstate-cli
cat << EOF >~/.config/stackstate-cli/config.yaml
contexts:
    - name: default
      context:
        url: https://$OBS_HOSTNAME
        api-token: $STS_TOKEN
        api-path: /api
        admin-api-path: ""
        skip-ssl: true
current-context: default
EOF

# ----------------------------------------
# deploy ingress for opentelemetry
Log "\_Creating otlp ingress.."

cat << INGEOF >./local/otlp-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: otlp-grpc-ingress
  namespace: suse-observability
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "GRPC"
    cert-manager.io/cluster-issuer: selfsigned-issuer
spec:
  rules:
  - host: otlp-grpc-$OBS_HOSTNAME
    http:
      paths:
      - backend:
          service:
            name: suse-observability-otel-collector
            port:
              number: 4317
        path: /
        pathType: Prefix
  tls:
    - hosts:
      - otlp-grpc-$OBS_HOSTNAME
      secretName: otlp-tls-secret
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: otlp-http-ingress
  namespace: suse-observability
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  rules:
  - host: otlp-http-$OBS_HOSTNAME
    http:
      paths:
      - backend:
          service:
            name: suse-observability-otel-collector
            port:
              number: 4318
        path: /
        pathType: Prefix
---
INGEOF

kubectl --kubeconfig=./local/admin.conf apply -f ./local/otlp-ingress.yaml

echo 
echo "${BWhi}**************************************"
echo "SUSE Observability OTLP Listening at:"
echo "  https://otlp-grpc-$OBS_HOSTNAME"
echo "  http://otlp-http-$OBS_HOSTNAME"
echo "**************************************${RCol}"
echo 

# ----------------------------------------
OBS_CLUSTER_NAME=obs

Log "\__Provisioning kubernetes-v2 stackpack.."
curl -sk https://$OBS_HOSTNAME/api/stackpack/kubernetes-v2/provision \
     -X POST \
     -H "Content-Type: application/json" \
     -H "Authorization: ApiToken $STS_TOKEN" \
     -d "{\"kubernetes_cluster_name\": \"$OBS_CLUSTER_NAME\"}"
echo

Log "\__Provisioning open-telemetry stackpack.."
curl -sk https://$OBS_HOSTNAME/api/stackpack/open-telemetry/provision \
     -X POST \
     -H "Content-Type: application/json" \
     -H "Authorization: ApiToken $STS_TOKEN" \
     -d '{}' 
echo 

Log "\__Provisioning Autonomous Anomaly Detector stackpack.."
curl -sk https://$OBS_HOSTNAME/api/stackpack/aad-v2/provision \
     -X POST \
     -H "Content-Type: application/json" \
     -H "Authorization: ApiToken $STS_TOKEN" \
     -d '{}'
echo

# -------------------------------------------------------------------------------------
# Add local receiver agent on observability cluster

# pause for stackpacks to deploy fully
sleep 120

# Check obs server pod is running first
Log "\_Waiting for SUSE Observability server to be up.."
READY=false
while ! $READY
do
  OBS_SERVER_UP=`kubectl get deployment/obs-suse-observability-server -n suse-observability --kubeconfig=./local/admin.conf | grep 1/1 | wc -l`
  if [ $OBS_SERVER_UP -eq 1 ]; then
    echo -n 1
    echo
    READY=true
  else
    echo -n .
    sleep 10
  fi
done

# ----------------------------------------
Log "\_Installing suse-observability agent.."
OBS_API_KEY=`cat ./local/obs-apikey.txt`

# install observability-agent - details via obs UI adding cluster with name $OBS_CLUSTER_NAME
helm --kubeconfig=./local/admin.conf upgrade --install suse-observability-agent suse-observability/suse-observability-agent \
     --namespace suse-observability --create-namespace \
     --set-string 'stackstate.apiKey'="$OBS_API_KEY" \
     --set-string 'stackstate.cluster.name'="$OBS_CLUSTER_NAME" \
     --set-string 'stackstate.url'="https://$OBS_HOSTNAME/receiver/stsAgent" \
     --set 'nodeAgent.skipKubeletTLSVerify'=true \
     --set-string 'global.skipSslValidation'=true

Log "\__Waiting for suse-observability agent to be Ready.."
kubectl --kubeconfig=./local/admin.conf wait pods -n suse-observability -l app.kubernetes.io/instance=suse-observability-agent --for condition=Ready --timeout=300s


# -------------------------------------------------------------------------------------
# Install the SUSE AI Observability Extension from the SUSE Application Collection

Log "\_Install SUSE Observability extension for SUSE AI.."

Log "\__Creating so-extensions namespace.."
kubectl --kubeconfig=./local/admin.conf create namespace so-extensions

Log "\__Authenticating local helm cli to SUSE Application Collection registry.."
helm registry login dp.apps.rancher.io/charts -u $APPCOL_USER -p $APPCOL_TOKEN

Log "\__Creating a docker-registry secret for SUSE Application Collection.."
kubectl --kubeconfig=./local/admin.conf create secret docker-registry application-collection --docker-server=dp.apps.rancher.io --docker-username=$APPCOL_USER --docker-password=$APPCOL_TOKEN -n so-extensions 


AI_CLUSTER_NAME=ai
Log "\__Creating ai-obs extension helm chart values (Observed cluster is $AI_CLUSTER_NAME).."
#SUSE_OBSERVABILITY_API_URL="https://$OBS_HOSTNAME"
# local connection as using self-signed cert for suse obsevability external ingress
SUSE_OBSERVABILITY_API_URL="http://obs-suse-observability-router.suse-observability.svc.cluster.local:8080"
SUSE_OBSERVABILITY_API_KEY="$OBS_API_KEY"
SUSE_OBSERVABILITY_API_CLI_TOKEN="$STS_TOKEN"
OBSERVED_SERVER_NAME="$AI_CLUSTER_NAME"
cat << AIOBSEOF >./local/aiobs-values.yaml
global:
  imagePullSecrets:
  - application-collection 
serverUrl: $SUSE_OBSERVABILITY_API_URL
apiKey: $SUSE_OBSERVABILITY_API_KEY
apiToken: $SUSE_OBSERVABILITY_API_CLI_TOKEN
clusterName: $OBSERVED_SERVER_NAME
AIOBSEOF

Log "\__Installing ai-obs helm chart (Observed cluster named $AI_CLUSTER_NAME).."
helm upgrade --kubeconfig=./local/admin.conf --install ai-obs \
  oci://dp.apps.rancher.io/charts/suse-ai-observability-extension \
  -n so-extensions \
  --timeout=5m \
  -f ./local/aiobs-values.yaml

#
echo "${BWhi}**************************************"
echo "SUSE Observability is running at:"
echo "open https://$OBS_HOSTNAME"
echo "**************************************${RCol}"

# -------------------------------------------------------------------------------------
LogElapsedDuration
LogCompleted "Done."

# tidy up
exit 0
