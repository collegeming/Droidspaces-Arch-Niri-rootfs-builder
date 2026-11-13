# Fedora 45 patched KWin build inputs

`kwin-fedora45.patch` is upstream Anland's `producers/kde/Fedora43_v5/kwin.patch`
with one hunk removed:

- dropped: `src/scene/surfaceitem.cpp` (`addDamage` duplicate-repaint shortcut)

Reason: Fedora 45's KWin 6.8.2 SRPM contains the per-render-device damage change
(`m_damage` is `std::unordered_map<RenderDevice *, Region>`), while the hunk was
written for the older `Region` member and fails to compile:

```
error: no type named 'type' in 'struct std::__has_is_transparent<
    std::hash<KWin::RenderDevice *>, KWin::Rect, void>'
```

The hunk only avoids an extra repaint signal; without it KWin keeps the stock
behavior and the Anland backend still compiles. The remaining hunks (inputmethod
commitText, backends/CMakeLists, main_wayland `--anland`, transaction implicit
sync fast path) are required and unchanged from upstream.

The workflow passes this file through `KWIN_PATCH`, which `build.sh` honours in
`find_patch kwin.patch "${KWIN_PATCH:-}"`. Rebase it when Anland updates the
producer for KWin 6.9.

The workflow also runs `sed -i "s/rpm -K /rpm -K --nosignature /g" build.sh`
before building: `rpmbuild` does not sign the packages, so the producer's
`rpm -K` verification aborts with `digests SIGNATURES NOT OK`. Digest checks
still run, and the image installer uses `dnf --nogpgcheck` for these local RPMs.
