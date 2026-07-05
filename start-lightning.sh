#!/usr/bin/env bash
# ============================================================
# Day 3 one-time SETUP bootstrap (Linux, NO sudo, NO Docker, NO Polar).
# Designed specifically for GitHub Codespaces with /workspaces/Bitcoin2
# ============================================================
set -u

BIN_DIR="/workspaces/Bitcoin2/.local/bin"
WORK="/workspaces/Bitcoin2/bootcamp-lnd"
DATA_DIR="/workspaces/Bitcoin2/.bitcoin"
LND_VERSION="v0.18.5-beta"
BTC_VERSION="28.1"
RPCUSER="bootcamp"; RPCPASS="bootcamp123"

say()  { echo; echo ">> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$BIN_DIR" "$WORK" "$DATA_DIR"
export PATH="$BIN_DIR:$PATH"

# ------------------------------------------------------------
# 1. Binaries in Codespaces path (download only if missing)
# ------------------------------------------------------------
arch() { case "$(uname -m)" in
  x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; esac; }

if ! have bitcoind; then
  say "Downloading Bitcoin Core $BTC_VERSION"
  case "$(arch)" in amd64) BA=x86_64-linux-gnu ;; arm64) BA=aarch64-linux-gnu ;; esac
  curl -fsSL "https://bitcoincore.org/bin/bitcoin-core-${BTC_VERSION}/bitcoin-${BTC_VERSION}-${BA}.tar.gz" \
    | tar -xz -C /tmp
  cp "/tmp/bitcoin-${BTC_VERSION}/bin/bitcoind" "/tmp/bitcoin-${BTC_VERSION}/bin/bitcoin-cli" "$BIN_DIR/"
fi
if ! have lnd; then
  say "Downloading LND $LND_VERSION"
  curl -fsSL "https://github.com/lightningnetwork/lnd/releases/download/${LND_VERSION}/lnd-linux-$(arch)-${LND_VERSION}.tar.gz" \
    | tar -xz -C /tmp
  cp /tmp/lnd-linux-*/lnd /tmp/lnd-linux-*/lncli "$BIN_DIR/"
fi
echo "   bitcoind: $(command -v bitcoind)"
echo "   lnd:      $(command -v lnd)"

# Helper macro for bitcoin-cli to ensure it targets the Codespaces folder
bcli() { bitcoin-cli -datadir="$DATA_DIR" -regtest "$@"; }

# ------------------------------------------------------------
# 2. Complete bitcoin.conf written to /workspaces/Bitcoin2/.bitcoin
# ------------------------------------------------------------
say "Writing bitcoin.conf"
cat > "$DATA_DIR/bitcoin.conf" <<EOF
regtest=1
server=1
daemon=1
txindex=1
fallbackfee=0.0001
dbcache=100
maxmempool=50
rpcuser=$RPCUSER
rpcpassword=$RPCPASS
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333

[regtest]
rpcport=18443
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
EOF

# ------------------------------------------------------------
# 3. Start bitcoind and wait for RPC
# ------------------------------------------------------------
if ! bcli getblockchaininfo >/dev/null 2>&1; then
  say "Starting bitcoind"
  nohup bitcoind -datadir="$DATA_DIR" >"$WORK/bitcoind.log" 2>&1 &
fi
i=0; until bcli getblockchaininfo >/dev/null 2>&1; do
  i=$((i+1)); [ $i -gt 30 ] && { echo "bitcoind did not start" >&2; exit 1; }; sleep 1
done
echo "   bitcoind up, chain=$(bcli getblockchaininfo | grep -o '"chain": "[a-z]*"')"

# Set up 'alice' mining wallet; generate blocks to mature coinbase
bcli createwallet alice >/dev/null 2>&1 || bcli loadwallet alice >/dev/null 2>&1
FUND_ADDR=$(bcli -rpcwallet=alice getnewaddress)
MATURE=$(bcli -rpcwallet=alice getbalance)
if [ "$(echo "$MATURE" | awk '{print ($1>=50)?1:0}')" != 1 ]; then
  bcli -rpcwallet=alice generatetoaddress 101 "$FUND_ADDR" >/dev/null
fi
echo "   bitcoind alice wallet: $(bcli -rpcwallet=alice getbalance) BTC"

# ------------------------------------------------------------
# 4. LND configs for alice and bob
# ------------------------------------------------------------
write_lnd_conf() { # $1=dir $2=alias $3=p2p $4=rpc $5=rest
  mkdir -p "$WORK/$1"
  cat > "$WORK/$1/lnd.conf" <<EOF
[Application Options]
listen=127.0.0.1:$3
rpclisten=localhost:$4
restlisten=127.0.0.1:$5
alias=$2
[Bitcoin]
bitcoin.active=true
bitcoin.regtest=true
bitcoin.node=bitcoind
[Bitcoind]
bitcoind.rpchost=127.0.0.1:18443
bitcoind.rpcuser=$RPCUSER
bitcoind.rpcpass=$RPCPASS
bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333
EOF
}
say "Writing alice + bob lnd.conf under $WORK"
write_lnd_conf alice Alice 9735 10001 8081
write_lnd_conf bob   Bob   9736 10002 8082

# ------------------------------------------------------------
# 5. Start both LND nodes
# ------------------------------------------------------------
start_node() { # $1=dir
  if ! pgrep -f "lnd --lnddir=$WORK/$1" >/dev/null 2>&1; then
    nohup lnd --lnddir="$WORK/$1" --noseedbackup >"$WORK/$1.log" 2>&1 &
  fi
}
lcli() { lncli --network=regtest --lnddir="$WORK/$1" --rpcserver="localhost:$2" "${@:3}"; }

say "Starting alice + bob LND nodes"
start_node alice
start_node bob

waitsync() { # $1=dir $2=port $3=label
  local i=0
  until [ "$(lcli "$1" "$2" getinfo 2>/dev/null | grep -o '"synced_to_chain": true')" ]; do
    i=$((i+1))
    if [ $i -gt 90 ]; then
      echo "   $3 did not sync; last log lines:" >&2; tail -15 "$WORK/$1.log" >&2; exit 1
    fi
    sleep 1
  done
  echo "   $3 synced_to_chain=true"
}
waitsync alice 10001 alice
waitsync bob   10002 bob

# ------------------------------------------------------------
# 6. Fund alice's LND wallet, then open alice -> bob channel
# ------------------------------------------------------------
CHAN_AMT=1000000
if [ "$(lcli alice 10001 listchannels | grep -o '"active": true' | head -1)" ]; then
  say "Channel already open -- skipping funding/open"
else
  say "Funding alice's LND wallet (1 BTC) and opening a ${CHAN_AMT}-sat channel"
  ALICE_ADDR=$(lcli alice 10001 newaddress p2wkh | grep '"address"' | cut -d'"' -f4)
  bcli -rpcwallet=alice sendtoaddress "$ALICE_ADDR" 1 >/dev/null
  bcli -rpcwallet=alice generatetoaddress 6 "$FUND_ADDR" >/dev/null
  sleep 3

  BOB_PUBKEY=$(lcli bob 10002 getinfo | grep '"identity_pubkey"' | cut -d'"' -f4)
  lcli alice 10001 connect "$BOB_PUBKEY@127.0.0.1:9736" >/dev/null 2>&1 || true
  lcli alice 10001 openchannel --node_key="$BOB_PUBKEY" --local_amt="$CHAN_AMT" >/dev/null
  bcli -rpcwallet=alice generatetoaddress 6 "$FUND_ADDR" >/dev/null
  sleep 4
fi

# ------------------------------------------------------------
# 7. Verify + print how to continue
# ------------------------------------------------------------
ACTIVE=$(lcli alice 10001 listchannels | grep -o '"active": true' | head -1)
CAP=$(lcli alice 10001 listchannels | grep '"capacity"' | head -1 | grep -o '[0-9]\+')
if [ -z "$ACTIVE" ]; then
  echo; echo "XX  Channel is not active yet. Run: bitcoin-cli -datadir=$DATA_DIR -regtest -rpcwallet=alice generatetoaddress 6 \"$FUND_ADDR\"  then re-run this script." >&2
  exit 1
fi

# Write localized context file for the students
cat > "$WORK/aliases.sh" <<EOF
export PATH="$BIN_DIR:\$PATH"
alias bitcoin-cli="bitcoin-cli -datadir=$DATA_DIR"
alias alice="lncli --network=regtest --lnddir=$WORK/alice --rpcserver=localhost:10001"
alias bob="lncli --network=regtest --lnddir=$WORK/bob --rpcserver=localhost:10002"
MINER=$FUND_ADDR
EOF

cat <<EOF

============================================================
  SUCCESS: alice <-> bob channel is OPEN and ACTIVE
           capacity = ${CAP} sats
============================================================

bitcoind + both LND nodes are running in the background.

To use them in THIS or any new terminal:
    source $WORK/aliases.sh

Then try:
    alice listchannels        # see the open channel
    bob  getinfo              # Bob's node info
    bitcoin-cli -regtest -rpcwallet=alice generatetoaddress 6 "\$MINER"  # mine blocks

You're at the Day 3 starting line. Continue with the slides
(invoices, payments, routing) using the alice / bob
EOF
