#!/bin/bash
set -euo pipefail

# Build and push the dev environment Docker image to Docker Hub
# Usage: ./build-and-push.sh <dockerhub-username> [tag]

DOCKERHUB_USERNAME="${1:-}"
TAG="${2:-latest}"
IMAGE_NAME="terraform-devenv"

if [ -z "$DOCKERHUB_USERNAME" ]; then
  echo "Error: Docker Hub username required"
  echo "Usage: $0 <dockerhub-username> [tag]"
  exit 1
fi

FULL_IMAGE="${DOCKERHUB_USERNAME}/${IMAGE_NAME}:${TAG}"

echo "Building Docker image: ${FULL_IMAGE}"
echo "Context: $(pwd)"

# Build from repository root
cd "$(dirname "$0")/../.."

docker build \
  -f k8s/Dockerfile.production \
  -t "${FULL_IMAGE}" \
  --build-arg TZ="$(date +%Z)" \
  .

echo ""
echo "Image built successfully: ${FULL_IMAGE}"
echo ""
echo "Pushing to Docker Hub..."

docker push "${FULL_IMAGE}"

echo ""
echo "✅ Image pushed successfully: ${FULL_IMAGE}"
echo ""
echo "Next steps:"
echo "1. Update k8s/manifests/05-statefulset.yaml with your image name"
echo "2. Create secrets: ./k8s/scripts/create-secrets.sh"
echo "3. Deploy: ./k8s/scripts/deploy.sh"
