.PHONY: ping check apply apply-tags deps k8s-bootstrap argo-sync argo-status kubeconfig

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

kubeconfig:
	@mkdir -p ~/.kube
	@ssh ed@nas2 cat /etc/rancher/k3s/k3s.yaml \
	  | sed \
	    -e 's|https://127.0.0.1:6443|https://nas2.taile9c9c.ts.net:6443|g' \
	    -e 's|name: default|name: nas2|g' \
	    -e 's|cluster: default|cluster: nas2|g' \
	    -e 's|user: default|user: nas2|g' \
	    -e 's|current-context: default|current-context: nas2|g' \
	  > ~/.kube/nas2.yaml
	@chmod 600 ~/.kube/nas2.yaml
	@printf 'Written to ~/.kube/nas2.yaml\n'
	@printf 'Use: kubectl --kubeconfig=~/.kube/nas2.yaml get nodes\n'
	@printf ' or: export KUBECONFIG=~/.kube/nas2.yaml\n'
