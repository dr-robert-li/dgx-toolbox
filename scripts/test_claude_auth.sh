#!/bin/bash
export ANTHROPIC_BASE_URL="http://localhost:11434"
export ANTHROPIC_AUTH_TOKEN="ollama"
export ANTHROPIC_API_KEY="ollama"
echo "Testing with both AUTH_TOKEN and API_KEY set to 'ollama'..."
claude --print "hello" 2>&1 | head -n 20

echo -e "\nTesting with AUTH_TOKEN='ollama' and API_KEY=''"
export ANTHROPIC_API_KEY=""
claude --print "hello" 2>&1 | head -n 20

echo -e "\nTesting with --bare flag and both set..."
export ANTHROPIC_API_KEY="ollama"
claude --bare --print "hello" 2>&1 | head -n 20
