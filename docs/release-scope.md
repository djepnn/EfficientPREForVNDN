# Release Scope

## Included

The release contains only the blockchain implementation associated with the
paper's on-chain algorithms and its directly supporting test evidence. The
contract functions implement listing, payment lock, signed PRE-key submission,
confirmation/timeout settlement, key-timeout refund, and dispute recording.

The benchmark compiles the contract, deploys 30 fresh instances, exercises the
workflow branches, records transaction receipts and gas, and checks seven
negative cases. The bundled validation record reports 483 unique successful
transactions, 483 verified receipts, and 7/7 passed negative tests.

## Not included

- the Ubuntu virtual-machine image or its login credentials;
- GitHub credentials, wallet secrets, or production blockchain keys;
- the ndnSIM/ns-3 source tree and packet-level experiment campaign;
- the request-level vehicular simulator and literature-baseline implementations;
- reviewer documents, manuscript working files, or internal response material;
- VPRE algorithms or proofs that are not part of the adopted ordinary PRE scheme.

Those exclusions keep the public repository aligned with the original code
commitment without misrepresenting the package as the complete private
resubmission workspace.
