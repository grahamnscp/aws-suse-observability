#!/bin/bash

source ./params.sh
source ./utils/utils.sh

# -------------------------------------------------------------------------------------
# OpenTelelemetry setup on AI cluster

AI_CLUSTER_NAME=ai

LogStarted "\_Configure OpenTelemetry Collector for SUSE AI (remote cluster).."

Log "\__Creating observability namespace.."
kubectl --kubeconfig=./local/admin.conf create namespace observability

# Add custom rbac for opentelemetry-collector
Log "\__Creating rbac for opentelemetry-collector serviceAccount.."
cat << RBACEOF >./local/remote-otel-rbac.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: suse-observability-otel-scraper
rules:
- apiGroups:
  - ""
  resources:
  - events
  - namespaces
  - namespaces/status
  - nodes
  - nodes/spec
  - pods
  - pods/status
  - replicationcontrollers
  - replicationcontrollers/status
  - resourcequotas
  - services
  - endpoints
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - apps
  resources:
  - daemonsets
  - deployments
  - replicasets
  - statefulsets
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - extensions
  resources:
  - daemonsets
  - deployments
  - replicasets
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - batch
  resources:
  - jobs
  - cronjobs
  verbs:
  - get
  - list
  - watch
- apiGroups:
    - autoscaling
  resources:
    - horizontalpodautoscalers
  verbs:
    - get
    - list
    - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: suse-observability-otel-scraper
  labels:
    app: opentelemetry-collector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: suse-observability-otel-scraper
subjects:
- kind: ServiceAccount
  name: opentelemetry-collector
  namespace: observability
---
RBACEOF
kubectl --kubeconfig=./local/admin.conf apply -f local/remote-otel-rbac.yaml

OBS_API_KEY=`cat ./local/obs-apikey.txt`

Log "\__Creating open-telemetry-collector API_KEY secret.."
kubectl --kubeconfig=./local/admin.conf create secret generic open-telemetry-collector --namespace observability --from-literal=API_KEY="$OBS_API_KEY"

cat << OTELVEOF >./local/remote-otel-values.yaml
global:
  imagePullSecrets:
  - application-collection

extraEnvsFrom:
  - secretRef:
      name: open-telemetry-collector

mode: deployment
ports:
  metrics:
    enabled: true
presets:
  kubernetesAttributes:
    enabled: true
    extractAllPodLabels: true

config:
  receivers:
    prometheus:
      config:
        scrape_configs:
        - job_name: 'gpu-metrics'
          scrape_interval: 10s
          scheme: http
          kubernetes_sd_configs:
            - role: endpoints
              namespaces:
                names:
                - gpu-operator

  extensions:
    # Use the API key from the env for authentication
    bearertokenauth:
      scheme: SUSEObservability
      token: \${env:API_KEY}

  exporters:
    nop: {}
    otlp/suse-observability:
      auth:
        authenticator: bearertokenauth
      endpoint: https://otlp-grpc-${OBS_HOSTNAME}:443
      compression: snappy
      tls:
        insecure_skip_verify: true
        #insecure: true
    otlphttp/suse-observability:
      auth:
        authenticator: bearertokenauth
      endpoint: http://otlp-http-${OBS_HOSTNAME}:80
      compression: snappy
      tls:
        insecure: true

  processors:
    batch: {}
    resource:
      attributes:
      - key: k8s.cluster.name
        action: upsert
        value: $AI_CLUSTER_NAME
      - key: service.instance.id
        from_attribute: k8s.pod.uid
        action: insert
      - key: service.namespace
        from_attribute: k8s.namespace.name
        action: insert
    memory_limiter:
      check_interval: 5s
      limit_percentage: 80
      spike_limit_percentage: 25
    tail_sampling:
      decision_wait: 10s
      policies:
      - name: rate-limited-composite
        type: composite
        composite:
          max_total_spans_per_second: 500
          policy_order: [errors, slow-traces, rest]
          composite_sub_policy:
          - name: errors
            type: status_code
            status_code:
              status_codes: [ ERROR ]
          - name: slow-traces
            type: latency
            latency:
              threshold_ms: 1000
          - name: rest
            type: always_sample
          rate_allocation:
          - policy: errors
            percent: 33
          - policy: slow-traces
            percent: 33
          - policy: rest
            percent: 34
    filter/dropMissingK8sAttributes:
      error_mode: ignore
      traces:
        span:
          - resource.attributes["k8s.node.name"] == nil
          - resource.attributes["k8s.pod.uid"] == nil
          - resource.attributes["k8s.namespace.name"] == nil
          - resource.attributes["k8s.pod.name"] == nil

  connectors:
    spanmetrics:
      metrics_expiration: 5m
      namespace: otel_span
    routing/traces:
      error_mode: ignore
      table:
      - statement: route()
        pipelines: [traces/sampling, traces/spanmetrics]

  service:
    extensions: [ health_check,  bearertokenauth ]
    pipelines:
      traces:
        receivers: [otlp, jaeger]
        processors: [filter/dropMissingK8sAttributes, memory_limiter, resource]
        exporters: [debug, spanmetrics, routing/traces, otlphttp/suse-observability]
      traces/spanmetrics:
        receivers: [routing/traces]
        processors: []
        exporters: [spanmetrics]
      traces/sampling:
        receivers: [routing/traces]
        processors: [tail_sampling, batch]
        exporters: [debug, otlphttp/suse-observability]
      metrics:
        receivers: [otlp, spanmetrics, prometheus]
        processors: [memory_limiter, resource, batch]
        exporters: [debug, otlphttp/suse-observability]
      logs:
        receivers: [otlp]
        processors: []
        exporters: [nop]

serviceAccount:
  name: opentelemetry-collector
  create: true
OTELVEOF


Log "\__Authenticating local helm cli to SUSE Application Collection registry.."
helm registry login dp.apps.rancher.io/charts -u $APPCOL_USER -p $APPCOL_TOKEN

Log "\__Creating docker-registry application-collection secret.."
kubectl --kubeconfig=./local/admin.conf create secret docker-registry application-collection --docker-server=dp.apps.rancher.io --docker-username=$APPCOL_USER --docker-password=$APPCOL_TOKEN -n observability


Log "\__Installing opentelemetry-collector helm chart on SUSE AI (remote cluster).."
helm upgrade --kubeconfig=./local/admin.conf --install opentelemetry-collector \
  oci://dp.apps.rancher.io/charts/opentelemetry-collector \
  -n observability \
  -f ./local/remote-otel-values.yaml

# ----------------------
# create a dummy gpu-operator namespace and resources
Log "\_Creating gpu-operator namespace for testing.."
kubectl --kubeconfig=./local/admin.conf create namespace gpu-operator
cat << APPEOF >./local/sample-app-wordpress.yaml
wordpress:
  wordpressUsername: geeko
  wordpressPassword: geeko
  wordpressBlogName: "SUSE Blog!"
  persistence:
    enabled: false
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: selfsigned-issuer
    tls: true
  mariadb:
    auth:
      rootPassword: "Maria4Ever"
      password: "Maria4Ever"
    primary:
      persistence:
        enabled: false
APPEOF
helm repo add rodeo https://rancher.github.io/rodeo
helm repo update
Log "\__Installing sample app into gpu-operator namespace.."
helm --kubeconfig=./local/admin.conf upgrade --install wordpress rodeo/wordpress \
  --namespace gpu-operator \
  --set wordpress.ingress.hostname=wordpress-$OBS_HOSTNAME \
  -f ./local/sample-app-wordpress.yaml

# -------------------------------------------------------------------------------------
LogElapsedDuration
LogCompleted "Done."

# tidy up
exit 0
