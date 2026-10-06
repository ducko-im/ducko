# Third-party licences

These upstream licence and notice texts accompany the components linked into Ducko and its embedded CLI. Sparkle also contains its own distribution notices. System frameworks are supplied by macOS. Ducko's GPLv3 text and BoringSSL linking permission are in the repository LICENSE and the app's Resources/LICENSE.txt.

| Package | Version | Revision |
|---|---|---|
| sparkle | 2.10.0 | eef1a539a373c1f1a320624b1130fc5de7b2e100 |
| swift-argument-parser | 1.8.2 | 6a52f3251125d74daf04fcbd5e6f08a75d074382 |
| swift-atomics | 1.3.1 | 0442cb5a3f98ab802acb777929fdb446bda11a34 |
| swift-collections | 1.6.0 | a0cb0954ecb21e4e31b0070e6ed5674e8556685a |
| swift-log | 1.15.1 | 9c6fb14227f55d8f711ce3847dc2f419fb0ecacb |
| swift-nio | 2.103.0 | 21de5f08c1a166a6dd293d0e587ad977bf8dac5d |
| swift-nio-ssl | 2.37.5 | 322f3c2a4a21df31c84ca416bf65ee5e9059e440 |
| swift-system | 1.8.1 | 869129b7bf4ecc57b97d0193ad29690ca2134750 |

SwiftNIO SSL vendors BoringSSL revision `817ab07ebb53da35afea409ab9328f578492832d`; its aggregate licence is reproduced in `BoringSSL-LICENSE.txt`. Source: https://github.com/google/boringssl/tree/817ab07ebb53da35afea409ab9328f578492832d. Swift package source URLs and exact revisions are recorded in `Package.resolved` at the Ducko source repository: https://github.com/ducko-im/ducko.

SwiftNIO's CNIOAtomics target includes uSHET's `cpp_magic.h` from revision `c09e0acafd86720efe42dc15c63e0cc228244c32`. Its upstream aggregate licence is reproduced in `uSHET-LICENSE.txt`: https://github.com/18sg/uSHET/blob/c09e0acafd86720efe42dc15c63e0cc228244c32/LICENSE.

This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/). This product includes cryptographic software written by Eric Young (eay@cryptsoft.com) and software written by Tim Hudson (tjh@cryptsoft.com).

When updating dependencies, refresh this inventory and the unmodified upstream texts from the resolved revisions. Ducko maintainers monitor SwiftNIO SSL and its bundled BoringSSL security updates; macOS updates do not replace this statically linked TLS implementation. Rebuild and run Ducko's focused transport integration tests after upgrades.
