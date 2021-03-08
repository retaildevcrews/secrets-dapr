# DAPR secrets sync

## Simple local app with DAPR accessing local file secret

1. Install DAPR
    Follow the steps [here](https://docs.dapr.io/getting-started/install-dapr-cli/) to install `dapr cli`.

2. Build the sample node application (within `dapr-secret-sync` folder)

    ```bash
    cd local-simple
    npm install
    ```

3. Update the `secretsFile` value in `local-secret.yaml` file under components folder.

   ```yaml
    apiVersion: dapr.io/v1alpha1
    kind: Component
    metadata:
      name: localfile
      namespace: default
    spec:
      type: secretstores.local.file
      version: v1
      metadata:
        - name: secretsFile
          value: <PATH TO REPO>/secrets-dapr/dapr-secret-sync/local-simple/mysecrets.json
        - name: nestedSeparator
          value: ":"
   ```

4. Rename file `kv-secret.yaml` to `kv-secret.yaml.anything` under the components folder

5. Run the sample application with a secret in a local file - `secret store`

    ```bash
    export SECRET_STORE="localfile"
    dapr run --app-id localapp --components-path ./components --app-port 3000 --dapr-http-port 3500 node app.js
    ```

6. From another terminal curl the node app.

    ```bash
    curl -k http://localhost:3000/getsecret
    ```

## Simple local app with DAPR accessing secret in KV

1. Install DAPR
    Follow the steps [here](https://docs.dapr.io/getting-started/install-dapr-cli/) to install `dapr cli`.

2. Build the sample node application

    ```bash
    cd local-simple
    npm install
    ```

3. Create Key Vault, secret, service principal and grant access to get/list secrets

    ```bash
    # Define variables
    export region=eastus
    export kvname=simplekvdapr0001
    export rgname=dapr-rg01
    export spname=simplekv01
    export aksname=aksdapr0001

    # Create Resource Group
    az group create --name $rgname --location $region

    # Create Key Vault
    az keyvault create --location $region --name $kvname --resource-group $rgname

    # Create Service Principal with cert and store it in Key Vault
    spID=$(az ad sp create-for-rbac --name $spname --create-cert --cert $spname --keyvault $kvname --skip-assignment --years 1 --query appId -o tsv)
    spOID=$(az ad sp show --id $spID --query objectId -o tsv)
    spTenantID=$(az ad sp show --id $spID --query appOwnerTenantId -o tsv)

    # set policy in kev vault
    az keyvault set-policy --name $kvname --spn $spID --secret-permissions get list 
    az keyvault secret download --vault-name $kvname --name $spname --encoding base64 --file $spname.pfx

    echo vault name: $kvname
    echo tenant: $spTenantID
    echo spid: $spID
    echo pfx: $PWD/$spname.pfx
    ```

4. Rename, Update Service Principal and pfx path details in the `kv-secret.yaml` file

   ```yaml
    apiVersion: dapr.io/v1alpha1
    kind: Component
    metadata:
        name: azurekeyvault
        namespace: default
    spec:
        type: secretstores.azure.keyvault
        version: v1
        metadata:
            -   name: vaultName
                value: <KEY VAULT NAME>
            -   name: spnTenantId
                value: <SP TENANT ID>
            -   name: spnClientId
                value: <SP CLIENT ID>
            -   name: spnCertificateFile
                value: <PATH TO REPO/secrets-dapr/dapr-secret-sync/local-simple/<NAME OF PFX>.pfx
   ```

5. Create sample secret in the key vault

    ```bash
    # Create Sample Secret
    az keyvault secret set -n mysecret --vault-name $kvname --value "hellofromkv"
    ```

6. Run the sample application with a secret in the key vault - `secret store`

    ```bash
    export SECRET_STORE="azurekeyvault"
    dapr run --app-id localapp --components-path ./components --app-port 3000 --dapr-http-port 3500 node app.js
    ```

7. From another terminal curl the node app.

    ```bash
    curl -k http://localhost:3000/getsecret
    ```

## Simple app running in AKS

> Prerequisites

- Azure CLI
- Azure Subscription
- Enough permissions in the Azure subscription to create role assignments

### Create your cluster with pod identities

1. Configure the following variables:

    ```bash
    export region=eastus
    export kvname=simplekvdapr0001
    export rgname=dapr-rg01
    export spname=simplekv01
    export aksname=aksdapr0001
    ```

2. Configure `Azure CLI` with the PodIdentity feature (`preview`). This example follows the configuration described [here](https://docs.microsoft.com/en-us/azure/aks/use-azure-ad-pod-identity)

    ```bash
    az feature register --name EnablePodIdentityPreview --namespace Microsoft.ContainerService
    az provider register -n Microsoft.ContainerService
    # Install the aks-preview extension
    az extension add --name aks-preview
    az extension update --name aks-preview
    ```

3. Create an AKS cluster with managed identities and retrieved the configuration. Keep in mind, Pod Identities do not work with kubenet due to security issues.

    ```bash
    az group create --name $rgname --location $region
    az aks create -g $rgname -n $aksname --enable-managed-identity --enable-pod-identity --network-plugin azure --node-count 1
    az aks get-credentials --resource-group $rgname --name $aksname --overwrite-existing
    ```

4. Create a Key Vault with a secret `mysecret` (optional if the executed in the previous exercise).

    ```bash
    az keyvault create --location $region --name $kvname --resource-group $rgname
    az keyvault secret set -n mysecret --vault-name $kvname --value "hellofromdaprinkv"
    ```

5. Create and configure the identity. In this case the identity is going to be created in the same resource group as the AKS and the Key Vault:

    ```bash
    az identity create --resource-group $rgname --name $aksname
    export IDENTITY_CLIENT_ID="$(az identity show -g $rgname -n $aksname --query clientId -otsv)"
    export IDENTITY_RESOURCE_ID="$(az identity show -g $rgname -n $aksname --query id -otsv)"

    # Retrieve details from the AKS nodes
    NODE_GROUP=$(az aks show -g $rgname -n $aksname --query nodeResourceGroup -o tsv)
    NODES_RESOURCE_ID=$(az group show -n $NODE_GROUP -o tsv --query "id")
    
    # Assign **Reader** role to the identity. In this case to the AKS node resource (VMSS).
    az role assignment create --role "Reader" --assignee "$IDENTITY_CLIENT_ID" --scope $NODES_RESOURCE_ID
    
    # Assign **get** and **list** permissions over the Key Vault secrets to the Identity
    az keyvault set-policy --name $kvname --spn "$IDENTITY_CLIENT_ID" --secret-permissions get list
    ```

6. Create pod identity

    ```bash
    export POD_IDENTITY_NAME="pod-identity-dapr"
    export POD_IDENTITY_NAMESPACE="default"
    az aks pod-identity add --resource-group $rgname --cluster-name $aksname --namespace ${POD_IDENTITY_NAMESPACE} --name ${POD_IDENTITY_NAME} --identity-resource-id ${IDENTITY_RESOURCE_ID}
    ```

7. Install DAPR in the cluster

    ```bash
    dapr init --kubernetes
    ```

### Deploy the two use cases (change terminal directory to k8s-simple)

1. For the first use case, the application that will be consuming native kubernetes secrets

    ```bash
    # Create a native k8s secret
    kubectl create secret generic mysecret --from-literal=mysecret=native-k8s-secret
    # deploy the app
    kubectl apply -f app-k8s-deployment.yaml
    ```

2. Update key vault name and por identity id in `component.yaml` file

    ```bash
    echo KEY VAULT NAME: $kvname
    echo POD IDENTITY ID: $IDENTITY_CLIENT_ID
    ```

    ```yaml
    apiVersion: dapr.io/v1alpha1
    kind: Component
    metadata:
      name: azurekeyvault
      namespace: default
    spec:
      type: secretstores.azure.keyvault
      version: v1
      metadata:
        - name: vaultName
          value: <KEY VAULT NAME>
        - name: spnClientId
          value: <POD IDENTITY ID>
    ```

3. For the first use case, the application that will be consuming native kubernetes secrets

    ```bash
    # deploy the dapr component
    kubectl apply -f component.yaml
    # deploy the app
    kubectl apply -f app-kv-deployment.yaml
    ```

4. Hit both end points

    ```bash
    export NODE_APP_KV=$(kubectl get svc nodeappkv --output 'jsonpath={.status.loadBalancer.ingress[0].ip}')
    curl -k http://$NODE_APP_KV/getsecret
    export NODE_APP_K8S=$(kubectl get svc nodeappk8s --output 'jsonpath={.status.loadBalancer.ingress[0].ip}')
    curl -k http://$NODE_APP_K8S/getsecret
    ```

## Let's include `akv2k8s` controller (only sync secrets)

1. Configure akv2k8s in aks using Pod Identities

    ```bash
    # akv2k8s needs its own namespace
    export akv2k8sns=akv2k8s
    
    # Create a new pod identity and binding for akv2k8s 
    az aks pod-identity add --resource-group $rgname --cluster-name $aksname --namespace $akv2k8sns --name ${POD_IDENTITY_NAME} --identity-resource-id ${IDENTITY_RESOURCE_ID}

    # install akv2k8s in the cluster
    helm repo add spv-charts https://charts.spvapi.no
    helm repo update
    helm upgrade --install akv2k8s spv-charts/akv2k8s --namespace $akv2k8sns --set controller.keyVaultAuth=environment --set controller.podLabels.aadpodidbinding=${POD_IDENTITY_NAME} --set env_injector.keyVaultAuth=environment --set env_injector.podLabels.aadpodidbinding=${POD_IDENTITY_NAME}
    ```

2. Create a new secret to test `akv2k8s`

    ```bash
    # create mysecret 2 in kv
    az keyvault secret set -n mysecret2 --vault-name $kvname --value "hello-from-kv-secret2"

    # lets create a azuresecret sync
    kubectl apply -f secret-sync.yaml
    ```

3. Update the `keyvaultname` value in `secret-sync.yaml`

    ```yaml
    apiVersion: spv.no/v2beta1
    kind: AzureKeyVaultSecret
    metadata:
      name: mysecret2
      namespace: default
    spec:
      vault:
        name: simplekvdapr0001 # name of key vault
        object:
          name: mysecret2 # name of the akv object
          type: secret # akv object type
      output:
        secret:
          name: mysecret2 # kubernetes secret name
          dataKey: secret-value # key to store object value in kubernetes secret    
    ```

4. Apply the AzureKeyVaultSecret

    ```bash
    kubectl apply -f secret-sync.yaml
    ```

5. Let `akv2k8s` work with `dapr`

    ```bash
    # delete the secret dapr was using
    kubectl delete secret mysecret

    # create the new AzureKeyVaultSecret - remember to update the kvname
    kubectl apply -f secret-sync-dapr.yaml

    # hit the end point
    curl -k http://$NODE_APP_K8S/getsecret

    # rotate tbe secret in kv and try again
    curl -k http://$NODE_APP_K8S/getsecret
    ```
