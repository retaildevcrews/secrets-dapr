#!/bin/bash

# TODO: use parameters and validation
# TODO: configure azure cli login / subscription

# configure for your env
# export region=eastus
# export kvname=akv2k8s0008
# export rgname=akv2k8s-rg08
# export aksname=akv2k8s0008
# export akv2k8sns=akv2k8s

# Uncomment the folloing lines to configure AZ CLI to use podidentity feature
# az feature register --name EnablePodIdentityPreview --namespace Microsoft.ContainerService
# az provider register -n Microsoft.ContainerService
# # Install the aks-preview extension
# az extension add --name aks-preview
# az extension update --name aks-preview

az group create --name "$rgname" --location "$region"
az aks create -g "$rgname" -n "$aksname" --enable-managed-identity --enable-pod-identity --network-plugin azure --node-count 1
az aks get-credentials --resource-group "$rgname" --name "$aksname" --overwrite-existing

az keyvault create --location "$region" --name "$kvname" --resource-group "$rgname"
az keyvault secret set -n mysecret --vault-name "$kvname" --value "hellofromkv"

az identity create --resource-group "$rgname" --name "$aksname"
IDENTITY_CLIENT_ID="$(az identity show -g "$rgname" -n "$aksname" --query clientId -otsv)"
export IDENTITY_CLIENT_ID
IDENTITY_RESOURCE_ID="$(az identity show -g "$rgname" -n "$aksname" --query id -otsv)"
export IDENTITY_RESOURCE_ID

# Retrieve details from the AKS nodes
NODE_GROUP=$(az aks show -g "$rgname" -n "$aksname" --query nodeResourceGroup -o tsv)
NODES_RESOURCE_ID=$(az group show -n "$NODE_GROUP" -o tsv --query "id")

# Assign **Reader** role to the identity. In this case to the AKS node resource (VMSS).
az role assignment create --role "Reader" --assignee "$IDENTITY_CLIENT_ID" --scope "$NODES_RESOURCE_ID"

# Assign **get** and **list** permissions over the Key Vault secrets to the Identity
az keyvault set-policy -g "$rgname" --name "$kvname" --spn "$IDENTITY_CLIENT_ID" --secret-permissions get list

# create ns for akv2k8s resources
kubectl create ns "$akv2k8sns"

# create the pod identity
export POD_IDENTITY_NAME="pod-identity-akv"
az aks pod-identity add --resource-group "$rgname" --cluster-name "$aksname" --namespace "$akv2k8sns" --name ${POD_IDENTITY_NAME} --identity-resource-id "${IDENTITY_RESOURCE_ID}"

# install the helm template from a rendered yaml - had to do this because the controller pod didn't allow to add labels through helm configs
helm repo add spv-charts https://charts.spvapi.no
helm repo update
helm upgrade --install akv2k8s spv-charts/akv2k8s --namespace "$akv2k8sns" --set controller.keyVaultAuth=environment --set controller.podLabels.aadpodidbinding=${POD_IDENTITY_NAME} --set env_injector.keyVaultAuth=environment --set env_injector.podLabels.aadpodidbinding=${POD_IDENTITY_NAME}

kubectl apply -f secret-sync.yaml

sleep 10
kubectl get secret my-secret-from-akv -o yaml

# validate injector
kubectl apply -f inject-ns.yaml
kubectl apply -f inject-secret.yaml
kubectl apply -f inject-deployment.yaml
sleep 10
kubectl -n akv-test logs deployment/akvs-secret-app
