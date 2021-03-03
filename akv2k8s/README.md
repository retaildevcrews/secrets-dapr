# akv2k8s
This example will show the two methods [akv2k8s](https://akv2k8s.io/) solution sync Key Vault secrets with Kubernetes pods.

Akv2k8s has two main components. The **akv2k8s controller** that syncs Key Vault secrets with K8s secrets. The second component, the **akv2k8s injector** sync Key Vault secrets with pod environment variables.

When to use which?
* controller: use it if it is acceptable to have the secrets store in the cluster as k8s secrets.
* Env injector: use this solution when the security requirements ask to avoid using k8s secrets.

## Configure environment steps
1. Configure the following variables (example):
    ```
    export region=eastus
    export kvname=akv2k8s0001
    export rgname=akv2k8s-rg01
    export aksname=akv2k8s0001
    export akv2k8sns=akv2k8s
    ```

2. Create resources:
    Configure **Azure CLI** with the PodIdentity feature (*preview*). This example follows the configuration described [here](https://docs.microsoft.com/en-us/azure/aks/use-azure-ad-pod-identity)
    ```
    az feature register --name EnablePodIdentityPreview --namespace Microsoft.ContainerService
    az provider register -n Microsoft.ContainerService
    # Install the aks-preview extension
    az extension add --name aks-preview
    az extension update --name aks-preview
    ```
    
    Cluster
    ```
    az group create --name $rgname --location $region
    az aks create -g $rgname -n $aksname --enable-managed-identity --enable-pod-identity --network-plugin azure
    az aks get-credentials --resource-group $rgname --name $aksname    
    ```
    
    Key vault with secret
    ```
    az keyvault create --location $region --name $kvname --resource-group $rgname --enable-soft-delete false
    az keyvault secret set -n mysecret --vault-name $kvname --value "hellofromkv"
    ```
    
    Pod identities
    ```
    az identity create --resource-group $rgname --name $aksname
    export IDENTITY_CLIENT_ID="$(az identity show -g $rgname -n $aksname --query clientId -otsv)"
    export IDENTITY_RESOURCE_ID="$(az identity show -g $rgname -n $aksname --query id -otsv)"

    # Retrieve details from the AKS nodes
    NODE_GROUP=$(az aks show -g $rgname -n $aksname --query nodeResourceGroup -o tsv)
    NODES_RESOURCE_ID=$(az group show -n $NODE_GROUP -o tsv --query "id")

    # Assign **Reader** role to the identity. In this case to the AKS node resource (VMSS).
    az role assignment create --role "Reader" --assignee "$IDENTITY_CLIENT_ID" --scope $NODES_RESOURCE_ID

    # Assign **get** and **list** permissions over the Key Vault secrets to the Identity
    az keyvault set-policy -g $rgname --name $kvname --spn "$IDENTITY_CLIENT_ID" --secret-permissions get list

    ```

3. Configure AKS
    Installing akv2k8s and setting up pod-identity
    ```
    # create ns for akv2k8s resources
    kubectl create ns $akv2k8sns
    
    # create the pod identity
    export POD_IDENTITY_NAME="pod-identity-akv"    
    az aks pod-identity add --resource-group $rgname --cluster-name $aksname --namespace $akv2k8sns --name ${POD_IDENTITY_NAME} --identity-resource-id ${IDENTITY_RESOURCE_ID}

    # install the helm template from a rendered yaml - had to do this because the controller pod didn't allow to add labels through helm configs
    helm repo add spv-charts https://charts.spvapi.no
    helm repo update
    helm upgrade --install akv2k8s spv-charts/akv2k8s --namespace $akv2k8sns --set controller.keyVaultAuth=environment --set controller.podLabels.aadpodidbinding=${POD_IDENTITY_NAME} --set env_injector.keyVaultAuth=environment --set env_injector.podLabels.aadpodidbinding=${POD_IDENTITY_NAME}    
    ```

## Testing controller option
1. Update the key vault name in the *secret-sync.yaml* file and apply it
    ```
    kubectl apply -f secret-sync.yaml
    ```
2. Check your a kubernetes secret created in the default namespace with name *my-secret-from-akv* 
    ```
    kubectl get secret my-secret-from-akv -o yaml
    ```
3. Check a secret update. Go to your key vault and update (rotate) the secret value.
   ```
    kubectl get secret my-secret-from-akv -o yaml
    ```

## Testing injector option
1. Create a namespace to test the injector. The namespace needs the label *azure-key-vault-env-injection: enabled* to enable the webhook that injects the secret.
    ```
    kubectl apply -f inject-ns.yaml
    ```
2. Update the key vault name in the *inject-secret.yaml* file and apply it
    ```
    kubectl apply -f inject-secret.yaml
    ```
3. Deploy a sample app to validate the secret is getting injected into the pod.
    ```
    kubectl apply -f  inject-deployment.yaml
    ```
4. Check the logs in the pod
    ```
    kubectl -n akv-test logs deployment/akvs-secret-app
    ```
