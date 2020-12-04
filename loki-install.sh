#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

loki_NAMESPACE=loki

#HELM_CHART_URL="https://github.com/slugstack/splunk-helm-chart"
HELM_CHART_URL="https://github.com/grafana/loki/tree/master/production/helm/loki"
HELM_CHART_NAME=loki

loki_USERNAME="admin"
loki_PASSWORD="admin123"
loki_OPENSHIFT_INDEX="openshift"
loki_HEC_TOKEN="loki_hec_token"

# Check if OpenShift cli tool is installed
command -v oc >/dev/null 2>&1 || { echo >&2 "OpenShift CLI is required but not installed.  Aborting."; exit 1; } 

# Check if Git is installed
command -v git >/dev/null 2>&1 || { echo >&2 "Git is required but not installed.  Aborting."; exit 1; } 

# Check if Git is installed
command -v helm >/dev/null 2>&1 || { echo >&2 "Helm is required but not installed.  Aborting."; exit 1; } 

oc apply -f ${DIR}/assets/manifests/namespace.yaml

# Helm Install
if [ ! -d "${DIR}/charts/splunk-helm-chart" ]; then
  echo "Cloning Helm Chart"
  git clone ${HELM_CHART_URL} ${DIR}/charts/
fi

cp ${DIR}/assets/helm/templates/* ${DIR}/charts/templates

helm upgrade --namespace ${loki_NAMESPACE} --install -f ${DIR}/assets/helm/values/loki_install.yaml ${HELM_CHART_NAME} ${DIR}/charts/

oc patch -n ${loki_NAMESPACE} deployment/${HELM_CHART_NAME} --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value":  { "name": "SPLUNK_LAUNCH_CONF", "value": "OPTIMISTIC_ABOUT_FILE_LOCKING=1" }  }]'
oc patch -n ${loki_NAMESPACE} deployment/${HELM_CHART_NAME} --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/template/spec/containers/0/env/-\", \"value\":  { \"name\": \"SPLUNK_PASSWORD\", \"value\": \"${SPLUNK_PASSWORD}\" }  }]"

sleep 5

loki_ROUTE=https://$(oc get routes $HELM_CHART_NAME -n ${loki_NAMESPACE} -o jsonpath={.spec.host})

echo "Waiting for loki to become active"
until $(curl -fLk --silent --output /dev/null ${loki_ROUTE}); do sleep 2; done

loki_POD=$(oc get -n ${loki_NAMESPACE} pods -l=app.kubernetes.io/name=loki -o jsonpath='{.items[0].metadata.name}')

OPENSHIFT_INDEX_CREATED=$(oc -n ${loki_NAMESPACE} exec ${loki_POD} -- curl -ks -u ${loki_USERNAME}:${loki_PASSWORD} -o /dev/null -w "%{http_code}" https://localhost:8089/services/data/indexes/${loki_OPENSHIFT_INDEX})

if [ ${OPENSHIFT_INDEX_CREATED} -eq 404 ]; then
  echo "Creating OpenShift Index"
  oc exec -n ${loki_NAMESPACE} ${loki_POD} -- curl -ks -u ${loki_USERNAME}:${loki_PASSWORD} -o /dev/null https://localhost:8089/services/data/indexes -d name=${loki_OPENSHIFT_INDEX} -d datatype=event
fi

oc exec -n ${loki_NAMESPACE} ${loki_POD} -- curl -ks -u ${loki_USERNAME}:${loki_PASSWORD} -o /dev/null https://localhost:8089/servicesNS/admin/splunk_httpinput/data/inputs/http/${loki_HEC_TOKEN} -d indexes=${loki_OPENSHIFT_INDEX} -d index=${loki_OPENSHIFT_INDEX}
