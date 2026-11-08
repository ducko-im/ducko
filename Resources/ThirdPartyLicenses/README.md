# Third-party licences

These upstream licence and notice texts accompany the components linked into Ducko and its embedded CLI. Sparkle also contains its own distribution notices. System frameworks are supplied by macOS. Ducko's GPLv3 text is in the repository LICENSE and the app's Resources/LICENSE.txt.

| Package | Version | Revision |
|---|---|---|
| sparkle | 2.10.1 | ab7d71291238df6e0492143b120c9b696a35f603 |
| swift-argument-parser | 1.8.2 | 6a52f3251125d74daf04fcbd5e6f08a75d074382 |
| swift-atomics | 1.3.1 | 0442cb5a3f98ab802acb777929fdb446bda11a34 |
| swift-collections | 1.7.5 | f96b909e1a9e469620bc5037c1e24e00153f376f |
| swift-log | 1.17.0 | e3da04078777e6a1b72ce19981fbd6539b0847d8 |
| swift-nio | 2.105.0 | 2f58d8ef84438d6517fc78bcea2f8527e3c72936 |
| swift-nio-ssl | 2.37.6 | 15e0b9e495786807272dd4891fa4bac76aa43034 |
| swift-system | 1.8.1 | 869129b7bf4ecc57b97d0193ad29690ca2134750 |

SwiftNIO SSL vendors BoringSSL revision `8eb25be6fa18d475291122887a7bccd3762ff236`. Its aggregate licence is reproduced in `BoringSSL-LICENSE.txt`, taken from https://github.com/google/boringssl/tree/8eb25be6fa18d475291122887a7bccd3762ff236.

The Ducko source repository records each Swift package's source URL and exact revision in `Package.resolved`: https://github.com/ducko-im/ducko.

SwiftNIO's CNIOAtomics target includes uSHET's `cpp_magic.h` from revision `c09e0acafd86720efe42dc15c63e0cc228244c32`. Its upstream aggregate licence is reproduced in `uSHET-LICENSE.txt`: https://github.com/18sg/uSHET/blob/c09e0acafd86720efe42dc15c63e0cc228244c32/LICENSE.

When updating dependencies, refresh this inventory and the unmodified upstream texts from the resolved revisions. Ducko maintainers monitor SwiftNIO SSL and its bundled BoringSSL security updates; macOS updates do not replace this statically linked TLS implementation. Rebuild and run Ducko's focused transport integration tests after upgrades.
