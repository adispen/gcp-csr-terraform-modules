# Sourcing Terraform Modules Stored in GCP Cloud Source Repositories from Cloud Build

When using GCP's Cloud Build to automate your Terraform infrastructure deployments you'll
almost certainly need to store and manage your Terraform Modules in version control. 
If you're using git, Terraform makes it easy to [source your Modules directly from the 
repository](https://developer.hashicorp.com/terraform/language/modules/sources#generic-git-repository) and even executes this as a shallow clone to improve performance. 
While [using GitHub makes it even easier](https://developer.hashicorp.com/terraform/language/modules/sources#github) to source your Terraform Modules from inside your Cloud Build deployments,
it may not be permissible for your organization to expose the SSH keys required for Cloud Build to reach outside of GCP.
The same can be said about any of the many git as a service offerings available.

GCP however offers a cloud native version control alternative that allows for Service Account based authorization
for interoperability between services.  Utilizing [Google Cloud Source Repositories](https://cloud.google.com/source-repositories/docs) (GCSR or CSR) allows us to 
securely provide access for Cloud Build to pull Terraform Modules with full permission scoping and audit log support via GCP IAM.
Even if your repository is already hosted on a platform such as GitHub, [CSR provides mirroring](https://cloud.google.com/source-repositories/docs/mirroring-repositories) 
for most major git hosting providers enabling you to easily utilize these tools without potentially exposing access to your cloud environment.

## Assumptions

Before we get started it is important to understand the state this blog expects your environment to be in.  Ensure the following are true
before you proceed:
* GCP Project configured with Cloud Build and CSR APIs enabled.
* Local `gcloud` SDK is properly installed, set up, and authenticated with the desire project.

## Creating the Terraform Image for Cloud Build

While using the Hashicorp provided Terraform image may be sufficient for most deployments, if you intend to manage your
Cloud Build deployments it is advisable to create your own.  There are many benefits to this including any bespoke tooling
your automation may require, but in our case it is important that our Terraform builder image also has access to the `gcloud` SDK.
This will allow Terraform to properly find the credentials associated with the assigned Cloud Build service account when
authenticating against CSR.

```dockerfile
FROM alpine:3.17

ENV TERRAFORM_VERSION=1.4.6

# Download and install Terraform
RUN wget https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
RUN unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip && rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip
RUN mv terraform /usr/bin/terraform

# Set up gcloud SDK CLI
RUN apk add --no-cache bash python3 git

RUN wget https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-421.0.0-linux-x86_64.tar.gz \
    -O /tmp/google-cloud-sdk.tar.gz | bash

RUN mkdir -p /usr/local/gcloud \
    && tar -C /usr/local/gcloud -xvzf /tmp/google-cloud-sdk.tar.gz \
    && /usr/local/gcloud/google-cloud-sdk/install.sh -q

ENV PATH $PATH:/usr/local/gcloud/google-cloud-sdk/bin

ENTRYPOINT ["/usr/bin/terraform"]
```

The above simply creates an image with all the prerequisites for running Terraform as well as the `gcloud` SDK. You can 
adjust the SDK and Terraform version as required.  You can also add any other libraries or tooling your particular deployment
pipeline might need.

`docker build -t gcr.io/my-project/terraform:1.4.6 .`

With this image created, be sure to [store it in Container Registry](https://cloud.google.com/container-registry/docs/pushing-and-pulling) so Cloud Build can access and run it.

`docker push gcr.io/my-project/terraform:1.4.6`

## Creating the Cloud Build Pipeline 

Now we need to set up our Cloud Build pipeline to actually deploy the Terraform changes.  This section assumes you have an
existing Cloud Build pipeline and trigger already configured and won't be covering all the different options available. 
The main configuration change will be ensuring that the Service Account your pipeline uses has the `roles/source.reader` role
or its associated permissions attached.

```yaml
steps:
  - name: "gcr.io/my-project/terraform:1.4.6"
    entrypoint: "bash"
    args:
      - -c
      - |
        git config --global credential.'https://source.developers.google.com'.helper gcloud.sh &&
        terraform init
```

The above should be the first step in your Cloud Build pipeline file. Make sure you are passing the name of the image we created
in the previous step so that all the correct libraries are available to the Cloud Build container.

The `git config` line configures git to use the local `gcloud` SDK credential helper when reaching out to the CSR domain.  We'll specify
the actual location of the code within the Terraform itself.

## Updating the Terraform Module Reference

Finally, we'll need to modify the Terraform configuration file that calls the module source.  You'll only need to modify the `source` 
field in your module call, everything else can remain as configured previously.

```
my-example-repo/
└── modules
    └── example-remote-module
        └── main.tf
```

```hcl
module "example-remote-module" {
  source = "git::https://source.developers.google.com/p/my-project/r/my-example-repo//modules/example-remote-module?ref=main"
  ...
}
```

Above we can see a few different configuration options in action, as well as the directory structure of the remote repository we are
sourcing our module from.  

Let's break down each part of the `source` block:

`https://source.developers.google.com/p/my-project/r/my-example-repo/`

First we see the full [remote reference URL for a CSR repository](https://cloud.google.com/source-repositories/docs/adding-repositories-as-remotes). In the example I'm using a placeholder project and repository name in `my-project` and `my-example-repo` respectively.
Replace them with your project and repository names.

`my-example-repo//modules/example-remote-module`

Next we see the specific module directory. In this case we have a folder named `modules` that contains the folder
`example-remote-module`, which is where our module code lives. Note the `//` between the repository name and the 
folder reference.  Once again, replace `modules` and `example-remote-module` with any relevant directory names in your
repository.

`/example-remote-module?ref=main`

Finally we see the revision reference in `?ref=main`.  This is how Terraform [knows which version of your repository to reference](https://developer.hashicorp.com/terraform/language/modules/sources#selecting-a-revision).
This allows you to specify anything that a `checkout` command would accept by simply replacing the `main` identifier 
with whatever revision desired including branch names, tags, and SHA-1 hashes.  [Using tags and/or branches here is highly recommended](https://www.hashicorp.com/resources/a-guide-to-terraform-binary-provider-and-module-versioning#:~:text=be%20accepted%20soon.-,Module%20Versioning,-Let%27s%20bring%20it)
for ensuring whichever Terraform configurations are pulling the module are aware of exactly

## Performing a Local Terraform Apply

During development you may need to apply your Terraform configuration locally for testing or debugging.  While the above
configuration is meant to operate in an automated Cloud Build CI/CD pipeline, you can still apply the Terraform configuration
from your local machine without any code changes.  

The only considerations to make are to ensure that you have the `gcloud` SDK installed.  Once installed fully, make sure
to authenticate with your account using `gcloud auth application-default login` and select the project project with
`gcloud config set project <project name>`.  More configuration specifics can be found [in the GCP docs](https://cloud.google.com/sdk/docs/authorizing).
Finally, whatever user account you are authing with must have the correct roles and permissions to read the CSR repository.

## Conclusion

Whether you already use a repository located in CSR or have a managed git repository on another host, this method provides
a more secure and auditable method for managing your Terraform modules in CI/CD. Removing the need to pass around and 
maintain SSH keys between different services should significantly reduce the overhead required, and more tightly integrate into
your cloud environment's existing IAM processes and procedures.

## Links and References
* [This blog as a repository](https://github.com/adispen/gcp-csr-terraform-modules)
* [Remote Module References in Terraform](https://developer.hashicorp.com/terraform/language/modules/sources#generic-git-repository)
* [GCP Cloud Source Repositories Docs](https://cloud.google.com/source-repositories/docs)
* [Managing GCP Infrastructure With Terraform and Cloud Build](https://cloud.google.com/docs/terraform/resource-management/managing-infrastructure-as-code)