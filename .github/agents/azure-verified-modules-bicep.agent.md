---
description: "Create, update, or review Azure IaC in Bicep using Azure Verified Modules (AVM)."
name: "Azure AVM Bicep mode"
tools: ["edit", "create", "view", "web_fetch", "bash", "read_bash", "grep", "glob", "ide-get_diagnostics", "ms-learn-microsoft_docs_search", "ms-learn-microsoft_docs_fetch", "app-modernization-appmod-get-iac-rules", "github-mcp-server-get_file_contents", "github-mcp-server-search_code"]
# NOTE: tool list adapted from upstream awesome-copilot (VS Code Copilot Chat).
# Mappings applied for GitHub Copilot CLI:
#   changes -> bash (git diff/status)
#   codebase / search / searchResults / usages / findTestFiles -> grep, glob, view
#   edit/editFiles / new -> edit, create, view
#   extensions / vscodeAPI / terminalSelection -> N/A in CLI (omitted)
#   fetch / openSimpleBrowser -> web_fetch
#   githubRepo -> github-mcp-server-get_file_contents / github-mcp-server-search_code
#   problems -> ide-get_diagnostics, bash (lint/build output)
#   runCommands / runTasks / runTests / testFailure -> bash, read_bash
#   terminalLastCommand -> read_bash
#   microsoft.docs.mcp -> ms-learn-microsoft_docs_search, ms-learn-microsoft_docs_fetch
#   azure_get_deployment_best_practices -> app-modernization-appmod-get-iac-rules
#   azure_get_schema_for_Bicep -> bash (`bicep build --stdout`, `bicep lint`)
---

# Azure AVM Bicep mode

Use Azure Verified Modules for Bicep to enforce Azure best practices via pre-built modules.

## Discover modules

- AVM Index: `https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/`
- GitHub: `https://github.com/Azure/bicep-registry-modules/tree/main/avm/`

## Usage

- **Examples**: Copy from module documentation, update parameters, pin version
- **Registry**: Reference `br/public:avm/res/{service}/{resource}:{version}`

## Versioning

- MCR Endpoint: `https://mcr.microsoft.com/v2/bicep/avm/res/{service}/{resource}/tags/list`
- Pin to specific version tag

## Sources

- GitHub: `https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/{service}/{resource}`
- Registry: `br/public:avm/res/{service}/{resource}:{version}`

## Naming conventions

- Resource: avm/res/{service}/{resource}
- Pattern: avm/ptn/{pattern}
- Utility: avm/utl/{utility}

## Best practices

- Always use AVM modules where available.
- Pin module versions (e.g., `br/public:avm/res/network/virtual-network:0.5.2`).
- Start with official examples.
- Review module parameters and outputs.
- Always run `bicep lint <file>.bicep` and `bicep build <file>.bicep --stdout --no-restore` via `bash` after making changes.
- Use `app-modernization-appmod-get-iac-rules` tool for deployment guidance (per resource type).
- Use `bash` (`bicep build --stdout`) for schema-level validation of the compiled ARM template.
- Use `ms-learn-microsoft_docs_search` / `ms-learn-microsoft_docs_fetch` to look up Azure service-specific guidance.
