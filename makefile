SHELL := /bin/bash

.PHONY: bootstrap inventory k8s-install clean

bootstrap:
	cd terraform/bootstrap && terraform init && terraform apply
	terraform -chdir=terraform/bootstrap output -raw infra_authorized_key_json \
		> terraform/main/terraform-infra-key.json
	chmod 600 terraform/main/terraform-infra-key.json

inventory:
	terraform -chdir=terraform/main output -raw ansible_inventory \
		> ansible/inventory/hosts.yaml

k8s-install: inventory
	cd ansible && \
	ansible-playbook -i inventory/hosts.yaml playbook.yml -b -u ubuntu

clean:
	terraform -chdir=terraform/main destroy
