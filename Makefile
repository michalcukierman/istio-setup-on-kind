CLUSTER1 ?= "cluster1"
CLUSTER2 ?= "cluster2"
CTX_CLUSTER1 ?= "kind-cluster1"
CTX_CLUSTER2 ?= "kind-cluster2"
ISTIOCTL ?= istioctl

.fetch.done:
	git clone https://github.com/istio/istio.git
	touch .fetch.done

.kind-cloud-provider.done:
	# Without cloud-provider-kind running the background the gateways will never get an IP address and will not get programmed in kind
	docker run -d --rm --network kind -v /var/run/docker.sock:/var/run/docker.sock --name cloud-provider-kind registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.7.0 || true
	touch .kind-cloud-provider.done

.certs.done:
	mkdir -p certs
	touch .certs.done

.root-ca.done: .fetch.done .certs.done
	cd certs && \
	make -f ../istio/tools/certs/Makefile.selfsigned.mk root-ca
	touch .root-ca.done

.cluster1-cacerts.done: .root-ca.done
	cd certs && \
	rm -rf cluster1 && \
	make -f ../istio/tools/certs/Makefile.selfsigned.mk cluster1-cacerts
	touch .cluster1-cacerts.done

.cluster2-cacerts.done: .root-ca.done
	cd certs && \
	rm -rf cluster2 && \
	make -f ../istio/tools/certs/Makefile.selfsigned.mk cluster2-cacerts
	touch .cluster2-cacerts.done

.prepare.done:
	echo fs.inotify.max_user_watches=655360 | sudo tee -a /etc/sysctl.conf
	echo fs.inotify.max_user_instances=1280 | sudo tee -a /etc/sysctl.conf
	sudo sysctl -p
	touch .prepare.done

cluster1: kind1.yaml .cluster1-cacerts.done .kind-cloud-provider.done
	kind create cluster --name $(CLUSTER1) --config kind1.yaml
	kubectl config use-context $(CTX_CLUSTER1)
	kubectl create namespace istio-system
	kubectl create secret generic cacerts -n istio-system \
		--from-file certs/cluster1/ca-cert.pem \
		--from-file certs/cluster1/ca-key.pem \
		--from-file certs/cluster1/root-cert.pem \
		--from-file certs/cluster1/cert-chain.pem

cluster2: kind2.yaml .cluster2-cacerts.done .kind-cloud-provider.done
	kind create cluster --name $(CLUSTER2) --config kind2.yaml
	kubectl config use-context $(CTX_CLUSTER2)
	kubectl create namespace istio-system
	kubectl create secret generic cacerts -n istio-system \
		--from-file certs/cluster2/ca-cert.pem \
		--from-file certs/cluster2/ca-key.pem \
		--from-file certs/cluster2/root-cert.pem \
		--from-file certs/cluster2/cert-chain.pem

install-istio1: cluster1.yaml
	kubectl config use-context $(CTX_CLUSTER1)
	kubectl label namespace istio-system topology.istio.io/network=network1
	$(ISTIOCTL) install -y -f cluster1.yaml

install-ew1: .fetch.done
	kubectl config use-context $(CTX_CLUSTER1)
	kubectl get crd gateways.gateway.networking.k8s.io || { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.3.0" | kubectl apply -f -; }
	istio/samples/multicluster/gen-eastwest-gateway.sh --network network1 --ambient | kubectl apply -f -

install-istio2: cluster2.yaml
	kubectl config use-context $(CTX_CLUSTER2)
	kubectl label namespace istio-system topology.istio.io/network=network2
	$(ISTIOCTL) install -y -f cluster2.yaml

install-ew2: .fetch.done
	kubectl config use-context $(CTX_CLUSTER2)
	kubectl get crd gateways.gateway.networking.k8s.io || { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.3.0" | kubectl apply -f -; }
	istio/samples/multicluster/gen-eastwest-gateway.sh --network network2 --ambient | kubectl apply -f -

connect-clusters:
	# istioctl does not correctly figure out the API server address in kind so we have to explicitly provide it
	# We inspec the controlplane node containers and use their IP addresses on the kind network and hardcode port 6443
	# Port can be figured out if you describe k8s API server pod, but given that it's a command line flag it's unlikely
	# to change that often.
	while ! $(ISTIOCTL) create-remote-secret --server=https://$(shell docker inspect $(CLUSTER1)-control-plane | jq -r .[].NetworkSettings.Networks.kind.IPAddress):6443 --context=$(CTX_CLUSTER1) --name=$(CLUSTER1) ; do sleep 1 ; done
	$(ISTIOCTL) create-remote-secret --server=https://$(shell docker inspect $(CLUSTER1)-control-plane | jq -r .[].NetworkSettings.Networks.kind.IPAddress):6443 --context=$(CTX_CLUSTER1) --name=$(CLUSTER1) | kubectl apply -f - --context=$(CTX_CLUSTER2)
	while ! $(ISTIOCTL) create-remote-secret --server=https://$(shell docker inspect $(CLUSTER2)-control-plane | jq -r .[].NetworkSettings.Networks.kind.IPAddress):6443 --context=$(CTX_CLUSTER2) --name=$(CLUSTER2) ; do sleep 1 ; done
	$(ISTIOCTL) create-remote-secret --server=https://$(shell docker inspect $(CLUSTER2)-control-plane | jq -r .[].NetworkSettings.Networks.kind.IPAddress):6443 --context=$(CTX_CLUSTER2) --name=$(CLUSTER2) | kubectl apply -f - --context=$(CTX_CLUSTER1)

clean:
	kind delete cluster --name $(CLUSTER1)
	kind delete cluster --name $(CLUSTER2)

setup: .prepare.done cluster1 cluster2 install-istio1 install-istio2 install-ew1 install-ew2 connect-clusters
