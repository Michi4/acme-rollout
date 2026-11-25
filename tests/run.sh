#!/bin/sh
# Regression tests for the host-side scripts and the deploy hook. No network,
# no docker, no SSH: everything external is stubbed.
#
#   sh tests/run.sh
#
# Every test works on a fresh copy of the repository in a temporary directory,
# so nothing here touches acme/, config/ or .env of the checkout.
set -u

repo=$(cd "$(dirname "$0")/.." && pwd)
pass=0
fail=0
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}

bad() {
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$1"
    [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/     /'
}

# A throwaway checkout with stubbed docker/dig/ssh-keygen/ssh.
sandbox() {
    dir=$work/$1
    mkdir -p "$dir/bin"
    # The checkout may be a live deployment: leave its certificate specs, group
    # files, host keys, acme-dns credentials and keys out, then restore only the
    # tracked examples. Otherwise the "empty tree" cases see real data.
    (cd "$repo" && tar -cf - \
        --exclude=.git --exclude=acme \
        --exclude='./config/groups/*.txt' \
        --exclude='./config/certs/*.conf' \
        --exclude='./config/known_hosts' \
        --exclude='./config/acme-dns' \
        --exclude='./keys/*' .) | (cd "$dir" && tar -xf -)
    for f in config/certs/example.conf config/groups/web.txt config/groups/edge.txt keys/README.md; do
        [ -f "$repo/$f" ] || continue
        mkdir -p "$dir/${f%/*}"
        cp "$repo/$f" "$dir/$f"
    done
    printf 'ACMEDNS_BASE_URL=https://auth.example.com\n' > "$dir/.env"
    printf '#!/bin/sh\nexit 0\n' > "$dir/bin/docker"
    printf '#!/bin/sh\nexit 0\n' > "$dir/bin/ssh"
    printf '#!/bin/sh\necho e74ef744.auth.example.com.\n' > "$dir/bin/dig"
    printf '#!/bin/sh\nexit 0\n' > "$dir/bin/ssh-keygen"
    chmod +x "$dir/bin/docker" "$dir/bin/ssh" "$dir/bin/dig" "$dir/bin/ssh-keygen"
    mkdir -p "$dir/config/certs" "$dir/config/groups" "$dir/config/acme-dns" \
        "$dir/acme/deploy-state" "$dir/keys"
    printf 'k' > "$dir/keys/acme_ed25519"
    printf 'h' > "$dir/config/known_hosts"
    printf '%s\n' "$dir"
}

run_in() {
    dir=$1
    shift
    (cd "$dir" && PATH="$dir/bin:$PATH" "$@")
}

# --- spec parsing ----------------------------------------------------------

d=$(sandbox spec)
cat > "$d/config/certs/example.net.conf" <<'EOF'
# leading comment
domain=example.net          # trailing comment
wildcard=0
hosts=example.net, web1.example.net
group=net
name='example.net'
EOF
out=$(run_in "$d" sh -c '. ./scripts/lib.sh; spec_get config/certs/example.net.conf domain')
[ "$out" = example.net ] && ok "spec_get strips trailing comment" || bad "spec_get domain" "$out"
out=$(run_in "$d" sh -c '. ./scripts/lib.sh; spec_get config/certs/example.net.conf name')
[ "$out" = example.net ] && ok "spec_get strips quotes" || bad "spec_get quoted value" "$out"
out=$(run_in "$d" sh -c '. ./scripts/lib.sh; spec_cert config/certs/example.net.conf')
[ "$out" = example.net ] && ok "spec_cert honours wildcard=0" || bad "spec_cert wildcard=0" "$out"
out=$(run_in "$d" sh -c '. ./scripts/lib.sh; cert_slug "*.example.net"')
[ "$out" = wildcard.example.net ] && ok "cert_slug maps the wildcard" || bad "cert_slug" "$out"
out=$(run_in "$d" sh -c '. ./scripts/lib.sh; cert_base "*.example.net"')
[ "$out" = example.net ] && ok "cert_base strips the wildcard" || bad "cert_base" "$out"
out=$(run_in "$d" sh -c '. ./scripts/lib.sh; slug_cert "wildcard.example.net"')
[ "$out" = '*.example.net' ] && ok "slug_cert reverses the wildcard slug" || bad "slug_cert" "$out"

# --- remove.sh -------------------------------------------------------------

d=$(sandbox remove)
cat > "$d/config/certs/hahnenkamm.conf" <<'EOF'
domain=hahnenkamm.com
wildcard=1
hosts=hahnenkamm.com one.hahnenkamm.com two.hahnenkamm.com
group=hahnenkamm
EOF
cat > "$d/config/certs/plain.conf" <<'EOF'
domain=example.net
wildcard=0
hosts=example.net
group=plain
EOF
mkdir -p "$d/acme/*.hahnenkamm.com" "$d/acme/deploy-state/wildcard.hahnenkamm.com"
printf 'x' > "$d/acme/*.hahnenkamm.com/*.hahnenkamm.com.conf"
printf '1 1 0\n' > "$d/acme/deploy-state/wildcard.hahnenkamm.com/one.hahnenkamm.com_22"
printf '# *.hahnenkamm.com on 3 host(s), from config/certs/hahnenkamm.conf\nhahnenkamm.com\none.hahnenkamm.com\ntwo.hahnenkamm.com\n' \
    > "$d/config/groups/hahnenkamm.txt"

out=$(run_in "$d" ./scripts/remove.sh '*.hahnenkamm.com' --check)
case "$out" in
    *"== check only, nothing changed"*) ok "remove --check prints a plan" ;;
    *) bad "remove --check plan" "$out" ;;
esac
[ -f "$d/config/certs/hahnenkamm.conf" ] && ok "remove --check keeps the spec" || bad "remove --check deleted the spec"
[ -f "$d/acme/deploy-state/wildcard.hahnenkamm.com/one.hahnenkamm.com_22" ] ||
    bad "remove --check touched deploy state"

out=$(run_in "$d" ./scripts/remove.sh '*.hahnenkamm.com' --keep-spec)
[ -f "$d/config/certs/hahnenkamm.conf" ] && ok "remove --keep-spec keeps the spec" || bad "remove --keep-spec"
[ ! -f "$d/config/groups/hahnenkamm.txt" ] && ok "remove deletes the generated group" || bad "group not removed"

out=$(run_in "$d" ./scripts/remove.sh example.net)
[ ! -f "$d/config/certs/plain.conf" ] && ok "remove deletes the matching spec" || bad "spec not deleted"
[ -f "$d/config/certs/example.conf" ] && ok "the template spec survives" || bad "template spec deleted"

# remove by spec path, and revoke failure keeps the spec
d=$(sandbox remove-spec)
cat > "$d/config/certs/foo.conf" <<'EOF'
domain=foo.example
wildcard=0
hosts=foo.example
group=foo
EOF
mkdir -p "$d/acme/foo.example"
printf 'x' > "$d/acme/foo.example/foo.example.conf"
printf '#!/bin/sh\ncase "$*" in *--revoke*) exit 1 ;; esac\nexit 0\n' > "$d/bin/docker"
chmod +x "$d/bin/docker"
out=$(run_in "$d" ./scripts/remove.sh config/certs/foo.conf --revoke 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 1 ] && ok "remove exits 1 when revocation fails" || bad "revoke rc" "$rc"
[ -f "$d/config/certs/foo.conf" ] && ok "failed revocation keeps the spec" || bad "spec deleted after failed revoke" "$out"
grep -q -- '--remove' "$d/docker.log" 2>/dev/null || printf '%s\n' "$out" >/dev/null
[ -d "$d/acme/foo.example" ] && ok "failed revocation keeps the certificate files" || bad "cert dir removed"

# --host removes one host from spec, group and state
d=$(sandbox remove-host)
cat > "$d/config/certs/foo.conf" <<'EOF'
domain=foo.example
wildcard=0
hosts=foo.example two.foo.example
group=foo
EOF
mkdir -p "$d/acme/deploy-state/foo.example"
printf '1 1 0\n' > "$d/acme/deploy-state/foo.example/two.foo.example_22"
printf '# foo.example on 2 host(s), from config/certs/foo.conf\nfoo.example\ntwo.foo.example\n' > "$d/config/groups/foo.txt"
run_in "$d" ./scripts/remove.sh foo.example --host two.foo.example >/dev/null
out=$(run_in "$d" sh -c '. ./scripts/lib.sh; spec_get config/certs/foo.conf hosts')
[ "$out" = "foo.example" ] && ok "--host edits the spec" || bad "--host spec" "$out"
out=$(cat "$d/config/groups/foo.txt")
case "$out" in
    *two.foo.example*) bad "--host left the host in the group" "$out" ;;
    *) ok "--host edits the group" ;;
esac
[ ! -f "$d/acme/deploy-state/foo.example/two.foo.example_22" ] &&
    ok "--host drops the deploy state" || bad "--host state"

# --- preflight conflicts ---------------------------------------------------

d=$(sandbox preflight)
mkdir -p "$d/acme/deploy-state/wildcard.example.org"
printf '1 1 0\n' > "$d/acme/deploy-state/wildcard.example.org/web1.example.com_22"
out=$(run_in "$d" sh -c '. ./scripts/preflight.sh; check_cert_conflicts "*.example.com" "web1.example.com"' 2>&1)
case "$out" in
    *"already serves *.example.org"*) ok "conflict check warns about another certificate" ;;
    *) bad "conflict warning" "$out" ;;
esac
out=$(SKIP_PREFLIGHT=1 run_in "$d" sh -c '. ./scripts/preflight.sh; check_cert_conflicts "*.example.com" "web1.example.com"' 2>&1)
[ -z "$out" ] && ok "SKIP_PREFLIGHT=1 silences the checks" || bad "SKIP_PREFLIGHT" "$out"

# --- deploy hook -----------------------------------------------------------

d=$(sandbox fleet)
mkdir -p "$d/groups" "$d/home/*.example.com" "$d/state"
printf 'a.example.com\nb.example.com\n' > "$d/groups/wildcard.txt"
cat > "$d/home/*.example.com/*.example.com.conf" <<'EOF'
Le_Domain='*.example.com'
Le_DeployHook='fleet,'
SAVED_DEPLOY_GROUP='wildcard'
SAVED_DEPLOY_HOSTS='a.example.com b.example.com'
SAVED_DEPLOY_NAME='wildcard.example.com'
EOF
for f in cert key ca fullchain; do printf 'x' > "$d/home/*.example.com/$f.pem"; done

hook_test() {
    DOMAIN_CONF="$d/home/*.example.com/*.example.com.conf" \
        DEPLOY_LIB="$repo/deploy/lib.sh" \
        DEPLOY_STATE_DIR="$d/state" \
        DEPLOY_GROUPS_DIR="$d/groups" \
        DEPLOY_KEY="$d/keys/acme_ed25519" \
        DEPLOY_KNOWN_HOSTS="$d/config/known_hosts" \
        PATH="$d/bin:$PATH" \
        sh -c '. "$1"; _savedeployconf() { :; }; shift; fleet_deploy "$@"' _ \
        "$repo/deploy/fleet.sh" '*.example.com' \
        "$d/home/*.example.com/key.pem" "$d/home/*.example.com/cert.pem" \
        "$d/home/*.example.com/ca.pem" "$d/home/*.example.com/fullchain.pem"
}

out=$(hook_test 2>&1)
case "$out" in
    *"deploy: wildcard.example.com ok 2, failed 0"*) ok "hook deploys the stored group" ;;
    *) bad "hook stored group" "$out" ;;
esac

out=$(DEPLOY_ONLY=b.example.com hook_test 2>&1)
case "$out" in
    *"deploy: wildcard.example.com ok 1, failed 0"*) ok "hook honours DEPLOY_ONLY" ;;
    *) bad "hook DEPLOY_ONLY" "$out" ;;
esac

DEPLOY_GROUP=
DEPLOY_HOSTS=c.example.com
export DEPLOY_GROUP DEPLOY_HOSTS
out=$(hook_test 2>&1)
unset DEPLOY_GROUP DEPLOY_HOSTS
case "$out" in
    *"ok 1, failed 0"*) ok "environment values win over the stored group" ;;
    *) bad "hook env precedence" "$out" ;;
esac

# A missing group file must not fail the sync: it asks for one host.
rm -f "$d/groups/wildcard.txt"
out=$(DEPLOY_ONLY=b.example.com hook_test 2>&1)
case "$out" in
    *"deploying the requested host only"*"ok 1, failed 0"*) ok "hook falls back to DEPLOY_ONLY without a group file" ;;
    *) bad "hook fallback" "$out" ;;
esac

# --- status.sh -------------------------------------------------------------

d=$(sandbox status)
run_in "$d" ./scripts/status.sh >/dev/null 2>&1 && ok "status is quiet on an empty tree" || bad "status empty tree"
cat > "$d/config/certs/ghost.conf" <<'EOF'
domain=ghost.example
wildcard=1
hosts=ghost.example
group=ghost
EOF
out=$(run_in "$d" ./scripts/status.sh 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] && ok "status reports a spec without certificate" || bad "status rc" "$out"
case "$out" in
    *"ghost.example is not issued"*) ok "status names the missing certificate" ;;
    *) bad "status message" "$out" ;;
esac
mkdir -p "$d/acme/deploy-state/gone.example"
out=$(run_in "$d" ./scripts/status.sh 2>&1)
case "$out" in
    *"deploy state for gone.example"*) ok "status reports orphan deploy state" ;;
    *) bad "status orphan state" "$out" ;;
esac

# A certificate removed from renewal keeps its files: it must not look healthy.
d=$(sandbox status-noconf)
mkdir -p "$d/acme/gone.example"
printf 'x' > "$d/acme/gone.example/gone.example.cer"
cat > "$d/config/certs/gone.conf" <<'EOF'
domain=gone.example
wildcard=0
hosts=gone.example
EOF
out=$(run_in "$d" ./scripts/status.sh 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] && ok "status fails for a certificate without config" || bad "status conf-less rc" "$out"
case "$out" in
    *"gone.example has no acme.sh config"*) ok "status names the spec without acme.sh config" ;;
    *) bad "status spec-side message" "$out" ;;
esac
case "$out" in
    *"gone.example: no acme.sh config"*) ok "status reports the certificate without acme.sh config" ;;
    *) bad "status cert-side message" "$out" ;;
esac

# An existing certificate without a spec can be adopted from its own config.
d=$(sandbox adopt)
mkdir -p "$d/acme/*.example.net"
cat > "$d/acme/*.example.net/*.example.net.conf" <<'EOF'
Le_Domain='*.example.net'
Le_DeployHook='fleet,'
SAVED_DEPLOY_GROUP='example'
SAVED_DEPLOY_HOSTS='example.net web1.example.net 10.0.0.1'
EOF
printf 'x' > "$d/acme/*.example.net/*.example.net.cer"
printf 'example.net\nweb1.example.net\n10.0.0.1\n' > "$d/config/groups/example.txt"
printf 'x' > "$d/config/acme-dns/example.net.env"
mkdir -p "$d/acme/deploy-state/wildcard.example.net"
for h in example.net web1.example.net 10.0.0.1; do
    printf '1 1 0\n' > "$d/acme/deploy-state/wildcard.example.net/${h}_22"
done
out=$(run_in "$d" ./scripts/status.sh --fix 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] && ok "status --fix adopts an existing certificate" || bad "status --fix rc" "$out"
grep -qx 'domain=example.net' "$d/config/certs/example.net.conf" &&
    ok "adopted spec keeps the domain" || bad "adopted domain" "$out"
grep -qx 'wildcard=1' "$d/config/certs/example.net.conf" &&
    ok "adopted spec keeps the wildcard" || bad "adopted wildcard" "$out"
grep -qx 'hosts=example.net,web1.example.net,10.0.0.1' "$d/config/certs/example.net.conf" &&
    ok "adopted spec keeps every host" || bad "adopted hosts" "$out"
grep -qx 'group=example' "$d/config/certs/example.net.conf" &&
    ok "adopted spec keeps the group" || bad "adopted group" "$out"
out=$(run_in "$d" ./scripts/status.sh --fix 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] && ok "status --fix is idempotent" || bad "status --fix rerun" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
