// Keep the version and download size in step with the latest GitHub release
// (the static values are filled in by deploy-site.sh as a fallback).
fetch('https://api.github.com/repos/Jotspot/VideoLibrary/releases/latest')
  .then(r => r.ok ? r.json() : Promise.reject())
  .then(release => {
    const version = release.tag_name.replace(/^v/, '');
    document.querySelectorAll('[data-version]').forEach(el => { el.textContent = version; });
    const zip = release.assets.find(a => a.name === 'VideoLibrary.zip');
    if (zip) document.querySelectorAll('[data-size]').forEach(el => { el.textContent = (zip.size / 1e6).toFixed(1) + ' MB'; });
  })
  .catch(() => {});
