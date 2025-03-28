#!/bin/bash

docker buildx build . --platform linux/arm64  && \
docker buildx build . --platform linux/riscv64 
