# Security and privacy

Joseon reads the audio that the Mac plays through a Core Audio process tap, made with
`muteBehavior = .unmuted`: the Mac keeps playing as before, and Joseon receives a copy. Audio stays
in memory on the Mac. Joseon does not record audio, has no account, and sends no analytics.

Network: Joseon makes one kind of request, the list of releases on GitHub
(`https://api.github.com/repos/jasas1/Joseon/releases`), once after the start, once a day, and
when you choose "Check for Updates…". Nothing is sent but that request. The setting "Check for
updates automatically" turns the automatic check off. An update is put in place only when its
SHA-256 matches the release and macOS confirms that its signature is valid, names the bundle
`app.joseon.Joseon`, and comes from the same signing team as the app that runs
(`Sources/JoseonApp/Updater.swift`).

Microphone: only the headphone measurement window opens an input, after you click start, and
macOS asks you first (`Sources/JoseonCapture/MeasurementInput.swift`).

On disk: the settings (user defaults) and the headphone curves you import or measure
(`~/Library/Application Support/Joseon/Curves`). Nothing else.

Entitlements: one, `com.apple.security.device.audio-input` (`scripts/Joseon.entitlements`).
Dependencies: none outside Apple's frameworks (`Package.swift`).

The project page, <https://jasas1.github.io/Joseon/>, has the full statement and the commands to
check each claim on your own Mac.

To report a vulnerability, use GitHub private vulnerability reporting on this repository
("Security" tab → "Report a vulnerability"). Do not open a public issue for a security problem.
