#!/bin/bash

docker buildx build . -t imgconsole-arm64 --platform linux/arm64  && \
docker buildx build . -t imgconsole-riscv64 --platform linux/riscv64 
