.PHONY: ping check apply apply-tags deps

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
