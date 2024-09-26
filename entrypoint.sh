#!/bin/bash
set -euo pipefail

# Start Ollama
/bin/ollama serve &
pid=$!

# Wait for Ollama to be ready using Bash's built-in networking capabilities
while ! timeout 1 bash -c "echo > /dev/tcp/localhost/11434" 2>/dev/null; do
    echo "Waiting for Ollama to start..."
    sleep 1
done
echo "Ollama started."

# Retrieve and install/update models from the MODELS environment variable
IFS=',' read -ra model_array <<< "$MODELS"
for model in "${model_array[@]}"; do
    echo "Installing/Updating model $model..."
    ollama pull $model  # This command fetches the latest version of the model
done
echo "All models installed/updated."

# Continue to main process
wait $pid
