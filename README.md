
# Secret management

## identify your secrets

Before deciding an approach, the team should do the exercise to identify and classify the application secrets in one of the following types:

- End user secrets. e.g. user passwords, user keys, etc.
- Resource access secrets e.g api keys to storage account, sql db, cosmos db
- Application secrets e.g keys to encrypt users data, api keys, etc

## What to do with the secrets

- End user secrets -> they should not be manage in a `Key Vault`. Best practice is to store them in a database or storage account encrypted.
- Resource access secrets -> avoid using keys/secrets to access Azure resources. Consider managed identities/pod identities.
- Application secrets -> these secrets should be store in `Key Vault`. Always consider having a second/back-up key to allow the system rotate the secrets with minimum interruption

## Application secrets consideration

`Key Vault`s are design to secure and not to distribute secrets. That means the resource have limitations and security in place. During the design of your application keep in mind these [limits](https://docs.microsoft.com/en-us/azure/key-vault/general/service-limits). One key consideration when consuming secrets from `Key Vault` is --throttling--. You can find guidance on how to deal with it [here](https://docs.microsoft.com/en-us/azure/key-vault/general/overview-throttling). In summary you should:

- The code should honor 429s. -> Is your solution going to generate more than 5000 transactions within 10 seconds per subscription?
- Create `Key Vault` per application not for all the platform.
- Use a `Key Vault` per region
- Cache the secrets in memory while running the app
- In case you have multiple nodes for your app, consider a fan out approach for distributing secrets.
- Consider the complexity of your solution by asking these questions.
  - Is it acceptable to restart a service when a key/secret rotates?
  - Are you going to run the application in a k8s cluster?
  - How often is the service going to be call at high demand?
  - What are the expectations for the inner development cycle?

## Examples

### Query `Key Vault` secret through DAPR

This example helps explaining how to use DAPR to easily retrieve secrets from `Key Vault`. This is a good approach since the application owner can easy jump between Azure `Key Vault`, Local File, K8s Secret, Hashicorp Vault, etc.

### Use of Pod Identities/Managed Identities

In this example we demonstrate how to use DAPR secret vault component without the need to create an SP and attached the credentials to the component's configuration.

### akv2k8s

In this example we will be using `akv2k8s` and the environment injector operators to sync `Key Vault` secrets with pods in a k8s cluster.

### Secrets as k8s secrets synced by akv2k8s

In this example we will be using `akv2k8s` to sync the secrets from `Azure Key Vault` and let the app consume the secret through DAPR from the k8s secret.
