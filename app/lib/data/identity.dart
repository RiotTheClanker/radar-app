/// The strings that identify this app to the outside world, in one place.
///
/// These used to be copy-pasted into every fetcher, which meant the version
/// was nowhere and the contact was nowhere. api.weather.gov and the OSM tile
/// servers both ask clients to say who they are and how to reach them, so a
/// client that misbehaves can be contacted instead of just blocked.
library;

/// Display name. Yaqui (Yoeme): taa'a, the sun -- near ta'a, to know -- and
/// yuku, the rain. Matches the Android label, the window titles, the desktop
/// entry and the installer, which used to differ in all four.
const appName = "Taa'a Yuku Radar";

/// Abbreviation, for places with no room for the full name -- the Android
/// launcher ellipsises anything much past ten characters. Mirrored in
/// android/app/src/main/res/values/strings.xml as app_name_short.
const appShortName = 'TY Radar';

/// [appName] where a space or an apostrophe would be a nuisance: config and
/// snapshot directories, and the User-Agent token.
const appSlug = 'taa-yuku-radar';

/// Kept in step with `version:` in pubspec.yaml by a test — see
/// test/identity_test.dart.
const appVersion = '0.1.3';

/// Where to find us. Used as the contact in [userAgent].
const appUrl = 'https://github.com/RiotTheClanker/radar-app';

/// Reverse-DNS id. Matches the Android applicationId and namespace, the
/// Linux APPLICATION_ID, and the StartupWMClass in the desktop entry -- the
/// last of those is how the shell pairs a window with its launcher icon, so
/// it has to move whenever this does.
const appId = 'io.github.riottheclanker.taayuku';

/// e.g. `taa-yuku-radar/0.1.3 (+https://github.com/RiotTheClanker/radar-app)`
const userAgent = '$appSlug/$appVersion (+$appUrl)';

/// Ready to splat into an `http` call's `headers:`.
const userAgentHeader = {'User-Agent': userAgent};
