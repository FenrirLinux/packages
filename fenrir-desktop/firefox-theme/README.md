# Fenrir Browser theme

Firefox only installs signed add-ons, themes included, so this folder holds the
theme's source. `fenrir-desktop` ships a Firefox policy (`policies.json`) that
installs the signed theme from
`/usr/lib/firefox/distribution/extensions/fenrir-theme@fenrirlinux.org.xpi`;
until a signed file is packaged, Firefox keeps its default theme.

To publish the theme:

1. Edit `manifest.json` and bump `version`.
2. Sign it on addons.mozilla.org as an **unlisted** add-on
   (`web-ext sign --channel=unlisted` with your AMO API key, run in this folder).
3. Save the signed file here as `fenrir-theme-signed.xpi`.
4. In `../PKGBUILD`, add `'firefox-theme/fenrir-theme-signed.xpi'` to `source`
   (and a `'SKIP'` to `sha256sums`), add this line to `package()`, and bump
   `pkgrel`:

   ```bash
   install -Dm644 fenrir-theme-signed.xpi \
       "$pkgdir/usr/lib/firefox/distribution/extensions/fenrir-theme@fenrirlinux.org.xpi"
   ```
