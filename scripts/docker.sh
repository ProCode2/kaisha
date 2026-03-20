#!/bin/bash
set -e

IMAGE="kaisha-server"
PORT=8420

case "${1:-build}" in
  build)
    echo "Cross-compiling kaisha-server for Linux ARM64..."
    zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall
    echo "Building Docker image..."
    docker build -t $IMAGE .
    echo "Done. Run: $0 run"
    ;;
  run)
    if [ -z "$LYZR_API_KEY" ]; then
      echo "Error: LYZR_API_KEY not set"
      exit 1
    fi
    echo "Starting $IMAGE on port $PORT..."
    docker run --rm -p $PORT:$PORT -e LYZR_API_KEY="$LYZR_API_KEY" $IMAGE
    ;;
  restart)
    echo "Stopping existing container..."
    docker stop $(docker ps -q --filter ancestor=$IMAGE) 2>/dev/null || true
    $0 build
    $0 run
    ;;
  rebuild)
    $0 build
    ;;
  stop)
    echo "Stopping..."
    docker stop $(docker ps -q --filter ancestor=$IMAGE) 2>/dev/null || true
    ;;
  logs)
    docker logs -f $(docker ps -q --filter ancestor=$IMAGE)
    ;;
  *)
    echo "Usage: $0 {build|run|restart|rebuild|stop|logs}"
    ;;
esac
