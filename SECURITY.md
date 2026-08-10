# Security

## Reporting a vulnerability

Email **support@seekquel.app** with the details. Please do not open a public issue for
anything exploitable.

Include what you found, how to reproduce it, and what an attacker could do with it. You
will get an acknowledgement within a few days.

## What is worth reporting

- Anything that lets one account read or write another account's reading data.
- Anything that leaks a device key, or lets a device key be guessed or reused.
- Anything that lets the pairing exchange be completed by somebody who is not the reader
  approving it.

## Known and deliberate

**The device key is stored in plain text** in `koreader/settings/seekquel.lua`. This is
not an oversight. KOReader runs unprivileged on a filesystem the reader mounts over USB,
so anything on the device is readable by anyone holding the device, and a keystore would
only look like protection. The key is scoped to syncing, it cannot read or change account
settings, and it can be revoked from Settings > Integrations at any time.

**The pairing code is eight characters** and lives for fifteen minutes behind a human
approval on an account somebody is already signed in to. The device code that backs the
exchange is much longer and is stored hashed.
