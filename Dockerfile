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