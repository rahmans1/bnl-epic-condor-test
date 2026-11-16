# Merger comparison: allbg_10x275_GoldCoating10um

47 chunks x 100 frames per merger (4700 frames each). SBM = SignalBackgroundMerger, TFB = TimeFrameBuilder.

| source | expected / frame | SBM / frame | TFB / frame | pull SBM | pull TFB | var/mean SBM | var/mean TFB | events-per-frame p |
|---|---|---|---|---|---|---|---|---|
| p beam-gas | 0.0652 | 0.065957 ± 0.0038 | 0.064681 ± 0.0037 | +0.20 | -0.14 | 1.031 | 0.975 | 0.128 |
| SYNRAD | 26554 | 26552 ± 2.3 | 26556 ± 2.4 | -0.77 | +0.97 | 0.966 | 1.008 | 0.487 |
| e-gas brems | 6.3545 | 6.3617 ± 0.036 | 6.347 ± 0.037 | +0.20 | -0.20 | 0.982 | 1.013 | 0.0763 |
| e Coulomb | 0.05912 | 0.063404 ± 0.0038 | 0.054468 ± 0.0034 | +1.21 | -1.31 | 1.064 | 1.0 | 0.138 |
| e Touschek | 0.467 | 0.45681 ± 0.0098 | 0.47298 ± 0.01 | -1.02 | +0.60 | 0.993 | 1.014 | 0.245 |

Event time p is a test over independent events. The particle-level tests (production time, |p|,
theta) have chi2 divided by the mean final-state particles per event (they share the event time),
so their p-values are approximate. The sequence columns show whether the two mergers placed the very
same input particles in the same order.

| source | event time p | particle time p | abs(p) p | theta p | sequence: chunks identical | min fraction identical |
|---|---|---|---|---|---|---|
| p beam-gas | 0.269 | 0.125 | 1 | 1 | 47/47 | 1.0 |
| SYNRAD | 0.424 | 0.424 | 1 | 1 | 46/47 | 0.0 |
| e-gas brems | 0.451 | 0.451 | 1 | 1 | 47/47 | 1.0 |
| e Coulomb | 0.38 | 0.38 | nan | nan | 46/46 | 1.0 |
| e Touschek | 0.188 | 0.188 | 0.905 | nan | 47/47 | 1.0 |

| merger | frames/job | jobs | wall s (median) | CPU s (median) | max PSS GB |
|---|---|---|---|---|---|
| SignalBackgroundMerger | 100 | 60 | 54 | 47 | 2.19 |
| SignalBackgroundMerger | 500 | 20 | 332 | 234 | 2.28 |
| SignalBackgroundMerger | 1000 | 3 | 699 | 478 | 2.17 |
| TimeFrameBuilder | 100 | 60 | 70 | 47 | 3.31 |
| TimeFrameBuilder | 500 | 20 | 289 | 228 | 8.04 |
| TimeFrameBuilder | 1000 | 3 | 713 | 446 | 13.36 |
