# Third-party data: AutoEq

Joseon embeds measured headphone frequency responses and target curves taken from the
**AutoEq** project. No measurement in this repository was made by Joseon, and none was
invented: every number in `Sources/JoseonHeadphones/EmbeddedCurves.swift` comes from a file
listed below.

- Project: <https://github.com/jaakkopasanen/AutoEq>
- License: MIT
- Copyright (c) 2018-2022 Jaakko Pasanen
- Fetch date: **2026-09-20**
- Fetched from: `https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/<path>` (read-only HTTP GET)

## License notice

```
MIT License

Copyright (c) 2018-2022 Jaakko Pasanen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALING IN THE
SOFTWARE.
```

Full text: <https://github.com/jaakkopasanen/AutoEq/blob/master/LICENSE>

## What was taken

Every file is an AutoEq result CSV with the header
`frequency,raw,smoothed,error,error_smoothed,equalization,parametric_eq,fixed_band_eq,equalized_raw,equalized_smoothed,target`,
or a target CSV with the header `frequency,raw`.

**Only the `raw` column is used** — the measured response before AutoEq's own equalization.
The `smoothed`, `equalized_raw`, `equalized_smoothed` and `target` columns are never read.

### Headphone responses

| Embedded name | AutoEq path (under `master/`) | Measurer |
|---|---|---|
| HiFiMAN Susvara Unveiled | `results/Kuulokenurkka/over-ear/HIFIMAN Susvara Unveiled/HIFIMAN Susvara Unveiled.csv` | Kuulokenurkka |
| HiFiMAN Susvara | `results/Kuulokenurkka/over-ear/HIFIMAN Susvara/HIFIMAN Susvara.csv` | Kuulokenurkka |
| Sennheiser HD 600 | `results/oratory1990/over-ear/Sennheiser HD 600/Sennheiser HD 600.csv` | oratory1990 |
| Sennheiser HD 650 | `results/oratory1990/over-ear/Sennheiser HD 650/Sennheiser HD 650.csv` | oratory1990 |
| Sennheiser HD 800 S | `results/oratory1990/over-ear/Sennheiser HD 800 S/Sennheiser HD 800 S.csv` | oratory1990 |
| Focal Utopia | `results/oratory1990/over-ear/Focal Utopia/Focal Utopia.csv` | oratory1990 |
| Audeze LCD-X (2021) | `results/oratory1990/over-ear/Audeze LCD-X (2021)/Audeze LCD-X (2021).csv` | oratory1990 |
| Meze Empyrean (leather earpads) | `results/oratory1990/over-ear/Meze Empyrean (leather earpads)/Meze Empyrean (leather earpads).csv` | oratory1990 |
| ZMF Verite | `results/oratory1990/over-ear/ZMF Verite/ZMF Verite.csv` | oratory1990 |
| Apple AirPods Max | `results/oratory1990/over-ear/Apple AirPods Max/Apple AirPods Max.csv` | oratory1990 |
| Apple AirPods Pro 2 | `results/HypetheSonics/GRAS RA0045 in-ear/Apple Airpods Pro 2/Apple Airpods Pro 2.csv` | HypetheSonics, GRAS RA0045 rig |
| Sony WH-1000XM5 | `results/oratory1990/over-ear/Sony WH-1000XM5/Sony WH-1000XM5.csv` | oratory1990 |

### Target curves

| Embedded name | AutoEq path (under `master/`) |
|---|---|
| Harman over-ear 2018 | `targets/Harman over-ear 2018.csv` |
| Harman in-ear 2019 | `targets/Harman in-ear 2019.csv` |
| Diffuse field GRAS KEMAR | `targets/Diffuse field GRAS KEMAR.csv` |
| Flat (zero) | `targets/zero.csv` |

### Nothing was missing

Every file in the two tables above downloaded successfully on 2026-09-20. No curve was
dropped, and no curve was substituted.

HiFiMAN **Susvara Unveiled** is measured in AutoEq, so the fallback in the brief (plain
Susvara) was not needed. Plain **HiFiMAN Susvara** is embedded as well, so the two can be
compared.

## How the data was processed

1. Download the CSV over HTTPS from `raw.githubusercontent.com`.
2. Read the `frequency` and `raw` columns. Drop rows that are not two finite numbers.
3. Decimate onto a shared 200-point log-spaced grid from 20 Hz to 20 kHz
   (`EmbeddedCurves.standardFrequenciesHz`, about 1/10 octave spacing). Each output point is
   the **mean of the source points that fall inside its bin**, which is an anti-aliased
   decimation rather than plain point sampling. Where a bin holds no source point, the value
   is interpolated linearly in dB over log frequency.
4. Write the levels as `Float` literals with 2 decimals.

Source files are 695 points from 20.00 Hz to 19 956 Hz at a 1 % frequency step. The top grid
point, 20 000 Hz, is therefore an extrapolation: it repeats the 19 956 Hz value.

### Decimation error

Difference between the embedded value and the source curve interpolated at the same
frequency, measured on 2026-09-20 against the live files:

| Curve | max (dB) | mean (dB) |
|---|---|---|
| HiFiMAN Susvara Unveiled | 0.46 | 0.03 |
| HiFiMAN Susvara | 0.87 | 0.06 |
| Sennheiser HD 600 | 0.11 | 0.01 |
| Sennheiser HD 650 | 0.14 | 0.02 |
| Sennheiser HD 800 S | 0.15 | 0.02 |
| Focal Utopia | 0.10 | 0.02 |
| Audeze LCD-X (2021) | 0.12 | 0.02 |
| Meze Empyrean (leather earpads) | 0.18 | 0.02 |
| ZMF Verite | 0.21 | 0.02 |
| Apple AirPods Max | 0.19 | 0.02 |
| **Apple AirPods Pro 2** | **5.89** | 0.05 |
| Sony WH-1000XM5 | 0.15 | 0.01 |
| Harman over-ear 2018 | 0.53 | 0.01 |
| Harman in-ear 2019 | 0.32 | 0.01 |
| Diffuse field GRAS KEMAR | 0.07 | 0.01 |
| Flat (zero) | 0.00 | 0.00 |

The AirPods Pro 2 curve has a very narrow high-frequency notch. A notch narrower than
1/10 octave cannot survive a 200-point grid, so it is averaged down at one or two points.
Everything else stays inside about 0.9 dB, and the mean error is under 0.1 dB everywhere.
Raise `N_OUT` in the fetch script if a sharper in-ear curve is ever needed.

## Caveats a reader should know

- **Rigs are not interchangeable.** A response measured on one head-and-ear simulator cannot
  be compared point-by-point with one measured on another. The AutoEq repository names the
  rig in the directory path for some measurers (HypetheSonics, Rtings) and not for others
  (oratory1990, Kuulokenurkka), so the `source` string on each curve repeats only what the
  repository states. Joseon does not claim a rig it cannot cite.
- **Target pairing.** AutoEq stores, in each result file, the target it used, level-shifted.
  Checked on 2026-09-20: for the oratory1990 and Kuulokenurkka results the stored target is
  `targets/Harman over-ear 2018.csv` shifted by a constant (spread across frequency 0.09 dB
  for the Susvara Unveiled), so pairing those curves with the embedded Harman over-ear 2018
  is exact once both are normalized to 0 dB at 1 kHz. For the HypetheSonics GRAS RA0045
  in-ear result the stored target differs from `targets/Harman in-ear 2019.csv` by up to
  1.99 dB across frequency, so the AirPods Pro 2 pairing is an approximation, not the target
  AutoEq itself used. No closer file was found among the in-ear targets tried.
- **Normalization.** `HeadphoneModel` shifts every curve and target so that the mean over
  800–1250 Hz is 0 dB. Absolute sensitivity is not modelled, so the at-ear prediction is a
  shape, not an SPL.
- **Unit variation.** One measurement of one unit with one pad set. Real headphones vary
  between samples, pads, and how they sit on a head.

## Regenerating

There is no resource bundle: `EmbeddedCurves.swift` is generated Swift source, marked
"Do not edit by hand". To refresh it, re-download the files listed above, redo the four
processing steps, and update the fetch date and the decimation-error table here.
