#!/usr/bin/env bash
# Deploys the canonical RigoBlock fee infra (RigoBlockDeployer -> TokenJar + Firepit)
# on HyperEVM (chain 999), immune to forge/solc metadata drift.
#
# Why this script exists:
#   CREATE2 addresses depend on the exact initcode bytes, whose trailing CBOR
#   metadata embeds the local remappings. Recompiling with a newer forge
#   produces different metadata -> different addresses (this already happened
#   on HyperEVM: 0x0d38d8F0... instead of the canonical 0x8fe2051B...).
#   This script never compiles: it reuses the byte-identical initcode recorded
#   in the broadcast of a chain where the canonical deployment happened.
#
# Usage:
#   source .env
#   ./script/shell/deploy-canonical-hyperliquid.sh                # prompt for key (--interactive)
#   ./script/shell/deploy-canonical-hyperliquid.sh --dry-run      # simulate only, no txs
#   ./script/shell/deploy-canonical-hyperliquid.sh --rpc-url <url>
#
# Idempotent: each step is skipped if already done on-chain.
set -euo pipefail

DRY_RUN=false
RPC_URL="${HYPEREVM_RPC_URL:-}"
BROADCAST="broadcast/05_DeployRigoblock.s.sol/56/run-latest.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --rpc-url) RPC_URL="$2"; shift 2 ;;
    --broadcast) BROADCAST="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
lc() { tr 'A-F' 'a-f' <<< "$1"; }

# .env is typically sourced without `export`, so child processes can't see the
# variables. Source it here with export enabled if the RPC url is still missing.
if [[ -z "$RPC_URL" && -f .env ]]; then
  set -a; source .env; set +a
  RPC_URL="${HYPEREVM_RPC_URL:-}"
fi

[[ -n "$RPC_URL" ]] || fail "set HYPEREVM_RPC_URL or pass --rpc-url"

# --- constants (canonical across all chains) ---------------------------------
PROXY="0x4e59b44847b379578588920ca78fbf26c0b4956c"   # canonical CREATE2 factory
DEPLOYER="0x8fe2051B8107192D695449Cf2b002C2EcB479832" # canonical RigoBlockDeployer
EXPECTED_JAR="0xA0F9C380ad1E1be09046319fd907335B2B452B37"
EXPECTED_FIREPIT="0x28d2cd73d6f3A7cC7E302F093fD9Dd3a4149CD66"
GRG="0x78118293A39B6338bfC2e68fb54ef8282938D56d"       # HyperEVM GRG
OWNER="0x002BA2351532a741043d874Bd0b12aAb21abc289"     # governance
MIN_THRESHOLD="50000000000000000000"                   # 50e18
CHAIN_ID=999

SALT="0x$(printf '0%.0s' $(seq 29))524947"             # bytes32: 29 zero bytes + "RIG"
ZERO="0x0000000000000000000000000000000000000000"

code_size() { cast code "$1" --rpc-url "$RPC_URL" | tr -d '0x' | wc -c; }

[[ "$(cast chain-id --rpc-url "$RPC_URL")" == "$CHAIN_ID" ]] || fail "RPC is not HyperEVM (chain id != $CHAIN_ID)"

# --- 1. harvest canonical initcode from a canonical-chain broadcast -----------
[[ -f "$BROADCAST" ]] || fail "broadcast file not found: $BROADCAST"
INITCODE_FILE="$(mktemp)"
jq -r '.transactions[] | select(.transactionType=="CREATE2" and .contractName=="RigoBlockDeployer") | .transaction.input' "$BROADCAST" \
  | cut -c67- > "$INITCODE_FILE"
[[ "$(wc -c < "$INITCODE_FILE")" -gt 100 ]] || fail "could not extract RigoBlockDeployer initcode from $BROADCAST"
echo ">> harvested canonical initcode ($(wc -c < "$INITCODE_FILE") hex chars) from $BROADCAST"

[[ "$(code_size "$PROXY")" -gt 2 ]] || fail "canonical factory $PROXY not deployed on this chain"

# --- 2. deploy canonical RigoBlockDeployer if absent ---------------------------
if [[ "$(code_size "$DEPLOYER")" -le 2 ]]; then
  echo ">> deploying canonical RigoBlockDeployer via factory (salt 0x...524947)"
  if ! $DRY_RUN; then
    cast send "$PROXY" "0x${SALT#0x}$(cat "$INITCODE_FILE")" \
      --rpc-url "$RPC_URL" --interactive
  fi
  [[ "$(code_size "$DEPLOYER")" -gt 2 ]] || fail "deployer missing after send"
else
  echo ">> canonical deployer $DEPLOYER already deployed, skipping factory step"
fi

# sanity: the contract at the canonical address must be RigoBlockDeployer
JAR_RAW="$(cast call "$DEPLOYER" "tokenJar()(address)" --rpc-url "$RPC_URL")" \
  || fail "$DEPLOYER has code but is not RigoBlockDeployer (tokenJar() reverted). Aborting."

# --- 3. deploy TokenJar + Firepit via deployContracts --------------------------
if [[ "$(lc "$JAR_RAW")" == "$ZERO" ]]; then
  echo ">> calling deployContracts(resource, minThreshold, owner) — dry-run trace first:"
  TRACE="$(cast call "$DEPLOYER" "deployContracts(address,uint256,address)" "$GRG" "$MIN_THRESHOLD" "$OWNER" \
      --rpc-url "$RPC_URL" --trace 2>&1)"
  echo "$TRACE" | grep -E "new .*@0x" || fail "dry-run produced no contract creations"
  echo "$TRACE" | grep -qi "$EXPECTED_JAR" || fail "dry-run TokenJar != $EXPECTED_JAR"
  echo "$TRACE" | grep -qi "$EXPECTED_FIREPIT" || fail "dry-run Firepit != $EXPECTED_FIREPIT"
  echo ">> dry-run OK: jar=$EXPECTED_JAR firepit=$EXPECTED_FIREPIT"

  if ! $DRY_RUN; then
    cast send "$DEPLOYER" "deployContracts(address,uint256,address)" "$GRG" "$MIN_THRESHOLD" "$OWNER" \
      --rpc-url "$RPC_URL" --interactive
  fi
else
  echo ">> deployContracts already executed (tokenJar=$JAR_RAW), skipping"
fi

# --- 4. verify on-chain state --------------------------------------------------
JAR="$(cast call "$DEPLOYER" "tokenJar()(address)" --rpc-url "$RPC_URL")"
PIT="$(cast call "$DEPLOYER" "firepit()(address)" --rpc-url "$RPC_URL")"
if $DRY_RUN && [[ "$(lc "$JAR")" == "$ZERO" ]]; then
  echo ">> dry-run only: deployContracts not sent, skipping on-chain state verification"
  rm -f "$INITCODE_FILE"
  exit 0
fi
[[ "$(lc "$JAR")" == "$(lc "$EXPECTED_JAR")" ]] || fail "on-chain TokenJar mismatch: $JAR"
[[ "$(lc "$PIT")" == "$(lc "$EXPECTED_FIREPIT")" ]] || fail "on-chain Firepit mismatch: $PIT"

check() { # check <label> <actual> <expected>
  [[ "$(lc "$2")" == "$(lc "$3")" ]] \
    && echo "   ok: $1 = $2" || fail "$1 mismatch: got $2, want $3"
}
echo ">> verifying configuration:"
check "jar.releaser()"       "$(cast call "$EXPECTED_JAR"    'releaser()(address)'        --rpc-url "$RPC_URL")" "$PIT"
check "jar.owner()"          "$(cast call "$EXPECTED_JAR"    'owner()(address)'           --rpc-url "$RPC_URL")" "$OWNER"
check "firepit.owner()"      "$(cast call "$EXPECTED_FIREPIT" 'owner()(address)'           --rpc-url "$RPC_URL")" "$OWNER"
check "firepit.thresholdSetter()" "$(cast call "$EXPECTED_FIREPIT" 'thresholdSetter()(address)' --rpc-url "$RPC_URL")" "$OWNER"
check "firepit.RESOURCE()"   "$(cast call "$EXPECTED_FIREPIT" 'RESOURCE()(address)'        --rpc-url "$RPC_URL")" "$GRG"
check "firepit.TOKEN_JAR()"  "$(cast call "$EXPECTED_FIREPIT" 'TOKEN_JAR()(address)'       --rpc-url "$RPC_URL")" "$EXPECTED_JAR"

echo
echo "== HyperEVM deployment complete and verified. Update deployments.toml:"
cat <<EOF

[hyperliquid.address]
grg = "$GRG"
deployer = "$DEPLOYER"
token_jar = "$EXPECTED_JAR"
firepit = "$EXPECTED_FIREPIT"
EOF

rm -f "$INITCODE_FILE"
