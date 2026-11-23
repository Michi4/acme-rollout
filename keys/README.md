# keys

Private deploy key. Not committed.

```bash
ssh-keygen -t ed25519 -N '' -C acme-rollout -f keys/acme_ed25519
```

Add `keys/acme_ed25519.pub` as `ACME_PUSH_PUBKEY` to the profile of every
target host (the `acme-target` recipe in
[deploy-tool](https://github.com/Michi4/deploy-tool) installs it).
