#!/bin/bash
# Bootstrap script for flutter-sdk (Flutter/Dart)
set -e

echo "Bootstrapping flutter-sdk..."

# Install tools via mise (Flutter)
mise install

# Copy .env.sample to .env if it exists and .env doesn't
if [ -f ".env.sample" ] && [ ! -f ".env" ]; then
  cp .env.sample .env
  echo "Created .env from .env.sample"
fi

# Get Flutter dependencies
flutter pub get

echo "Done! Flutter SDK is ready."
