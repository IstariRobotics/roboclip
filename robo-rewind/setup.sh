#!/bin/bash
# setup.sh - Setup script for robo-rewind
# Usage: source setup.sh OR ./setup.sh

set -e

cd "$(dirname "$0")"

# Check if the script is sourced or executed
if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
    echo "Error: Please source this script instead of executing it."
    echo "Usage: source setup.sh"
    exit 1
fi

# Verify Python version
if ! python3 --version &>/dev/null; then
    echo "Error: Python3 is not installed. Please install Python3 and try again."
    return 1
fi

# Ensure we have a virtual environment; create and activate if needed
if [[ "$VIRTUAL_ENV" == "" ]]; then
    if [ ! -d "venv" ]; then
        echo "Creating virtual environment..."
        python3 -m venv venv
        echo "Virtual environment created."
    fi
    # Activate the newly created or existing venv
    source venv/bin/activate
fi

# Ensure pip is up-to-date inside the venv
python3 -m pip install --upgrade pip

# Install dependencies
python3 -m pip install -r requirements.txt

echo "Dependencies installed and virtual environment is ready."
echo "[robo-rewind] venv activated and dependencies installed."
echo "To visualize IMU data with rerun.io, run: python3 replay_local_data.py"
