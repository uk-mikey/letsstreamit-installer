# LetsStreamIt installer

Standalone distribution of the LetsStreamIt one-line installer, kept as a third download
host in case the LetsStreamIt domains are unavailable. `install.sh` here is a
byte-identical copy of `public/install.sh` in the panel source; keep the two in sync.

- **Repository:** `uk-mikey/letsstreamit-installer` (default branch `main`)
- **File:** `install.sh` — 3,237 lines, 155,320 bytes
- **Release:** 1.1.5
- **SHA-256:** `d2906eda3dcd72173845e669329d858f84bb41f57a6b766f99911aafbacfc16f`

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/uk-mikey/letsstreamit-installer/main/install.sh | sudo sh
```

```sh
# update an existing install
curl -fsSL https://raw.githubusercontent.com/uk-mikey/letsstreamit-installer/main/install.sh | sudo sh -s -- update

# uninstall (prints the plan unless UNINSTALL=yes)
curl -fsSL https://raw.githubusercontent.com/uk-mikey/letsstreamit-installer/main/install.sh | sudo sh -s -- uninstall
```

## Verify before running

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/uk-mikey/letsstreamit-installer/main/install.sh
sha256sum install.sh
# expected: d2906eda3dcd72173845e669329d858f84bb41f57a6b766f99911aafbacfc16f
```

## Download hosts

| Host | URL |
| --- | --- |
| Primary | `https://onair.letsstreamit.com/install.sh` |
| Third host | `https://raw.githubusercontent.com/uk-mikey/letsstreamit-installer/main/install.sh` |

If the primary domain does not answer, the script uses its own source-tarball fallback, so
a normal install needs only one reachable URL to start.

## Notes

- A normal install needs root: pipe into `sudo sh`.
- Opt out of the install counter with `INSTALL_REPORT=0`; override its endpoint with
  `INSTALL_REPORT_URL=…`.
- No credentials are embedded in the script. `TUNNEL_TOKEN` is read from your environment
  and is only needed for `PROXY_MODE=tunnel`.
- Every option (`APP_DIR`, `SOURCE_URL`, `PANEL_PORT`, `PROXY_MODE`, engine selections) is
  documented in the comment header at the top of `install.sh`.
- To refresh this copy later, overwrite `install.sh` from the panel's `public/install.sh`
  and update the SHA-256 above in the same commit.
