# Uploading this artifact to GitHub

Target repository:
`https://github.com/djepnn/EfficientPREForVNDN`

The repository was public and empty when this release package was prepared on
2026-09-10.

## Simple browser method

1. Open the target repository while signed in to the `djepnn` GitHub account.
2. Select **Add file** and then **Upload files**.
3. Upload the *contents* of `github_release_blockchain_v1` so that `README.md`,
   `contracts/`, `scripts/`, `docs/`, and `results/` appear at repository root.
4. Use a commit message such as `Release validated blockchain artifact v1`.
5. Confirm that the repository page displays the README and that
   `contracts/VehicularDataTrading.sol` is visible.
6. Create a release or tag named `v1.0.0` so the paper points to a fixed version,
   not only a moving branch.

## Command-line method

From PowerShell, change into this directory and run:

```powershell
git init
git branch -M main
git add .
git commit -m "Release validated blockchain artifact v1"
git remote add origin https://github.com/djepnn/EfficientPREForVNDN.git
git push -u origin main
git tag -a v1.0.0 -m "IoTJ blockchain artifact v1.0.0"
git push origin v1.0.0
```

GitHub may ask for browser sign-in or a personal access token. Do not place the
Ubuntu password, a GitHub token, real wallet keys, or any mnemonic holding funds
in this repository.

If a README or license is created on GitHub before these commands are run, the
remote is no longer empty. In that case, clone the remote first, copy these
files into the clone, and then commit and push rather than forcing the history.

## Before submitting the manuscript

- Open the public repository in a signed-out browser window.
- Check the contract SHA-256 against `SHA256SUMS.txt`.
- Check that no secrets or machine-specific absolute paths were added.
- Decide on a repository-wide license. The contract itself declares MIT through
  its SPDX header, but no license is imposed here on the remaining files.
- After the `v1.0.0` release exists, change the manuscript sentence from future
  tense ("will be archived") to present tense ("is archived") if desired.
