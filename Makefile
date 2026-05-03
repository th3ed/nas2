.PHONY: ping check apply apply-tags deps k8s-bootstrap argo-sync argo-status

deps:
	ansible-galaxy collection install -r requirements.yml

ping:
	ansible all -m ping

check:
	ansible-playbook playbook.yml --check --diff

apply:
	ansible-playbook playbook.yml --diff

apply-tags:
	ansible-playbook playbook.yml --diff --tags "$(TAGS)"

k8s-bootstrap:
	ansible-playbook playbook.yml --diff --tags kubernetes

argo-sync:
	ssh ed@nas2 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n argocd patch application root --type merge -p "{\"operation\":{\"sync\":{}}}"'

argo-status:
	ssh ed@nas2 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get applications -n argocd'
