#!/usr/bin/env bash
# SEEDED FOR TRAINING — DO NOT USE, DO NOT REMOVE WITHOUT UPDATING TRAINING_SEEDS.md
#
# Simulates a legacy integration script that (badly) hardcodes credentials
# instead of reading them from the environment. This is the GitLeaks lab
# seed for OrderFlow-Lite — see TRAINING_SEEDS.md at the repo root.
#
# The key below is a made-up, non-functional value shaped like a real AWS
# Access Key ID (AKIA + 16 alphanumeric characters) so it trips GitLeaks'
# aws-access-token rule. It deliberately does NOT use AWS's own published
# example key (AKIAIOSFODNN7EXAMPLE) — GitLeaks' default config allowlists
# any secret ending in "EXAMPLE" as a known placeholder, so that value
# never actually gets flagged. It is not a real, active credential.

AWS_ACCESS_KEY_ID="AKIATRAININGSEEDVALX"

echo "Notifying legacy webhook with access key ${AWS_ACCESS_KEY_ID}..."
