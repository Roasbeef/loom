#!/usr/bin/env bash
# mint-fixture.sh: mint a throwaway orchestrator/executor pair with plain
# openssl, for tests and smoke runs.
#
# This is a test fixture, not the operator's provisioning path. Operators run
# `loom distribution provision`, which writes one `.loombundle` per node.
# This script writes the same material in the layout those bundles install to,
# so a smoke run can boot a pair before, or without, the provision command.
#
# Usage:
#   mint-fixture.sh OUT ORCH_NODE ORCH_HOME EXEC_NODE EXEC_HOME WS_NAME WS_ROOT
#
# Each node gets a "home overlay" under OUT/<role>/home/ whose paths already
# assume the daemon will run with HOME=<that node's HOME argument>:
#
#   home/.erlang.cookie                      mode 0600, 32 characters
#   home/.loom/loom.toml                     [distribution] and the role table
#   home/.loom/distribution/{ca,cert,key}.pem
#
# Copy the overlay onto the real HOME (or, for a local test, pass the overlay
# itself as HOME), then render the options file and start the daemon:
#
#   loomd distribution options $HOME/.loom/loom.toml $HOME/.loom/distribution.options
#   LOOM_DISTRIBUTION_OPTFILE=$HOME/.loom/distribution.options bin/loomd \
#     --config $HOME/.loom/loom.toml ...
#
# Environment:
#   ORCH_LISTEN_PORT, EXEC_LISTEN_PORT  pin the distribution listener (optional).
#   EXEC_NAME     the [executors.<name>] key on the orchestrator (default box).
#   WORKSPACES    yes, no or auto. The executor's [workspaces.<name>] table is
#                 written when yes. auto looks for the key in
#                 docs/configuration.md, so the fixture works on a tree that
#                 has not got the executor role yet (default auto).
#
# Nothing private is printed. The CA key is deleted once both leaves are signed.
set -euo pipefail

if [ "$#" -ne 7 ]; then
	sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1 >&2
	exit 64
fi
out=$1
orch_node=$2
orch_home=$3
exec_node=$4
exec_home=$5
ws_name=$6
ws_root=$7
exec_name=${EXEC_NAME:-box}

root="$(cd "$(dirname "$0")/../.." && pwd)"
workspaces=${WORKSPACES:-auto}
if [ "$workspaces" = auto ]; then
	if grep -q '^## `\[workspaces' "$root/docs/configuration.md"; then
		workspaces=yes
	else
		workspaces=no
	fi
fi

for n in "$orch_node" "$exec_node"; do
	case $n in
	*@*.* | *@[0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
	*)
		echo "mint-fixture: node name needs name@host with a dot in the host: $n" >&2
		exit 64
		;;
	esac
done
case $orch_home$exec_home$ws_root in
/*) ;;
*)
	echo "mint-fixture: homes and the workspace root must be absolute paths" >&2
	exit 64
	;;
esac
if [ -e "$out" ]; then
	echo "mint-fixture: $out already exists; refusing to overwrite" >&2
	exit 73
fi

umask 077
mkdir -p "$out"
work=$(mktemp -d "$out/.mint.XXXXXX")
trap 'rm -rf "$work"' EXIT

# A certificate authority that signs exactly the two leaves below.
cat >"$work/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ca
prompt = no
[dn]
CN = loom-fixture-ca
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
EOF
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
	-days 30 -sha256 -config "$work/ca.cnf" \
	-keyout "$work/ca.key" -out "$work/ca.pem" 2>/dev/null

# The leaf carries the exact node name as a DNS name (the distribution pin
# check requires that), plus the host part as a DNS name or an IP address for
# the TLS host name check. Both client and server auth are needed, because
# each side of a distribution connection plays both parts.
leaf() {
	local label=$1 node=$2
	local host=${node#*@}
	local host_san="DNS:$host"
	case $host in
	*[!0-9.]*) ;;
	*) host_san="IP:$host" ;;
	esac
	cat >"$work/$label.ext" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = DNS:$node,$host_san
EOF
	openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
		-sha256 -subj "/CN=$node" \
		-keyout "$work/$label.key" -out "$work/$label.csr" 2>/dev/null
	openssl x509 -req -in "$work/$label.csr" -CA "$work/ca.pem" \
		-CAkey "$work/ca.key" -CAcreateserial -days 30 -sha256 \
		-extfile "$work/$label.ext" -out "$work/$label.pem" 2>/dev/null
}
leaf orchestrator "$orch_node"
leaf executor "$exec_node"

# The leaf's pin is the SHA-256 of its DER encoding.
pin() {
	openssl x509 -in "$work/$1.pem" -outform DER | openssl dgst -sha256 | awk '{print $NF}'
}
orch_pin=$(pin orchestrator)
exec_pin=$(pin executor)

# One cookie for the whole deployment, no trailing newline.
cookie=$(openssl rand -hex 16)

overlay() {
	local label=$1 home=$2
	local dir="$out/$label/home/.loom/distribution"
	mkdir -p "$dir"
	cp "$work/ca.pem" "$dir/ca.pem"
	cp "$work/$label.pem" "$dir/cert.pem"
	cp "$work/$label.key" "$dir/key.pem"
	chmod 0600 "$dir/key.pem"
	chmod 0644 "$dir/ca.pem" "$dir/cert.pem"
	printf '%s' "$cookie" >"$out/$label/home/.erlang.cookie"
	chmod 0600 "$out/$label/home/.erlang.cookie"
}
overlay orchestrator "$orch_home"
overlay executor "$exec_home"

# The [distribution] table. The cookie path is the daemon's own
# $HOME/.erlang.cookie, which the VM insists on.
table() {
	local node=$1 home=$2 port=$3 peer_node=$4 peer_pin=$5
	cat <<EOF
[distribution]
node = "$node"
ca = "$home/.loom/distribution/ca.pem"
certificate = "$home/.loom/distribution/cert.pem"
key = "$home/.loom/distribution/key.pem"
cookie = "$home/.erlang.cookie"
EOF
	if [ -n "$port" ]; then
		printf 'listen_port = %s\n' "$port"
	fi
	cat <<EOF

[[distribution.peers]]
node = "$peer_node"
sha256 = "$peer_pin"
EOF
}

{
	table "$orch_node" "$orch_home" "${ORCH_LISTEN_PORT:-}" "$exec_node" "$exec_pin"
	printf '\n[executors.%s]\nnode = "%s"\n' "$exec_name" "$exec_node"
} >"$out/orchestrator/home/.loom/loom.toml"

{
	table "$exec_node" "$exec_home" "${EXEC_LISTEN_PORT:-}" "$orch_node" "$orch_pin"
	if [ "$workspaces" = yes ]; then
		printf '\n[workspaces.%s]\nroot = "%s"\n' "$ws_name" "$ws_root"
	fi
} >"$out/executor/home/.loom/loom.toml"

echo "mint-fixture: wrote $out/orchestrator/home and $out/executor/home (workspaces: $workspaces)"
