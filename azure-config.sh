#!/usr/bin/env bash
# ==============================================================================
# azure-config.sh
# ==============================================================================
#
# Single source of truth for the Azure OpenAI models LiteLLM serves to
# OpenClaw. Sourced by apply.sh and check_env.sh so every script agrees on one
# list, and exported into Terraform so the deploy cannot drift from what was
# validated.
#
# ------------------------------------------------------------------------------
# Why a list
# ------------------------------------------------------------------------------
# Each model used to be wired by hand in three places: a deployment resource
# in 01-core/ai.tf, a key in the openclaw-openai-config secret, and a block in
# custom_data.sh -- with the picker names in a fourth (09-openclaw-init.sh).
# CLAUDE.md and SYSTEM.md already listed gpt-5 and gpt-5-mini, which were
# never deployed. Everything now derives from the array below: the Azure
# OpenAI deployments, the LiteLLM model_list, the OpenClaw model picker, and
# the pre-flight checks. Any number of entries from 1 upward renders
# correctly.
#
# ------------------------------------------------------------------------------
# Unlike Bedrock and Vertex, a model must be DEPLOYED before it can be called
# ------------------------------------------------------------------------------
# 01-core creates one deployment per entry, named after its alias. A model can
# be listed in the regional catalog and still fail to deploy: wrong version,
# SKU not offered in this region, retired, or no quota for this subscription.
# check_env.sh runs probe_azure.py --check on every entry before anything is
# built, which checks all four.
#
# To see what this subscription can deploy here, and -- once 01-core exists --
# how fast each deployment answers:
#     ./probe_azure.py
#     ./probe_azure.py --check gpt-4.1:2025-04-14
#
# Two routes, chosen by format:
#   OpenAI   LiteLLM azure/<deployment> on the account's OpenAI endpoint.
#   others   (DeepSeek, Meta, Mistral, xAI, ...) LiteLLM openai/<deployment>
#            on the account's Foundry endpoint, /openai/v1 -- verified
#            2026-09-24 to answer chat completions for non-OpenAI
#            deployments with the account key.
# Anthropic (Claude) is not usable: Azure will not deploy it without your
# organization details.
#
# ------------------------------------------------------------------------------
# Format
# ------------------------------------------------------------------------------
#     "<alias>|<model>|<version>|<capacity>|<display name>[|<format>]"
#
#   alias     the deployment name, what LiteLLM routes on, and what OpenClaw
#             stores as the model id. Changing it repoints agents -- keep it
#             stable across version bumps.
#   model     the catalog model name, e.g. gpt-4.1 or DeepSeek-V4-Pro
#   version   the model version, e.g. 2025-04-14. This is the part that
#             retires; the probe shows each version's retirement date.
#   capacity  quota in thousands of tokens per minute (100 = 100K TPM),
#             drawn from this subscription's per-model regional quota.
#             Non-OpenAI models often have far less (DeepSeek: 20).
#   display   what a human sees in the OpenClaw model picker.
#   format    the catalog provider format, as ./probe_azure.py prints it.
#             Optional; defaults to OpenAI.
# ==============================================================================

# These are the two deployments 01-core/ai.tf created before this file existed,
# carried over unchanged so the move does not also change which models answer.
#
# Catalog check 2026-09-24 (eastus): both are offered, but both are "Legacy"
# and retire 2027-04-14. gpt-5.4 / gpt-5.4-mini / gpt-5.5 are GA with quota.
# Verify tool calling in the UI before promoting a new primary.
#
# gpt-6-sol and gpt-5.4-mini added 2026-09-24 from a --deploy probe run:
# both GA, both answered, quota 1000 each. Not yet verified to drive
# OpenClaw's tool calls -- try them in the UI before promoting either.
#
# Excluded deliberately:
#   DeepSeek-V4-Flash / -Pro   tried 2026-09-24. They answer a short prompt,
#                              but this subscription's quota is 20 each, and
#                              an OpenClaw agent turn is larger than that:
#                              Azure rejects it with "Your request exceeds
#                              the maximum usage size allowed during peak
#                              load". Re-add (format DeepSeek) after a quota
#                              increase to ~100.
AZURE_MODELS=(
  "gpt-4.1|gpt-4.1|2025-04-14|100|GPT-4.1"
  "gpt-4.1-nano|gpt-4.1-nano|2025-04-14|100|GPT-4.1 Nano"
  "gpt-6-sol|gpt-6-sol|2026-09-22|100|GPT-6 Sol"
  "gpt-5.4-mini|gpt-5.4-mini|2026-03-17|100|GPT-5.4 Mini"
)

# Alias agents default to. Must be one of the aliases above; check_env.sh and
# Terraform both reject a primary that is not in the list, because it yields an
# OpenClaw that starts fine and cannot run an agent.
AZURE_PRIMARY="gpt-4.1"

# Deployment SKU for every model. GlobalStandard routes across Azure regions
# and has the broadest model availability and the largest default quota.
AZURE_SKU="GlobalStandard"

# Region for all resources, in the short form the CLI and catalog use
# (eastus, not "East US"). Model availability and quota are per region.
export AZURE_LOCATION="${AZURE_LOCATION:-eastus}"


# ==============================================================================
# Helpers
# ==============================================================================

# JSON array of model objects, shaped for TF_VAR_models.
azure_models_json() {
  local entry alias model version capacity display format
  for entry in "${AZURE_MODELS[@]}"; do
    IFS='|' read -r alias model version capacity display format <<< "${entry}"
    jq -n \
      --arg alias    "${alias}" \
      --arg model    "${model}" \
      --arg version  "${version}" \
      --argjson capacity "${capacity}" \
      --arg display  "${display}" \
      --arg format   "${format:-OpenAI}" \
      '{alias: $alias, model: $model, version: $version,
        capacity: $capacity, display: $display, format: $format}'
  done | jq -s '.'
}

# "model:version:capacity", one per line -- what check_env.sh probes.
azure_model_checks() {
  local entry alias model version capacity
  for entry in "${AZURE_MODELS[@]}"; do
    IFS='|' read -r alias model version capacity _ <<< "${entry}"
    printf '%s:%s:%s\n' "${model}" "${version}" "${capacity}"
  done
}

# Aliases, one per line.
azure_model_aliases() {
  local entry
  for entry in "${AZURE_MODELS[@]}"; do
    printf '%s\n' "${entry}" | cut -d'|' -f1
  done
}

# Resolve an alias to its model name; non-zero if the alias is unknown.
azure_model_for_alias() {
  local want="$1" entry alias model
  for entry in "${AZURE_MODELS[@]}"; do
    IFS='|' read -r alias model _ <<< "${entry}"
    if [ "${alias}" = "${want}" ]; then
      printf '%s' "${model}"
      return 0
    fi
  done
  return 1
}

# Hand the list to Terraform. Called by apply.sh before 01-core and
# 03-openclaw -- 01-core creates the deployments, 03-openclaw renders the
# LiteLLM config and registers the picker entries from the same list.
azure_export_tf_vars() {
  TF_VAR_models="$(azure_models_json)"
  TF_VAR_primary_alias="${AZURE_PRIMARY}"
  TF_VAR_deployment_sku="${AZURE_SKU}"
  TF_VAR_location="${AZURE_LOCATION}"
  export TF_VAR_models TF_VAR_primary_alias TF_VAR_deployment_sku \
         TF_VAR_location
}
