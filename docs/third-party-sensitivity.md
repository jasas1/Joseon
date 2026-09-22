# Third-party data: headphone sensitivity and the diffuse-field reference

Joseon's SPL estimate rests on two kinds of borrowed number: what each headphone maker
publishes about its own product, and one figure from the acoustics literature. Neither was
invented, remembered, or averaged from reviews. This file records where every number came
from, what was checked and found missing, and what is still unverified.

- Fetch date for every manufacturer figure: **2026-09-21**
- Method: read-only HTTPS GET of the manufacturer's own page or data sheet. Fetched pages
  were treated as data. No page carried text addressed to an automated reader.
- Code: `Sources/JoseonHeadphones/HeadphoneSensitivityLibrary.swift`,
  `Sources/JoseonHeadphones/DiffuseFieldOffset.swift`

## The rule

`HeadphoneSensitivity.dbSPLPerVolt` is **dB SPL at the eardrum simulator for 1 V RMS at
1 kHz**. A manufacturer figure is usable only when its reference is stated, because the
conversion depends on it:

- **dB SPL at 1 V** → use as published, no conversion.
- **dB SPL per mW** → `dbSPLPerVolt = dbPerMilliwatt + 10·log10(1000 / Z)`, which is
  `HeadphoneSensitivity.fromDBPerMilliwatt`.
- **a bare "86 dB"** → **not usable**. It could be per milliwatt or per volt, and at 45 Ω
  those two readings differ by 13.5 dB — which is the difference between a safe evening and
  a harmful one. Joseon leaves the headphone out rather than pick one.

A headphone with no usable figure is not in the library. It is in
`HeadphoneSensitivityLibrary.unlisted` with the reason and the page that was checked, so the
app asks the user for a number and says why.

## Sensitivity: what was found

Six of the twelve embedded curves have a citable figure.

| Curve name | Published spec line, verbatim | Impedance | dB SPL / V used | Source URL |
|---|---|---|---|---|
| Sennheiser HD 600 | "Sound pressure level (SPL) 97 dB (1 V)" | 300 Ω | 97.00 | <https://us.sennheiser-hearing.com/products/hd-600> |
| Sennheiser HD 650 | "Sound pressure level (SPL) 103 dB (1 V)" | 300 Ω | 103.00 | <https://us.sennheiser-hearing.com/products/hd-650> |
| Sennheiser HD 800 S | "Sound pressure level (SPL) 102 dB (1 V)" | 300 Ω | 102.00 | <https://us.sennheiser-hearing.com/products/hd-800-s> |
| Focal Utopia | "Sensitivity 104dB SPL / 1mW @ 1kHz" | 80 Ohms | 114.97 | <https://dam.focal-naim.com/m/60e16a1d4cab5a65/original/FP_Utopia_EN-pdf.pdf> |
| Audeze LCD-X (2021) | "Sensitivity 103 dB/1mW (at Drum Reference Point)" | 20 ohms | 119.99 | <https://www.audeze.com/products/lcd-x> |
| Sony WH-1000XM5 | "Sensitivity: 102 dB/mW (when connecting via the headphone cable with the headset turned on)" | 48 Ω (1 kHz) | 115.19 | <https://helpguide.sony.net/mdr/wh1000xm5/v1/en/contents/TP1000541014.html> |

### Per-entry caveats

**Sennheiser** labels the line "Sound pressure level (SPL)", not "Sensitivity". It is
nonetheless dB SPL at 1 V, which is exactly what the contract wants, so nothing is converted.
Do not compare these figures with the dB/mW ones above without converting: at 300 Ω the two
scales differ by 5.2 dB.

**Focal** is the one to be careful with. The live product page at `focal.com/products/utopia`
publishes **no sensitivity line at all** — it lists "Maximum SPL (peak@1m) : 104 dB SPL",
which is a *different quantity that happens to share the number 104*. The sensitivity figure
comes from Focal's own product data sheet PDF (footer: "Focal® is a trade from Focal-JMLab® -
www.focal.com - SCAA - v1 - 07/07/2022"), hosted on Focal's asset domain and linked from that
page. The sheet's own line is "Sensitivity 104dB SPL / 1mW @ 1kHz". The coincidence is a trap
worth remembering if this is ever re-fetched.

**Audeze** states the figure "at Drum Reference Point", which is the reference the SPL chain
wants — `dbSPLPerVolt` is defined at the eardrum simulator, and the DRP is that point. A
coupler or free-field figure would need a correction; this one does not. Separately: the page
does not print a model year anywhere, so it cannot be confirmed from Audeze that this table
is the 2021 revision specifically, while the embedded curve is explicitly "Audeze LCD-X
(2021)". Treat the pairing as probable, not certain.

**Sony** breaks the expectation that wireless headphones publish nothing. The product pages
on `sony.com` refuse automated requests, but Sony's Help Guide carries a full specifications
section. The figure used is the **wired, headset powered on** row, because Joseon can only
see the voltage of a wired chain at all. The passive row (headset off) is 100 dB/mW into
16 Ω and is not used. Over Bluetooth there is no voltage for Joseon to reason about, so no
SPL estimate is possible however good the sensitivity figure is.

## Sensitivity: user must enter

Six curves have no citable figure. Each is in `HeadphoneSensitivityLibrary.unlisted` with a
reason string the UI shows next to the input field.

| Curve name | What the maker publishes | Page checked |
|---|---|---|
| HiFiMAN Susvara Unveiled | "Sensitivity: : 86dB", "Impedance: : 45Ω" — **no reference given**, not per mW, not per V, no frequency | <https://www.hifiman.com/products/detail/347> |
| HiFiMAN Susvara | "Sensitivity : 83dB", "Impedance : 60Ω" — same, no reference | <https://www.hifiman.com/products/detail/275> |
| Meze Empyrean (leather earpads) | nothing: the first-generation Empyrean is discontinued and its product page is gone | <https://mezeaudio.com/products/meze-empyrean> |
| ZMF Verite | nothing: retired; the surviving page has prose about the driver and no specification table | <https://www.zmfheadphones.com/verite/> |
| Apple AirPods Max | nothing: Apple publishes no sensitivity or impedance for any AirPods model | <https://www.apple.com/airpods-max/specs/> |
| Apple AirPods Pro 2 | nothing, same as above | <https://support.apple.com/en-us/111851> |

### This includes the first user's own headphone

The HiFiMAN Susvara Unveiled is what Joseon was built for, and it is the one headphone whose
sensitivity Joseon cannot look up. HiFiMAN prints "86dB" with no reference. Read as dB/mW at
45 Ω it converts to 99.5 dB/V; read as dB/V it is 86 dB/V. Those are 13.5 dB apart, and a
13.5 dB error in the SPL chain turns a 22-fold difference in noise dose. Guessing which one
HiFiMAN meant would produce a number that looks authoritative and is not, which is worse than
having no number.

So for this headphone the app must ask, and the honest path is
`PlaybackCalibration.fromMeasuredTone` — measure the voltage at the headphone with a meter,
which sidesteps the published sensitivity entirely for everything except the final
volts-to-SPL step, and then enter a sensitivity the user chooses to trust.

### Substitutions that were deliberately NOT made

- Meze publishes 90 dB SPL/mW at 32 Ω for the **Empyrean II**. That is a different driver. It
  was not carried over to the first-generation Empyrean, whose curve is the embedded one.
- Search engines still surface a cached "300 Ohms / ~99 dB/mW" for the ZMF Verite from the
  dead shop page. The page returns 404 and the figure could not be verified, so it was not
  used. The live ZMF page's only electrical phrase, "a stiffer, lighter, 300 ohm voice coil",
  describes a voice coil, not a published nominal impedance spec.
- No review site, forum, retailer, database or measurement project was used for any
  sensitivity figure.

## Diffuse-field offset

`SPLEstimator` converts an eardrum level into the diffuse-field-equivalent level that
noise-dose limits refer to, per the ISO 11904-1 idea: subtract the ear's own diffuse-field
transfer function. That function needs a shape and an absolute anchor.

- **Shape**: the embedded "Diffuse field GRAS KEMAR" target, normalized to its own
  800–1250 Hz mean, the same normalization `HeadphoneModel` applies to every curve.
- **Anchor**: `DiffuseFieldOffsetDecision.valueDB` = **4.1 dB**.

### The value and its source

> Hammershøi, D. and Møller, H., "Determination of Noise Immission From Sound Sources Close
> to the Ears", *Acta Acustica united with Acustica* **94**(1), 2008, 114–129.
> DOI 10.3813/AAA.918014. **Table II**, column `ΔL_DF [dB]`, sub-column `ED`, row `1000` Hz.

Open-access copy: <https://dael.euracoustics.org/landing_pages/aaua/64603.html>
Retrieved and read on 2026-09-21. The number was taken from the paper's own text, not from a
secondary source or a search snippet.

Table II is printed under the section heading **"3.3. Literature data for ISO 11904-1"**, so
it is the quantity ISO 11904-1 subtracts. The table separates six columns, and the right one
matters: at 1 kHz the eardrum value is 4.1 dB, the open-entrance value 2.9 dB, the
blocked-entrance value 2.3 dB, and the free-field eardrum value 2.7 dB. Joseon's chain is
referred to an eardrum simulator, so the **diffuse-field, eardrum (ED)** column is correct.

The 1 kHz row in full, as printed:

| Frequency | ΔL_FF ED | ΔL_FF OE | ΔL_FF BE | ΔL_DF ED | ΔL_DF OE | ΔL_DF BE |
|---|---|---|---|---|---|---|
| 800 | 3.1 | 1.3 | 1.4 | 3.3 | 2.5 | 2.3 |
| **1000** | 2.7 | 0.6 | −0.4 | **4.1** | 2.9 | 2.3 |
| 1250 | 2.9 | 1.5 | 1.3 | 5.5 | 3.6 | 3.1 |

The underlying diffuse-field eardrum data the paper compiles are from Bronkhorst, Killion et
al., Berger, and Storey & Dillon.

**Sign.** ISO 11904 subtracts: `L_DF = L_eardrum − ΔL_DF`. A 90 dB SPL at the eardrum at
1 kHz is an 85.9 dB diffuse-field-equivalent level. `SPLEstimator` subtracts, and
`SPLDiffuseFieldTests.testTheTermIsSubtractedNotAdded` fails if that ever flips.

### Cross-check: the shape and the anchor agree

The KEMAR target and the Hammershøi & Møller table are independent — one is a manikin target
curve from the AutoEq project, the other a mean of human measurements from four studies. The
normalized KEMAR shape plus the single 4.1 dB constant reproduces the published table across
100 Hz – 16 kHz to:

- **RMS error 0.47 dB**
- worst case **+0.88 dB at 12.5 kHz** (next worst −0.80 dB at 3150 Hz, +0.79 dB at 2 kHz)

Two unrelated datasets landing that close is the reason to believe the construction rather
than just the arithmetic. `SPLDiffuseFieldTests.testConstructedResponseMatchesThePublishedTable`
checks it on every run, against the table transcribed into
`DiffuseFieldOffsetDecision.publishedEardrumDiffuseFieldDB`.

One consequence worth stating: because the normalized KEMAR shape is −0.23 dB at exactly
1 kHz relative to its own 800–1250 Hz mean, the constructed response at 1 kHz is 3.87 dB
rather than 4.10 dB. The constant is the published number, added as the spec describes;
the 0.23 dB residual is inside the scatter above and far inside the calibration uncertainty.

### What is still unverified about this number

**ISO 11904-1:2002's own Table 1 was not read.** The standard is paywalled; its free preview
ends at page 5 and the table is in clause 9 on page 7. `iso.org` returns 403. No thesis or
paper reproducing that table verbatim was found. What was obtained instead:

- The Hammershøi & Møller 2008 paper above, whose relevant section is explicitly headed
  "Literature data for ISO 11904-1" — strong evidence it is the standard's data source, but
  not the standard itself.
- An independent corroboration from a *different* part of the same standard family:
  **ISO 11904-2:2021, Table 1**, readable in the publisher's free sample, gives
  ΔL_DF,M = **4,6 dB** at 1 000 Hz. That is the *manikin* eardrum (IEC 60318-4 ear simulator
  DRP) rather than a human eardrum, so it is not the same quantity, but 4.6 against 4.1 is
  close, and Table I of the Hammershøi & Møller paper matches ISO 11904-2's table exactly —
  which confirms the paper really is the standards' data source.
  <https://cdn.standards.iteh.ai/samples/81332/fe906f88670e4558a3e990a9d3b4ec04/ISO-11904-2-2021.pdf>

**Shaw (1974) and Shaw & Vaillancourt (1985) were not used.** Both are paywalled, and both
tabulate the **free-field** transformation to the eardrum, not the diffuse-field one. At
1 kHz the free-field eardrum value is 2.7 dB against the diffuse-field 4.1 dB, so using them
would have introduced a 1.4 dB error at 1 kHz and much more higher up. They are named here so
nobody reaches for them later thinking they were overlooked.

## Other choices worth knowing

**Where Joseon deviates from the letter of the spec, and why.** The spec writes the
diffuse-field term as `DF(f_b)`, a point value at the band center, while it asks for the
headphone response to be averaged across the band in the dB domain. Joseon averages **both**
the same way. Using a band mean for one curve and a point value for the other would be
inconsistent, and the diffuse-field curve has a sharp 15 dB resonance around 3 kHz where a
point sample and a band mean genuinely differ. The band mean is nine log-spaced samples per
third octave, finer than the 1/10-octave grid the curves are stored on.

**A-weighting is evaluated at the nominal band center** (20, 25, 31.5 … 20000), as the spec
asks. The values printed in the IEC 61672 and ANSI S1.4 tables are computed at the *exact*
base-10 midband frequencies — nominal 16 kHz is really 15 848.9 Hz. Evaluating at nominal
centers reproduces the printed table to within **0.16 dB** (worst case at 160 Hz), against
0.05 dB when evaluated at the exact centers. `ThirdOctaveBands.exactCenterHz(nominalHz:)`
exists so the difference stays measurable rather than forgotten.

**Quiet time counts; only digital silence is skipped.** The Leq and both dose integrals skip
a frame only when `isSilent` is true or `dt` is zero. A fade-out, a pianissimo passage or a
gap between tracks that is not digitally silent is still sound arriving at the ear, and
dropping it would flatter both the Leq and the dose. The NIOSH 80 dBA threshold is what keeps
quiet listening out of the *dose*, and that is a separate, named switch.

**The NIOSH threshold is on by default**, as NIOSH publishes it: levels under 80 dBA
accumulate no dose at all. `SPLDoseOptions(applyNIOSHThreshold: false)` integrates every
level instead. The WHO / ITU-T H.870 weekly allowance has no threshold in the recommendation,
so none is applied — quiet listening does spend a sliver of the week.

**NIOSH uses the 3 dB exchange rate in its published form**, `T(L) = 8 h · 2^((85 − L)/3)`,
not the pure energy form `10^((85 − L)/10)`. The two differ by 0.7 % at 94 dBA. The WHO
formula is written as pure energy, `Σ dt · 10^((L − 80)/10) / 40 h`, because that is how
H.870 states it.

**No equipment-safety helper was written.** The brief named a `maxSafeVrmsNote` and then said
to skip it and keep to hearing, so there is nothing in this module about what voltage a
driver can survive. `expectedSPL(forSineDBFS:sensitivity:calibration:)` is the sanity line
the calibration sheet shows, and it is about hearing.

## Every number is an estimate

Joseon cannot see the amplifier gain. `PlaybackCalibration.uncertaintyDB` carries that
honestly — 2 dB for a measured tone, 4 dB from data sheets with a known attenuation, 8 dB
when the volume knob position is a guess, which is the normal case for an analog knob with no
scale. `SPLReading.uncertaintyDB` passes it through to the UI. Show the "≈", show the
calibration name, show the uncertainty. Never present an SPL or a dose as exact.

The sensitivity figures add their own uncertainty on top, and it is not in that number: each
is one unit measured on one rig by the manufacturer, and a real headphone varies with the
sample, the pads, and how it sits on a particular head.

## Regenerating

Re-fetch the URLs above, compare each spec line to the table in this file, and update the
fetch date here and in every `source` string in `HeadphoneSensitivityLibrary.swift`. If a
manufacturer has started publishing a referenced figure for one of the six unlisted
headphones, move it into `byCurveName` and out of `unlisted` — the test
`testEveryEmbeddedCurveIsEitherListedOrExplained` enforces that it is in exactly one.
