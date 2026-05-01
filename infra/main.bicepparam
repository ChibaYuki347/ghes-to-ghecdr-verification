using 'main.bicep'

// SSH public key is read from environment variable GHES_SSH_PUBLIC_KEY at deployment time.
// scripts/02-deploy.sh exports this from $SSH_PUBLIC_KEY_PATH (default ~/.ssh/ghestest_id_ed25519.pub).
// If the env var is unset or empty, Bicep parameter validation will fail with `minLength: 80`.
param sshPublicKey = readEnvironmentVariable('GHES_SSH_PUBLIC_KEY')

// Optional overrides via environment variables (uncomment as needed):
// param location = readEnvironmentVariable('LOCATION', 'japaneast')
// param resourceGroupName = readEnvironmentVariable('RG_NAME', 'rg-ghestest-jpe')
// param namePrefix = readEnvironmentVariable('NAME_PREFIX', 'ghestest')
