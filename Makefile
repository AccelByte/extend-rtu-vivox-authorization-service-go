# Copyright (c) 2024 AccelByte Inc. All Rights Reserved.
# This is licensed software from AccelByte Inc, for limitations
# and restrictions contact your company contract manager.

SHELL := /bin/bash

IMAGE_NAME := $(shell basename "$$(pwd)")-app
BUILDER := extend-builder

GOLANG_DOCKER_IMAGE := golang:1.20

TEST_SAMPLE_CONTAINER_NAME := sample-service-extension-test

proto:
	docker run -t --rm -u $$(id -u):$$(id -g) \
		-v $$(pwd):/data \
		-w /data \
		--entrypoint /bin/bash \
		rvolosatovs/protoc:4.1.0 \
			proto.sh

lint:
	rm -f lint.err
	find -type f -iname go.mod -exec dirname {} \; | while read DIRECTORY; do \
		echo "# $$DIRECTORY"; \
		docker run -t --rm \
				-u $$(id -u):$$(id -g) \
				-e GOCACHE=/data/.cache/go-build \
				-e GOLANGCI_LINT_CACHE=/data/.cache/go-lint \
				-v $$(pwd):/data \
				-w /data \
				golangci/golangci-lint:v1.42.1\
				sh -c "cd $$DIRECTORY \
						&& golangci-lint \
								-v --timeout 5m \
								--max-same-issues 0 \
								--max-issues-per-linter 0 \
								--color never run \
						|| touch /data/lint.err"; \
	done
	[ ! -f lint.err ] || (rm lint.err && exit 1)

build: proto
	docker run -t --rm \
			-u $$(id -u):$$(id -g) \
			-e GOCACHE=/data/.cache/go-build \
			-v $$(pwd):/data \
			-w /data \
			$(GOLANG_DOCKER_IMAGE) \
			sh -c "go build -v"

image:
	docker buildx build -t ${IMAGE_NAME} --load .

imagex:
	docker buildx inspect $(BUILDER) || docker buildx create --name $(BUILDER) --use
	docker buildx build -t ${IMAGE_NAME} --platform linux/amd64 .
	docker buildx build -t ${IMAGE_NAME} --load .
	docker buildx rm --keep-state $(BUILDER)

imagex_push:
	@test -n "$(IMAGE_TAG)" || (echo "IMAGE_TAG is not set (e.g. 'v0.1.0', 'latest')"; exit 1)
	@test -n "$(REPO_URL)" || (echo "REPO_URL is not set"; exit 1)
	docker buildx inspect $(BUILDER) || docker buildx create --name $(BUILDER) --use
	docker buildx build -t ${REPO_URL}:${IMAGE_TAG} --platform linux/amd64 --push .
	docker buildx rm --keep-state $(BUILDER)

test:
	docker run -t --rm -u $$(id -u):$$(id -g) \
		-v $$(pwd):/data/ -w /data/ \
		-e GOCACHE=/data/.cache/go-build \
		-e BASE_PATH=/vivoxauth \
		$(GOLANG_DOCKER_IMAGE) sh -c "go test -v ./..."

test_sample_local_hosted:
	@test -n "$(ENV_PATH)" || (echo "ENV_PATH is not set"; exit 1)
	docker build \
			--tag $(TEST_SAMPLE_CONTAINER_NAME) \
			-f test/sample/Dockerfile \
			test/sample
	docker run --rm -t \
			-u $$(id -u):$$(id -g) \
			-e GOCACHE=/data/.cache/go-build \
			-e GOPATH=/data/.cache/mod \
			--env-file $(ENV_PATH) \
			-v $$(pwd):/data \
			-w /data \
			--name $(TEST_SAMPLE_CONTAINER_NAME) \
			$(TEST_SAMPLE_CONTAINER_NAME) \
			bash ./test/sample/test-local-hosted.sh

test_sample_accelbyte_hosted:
	@test -n "$(ENV_PATH)" || (echo "ENV_PATH is not set"; exit 1)
ifeq ($(shell uname), Linux)
	$(eval DARGS := -u $$(shell id -u) --group-add $$(shell getent group docker | cut -d ':' -f 3))
endif
	docker build \
			--tag $(TEST_SAMPLE_CONTAINER_NAME) \
			-f test/sample/Dockerfile \
			test/sample
	docker run --rm -t \
			-e GOCACHE=/data/.cache/go-build \
			-e GOPATH=/data/.cache/mod \
			-e DOCKER_CONFIG=/tmp/.docker \
			--env-file $(ENV_PATH) \
			-v /var/run/docker.sock:/var/run/docker.sock \
			-v $$(pwd):/data \
			-w /data \
			--name $(TEST_SAMPLE_CONTAINER_NAME) \
			$(DARGS) \
			$(TEST_SAMPLE_CONTAINER_NAME) \
			bash ./test/sample/test-accelbyte-hosted.sh

test_docs_broken_links:
	@test -n "$(SDK_MD_CRAWLER_PATH)" || (echo "SDK_MD_CRAWLER_PATH is not set" ; exit 1)
	rm -f test.err
	bash "$(SDK_MD_CRAWLER_PATH)/md-crawler.sh" \
			-i README.md
	(for FILE in $$(find docs -type f); do \
			(set -o pipefail; DOCKER_SKIP_BUILD=1 bash "$(SDK_MD_CRAWLER_PATH)/md-crawler.sh" -i $$FILE) || touch test.err; \
	done)
	[ ! -f test.err ]