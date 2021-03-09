# Pod identities to Key Vault through DAPR

In this example we will be using DAPR Secret Store through Pod Identities to access a Key Vault.
This example can be use as the fan out service that manages all secrets for multiple nodes.

## Configure the environment

### Prerequisites

- Azure CLI
- Azure Subscription
- Enough permissions to create role assignments

### Configure environment steps

1. Configure the following variables:

    - `region`: the Azure region where kv/aks/identity will be deployed
    - `kvname`: Key Vault name
    - `rgname`: Resource group name
    - `aksname`: AKS name, also used for the Identity name.

    as an example:

    ```bash
    export region=eastus
    export kvname=kvdapr0001
    export rgname=dapr-rg01
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
    az aks create -g $rgname -n $aksname --enable-managed-identity --enable-pod-identity --network-plugin azure
    az aks get-credentials --resource-group $rgname --name $aksname
    ```

4. Create a Key Vault with a secret `mysecret`.

    ```bash
    az keyvault create --location $region --name $kvname --resource-group $rgname
    az keyvault secret set -n mysecret --vault-name $kvname --value "hellofromdapr"
    ```

5. Create and configure the identity. In this case the identity is going to be created in the same resource group as the AKS and the Key Vault:

    ```bash
    az identity create --resource-group $rgname --name $aksname
    export IDENTITY_CLIENT_ID="$(az identity show -g $rgname -n $aksname --query clientId -otsv)"
    export IDENTITY_RESOURCE_ID="$(az identity show -g $rgname -n $aksname --query id -otsv)"

    # Retrieve details from the AKS nodes
    NODE_GROUP=$(az aks show -g $rgname -n $aksname --query nodeResourceGroup -o tsv)
    NODES_RESOURCE_ID=$(az group show -n $NODE_GROUP -o tsv --query "id")
    
    # Assign `Reader` role to the identity. In this case to the AKS node resource (VMSS).
    az role assignment create --role "Reader" --assignee "$IDENTITY_CLIENT_ID" --scope $NODES_RESOURCE_ID
    
    # Assign `get` and `list` permissions over the Key Vault secrets to the Identity
    az keyvault set-policy --name $kvname --spn "$IDENTITY_CLIENT_ID" --secret-permissions get list
    ```

6. Create pod identity

    ```bash
    export POD_IDENTITY_NAME="pod-identity-dapr"
    export POD_IDENTITY_NAMESPACE="default"
    az aks pod-identity add --resource-group $rgname --cluster-name $aksname --namespace ${POD_IDENTITY_NAMESPACE} --name ${POD_IDENTITY_NAME} --identity-resource-id ${IDENTITY_RESOURCE_ID}
    ```

### Configure DAPR and deploy sample app

Now we will be deploying a sample application adn configuring dapr in the cluster. The sample source code can be located [here](https://github.com/dapr/quickstarts/tree/master/secretstore).

1. Deploy dapr into aks
    The quickest way to `init` dapr in your cluster is through `dapr cli`. Follow the steps [here](https://docs.dapr.io/getting-started/install-dapr-cli/) to install `dapr cli`.
    Confirm you are in the right k8s context. To init dapr:

    ```bash
    dapr init --kubernetes
    ```

2. Deploy dapr component `(secretstores.azure.keyvault)`
    Update values in `component.yaml` file

    ```yaml
    apiVersion: dapr.io/v1alpha1
    kind: Component
    metadata:
      name: azurekeyvault
      namespace: <$POD_IDENTITY_NAMESPACE>
    spec:
      type: secretstores.azure.keyvault
      version: v1
      metadata:
        - name: vaultName
          value: <$kvname>
        - name: spnClientId
          value: <$IDENTITY_CLIENT_ID>
    ```

    deploy the component to your cluster:

    ```bash
    kubectl apply -f component.yaml
    ```

3. Deploy the node app including the podidentity label `aadpodidbinding`
    Update values in `stack.yaml` file

    ```yaml
    ...
    aadpodidbinding: pod-identity-dapr
    ...
    ```

    deploy the component to your cluster:

    ```bash
    kubectl apply -f stack.yaml
    ```

### Source code

The container used in `stack.yaml` is based on dapr example located here. For tracking purposes a copy of the example code can be located under `daprexample` folder.
