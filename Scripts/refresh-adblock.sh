#!/bin/zsh
# Regenerate Resources/adblock-youtube.json from upstream EasyList + EasyPrivacy
# using Adblock Plus's official abp2blocklist converter (same tooling as ABP for iOS).
# The list is intentionally YouTube/ad-delivery scoped: our webview only ever
# loads YouTube, so full EasyList (~117k rules / 47MB) would be pure dead weight.
# Re-run every few months, then rebuild the app.
set -e
cd "$(dirname "$0")/.."
WORK="${TMPDIR:-/tmp}/notch-adblock"
mkdir -p "$WORK"
echo "== fetching filter lists"
curl -sL --max-time 90 -o "$WORK/easylist.txt" https://easylist.to/easylist/easylist.txt
curl -sL --max-time 90 -o "$WORK/easyprivacy.txt" https://easylist.to/easylist/easyprivacy.txt
echo "== extracting YouTube/ad-delivery network + cosmetic rules"
printf '[Adblock Plus 2.0]\n' > "$WORK/yt-ads.txt"
grep -ahiE 'doubleclick|googlesyndication|googleadservices|imasdk|moatads|/pagead|stats/ads|innovid|2mdn|googletagservices|vast|vpaid|freewheel|spotx' "$WORK/easylist.txt" "$WORK/easyprivacy.txt" | grep -av '^\S*:!' >> "$WORK/yt-ads.txt" || true
grep -ahiE 'youtube\.com/(pagead|get_video_info|ptracking|api/stats/ads)|youtube\.com##|youtube\.com#@#|googlesyndication\.com\^.*youtube|imasdk.*youtube|youtube.*imasdk' "$WORK/easylist.txt" >> "$WORK/yt-ads.txt" || true
grep -v '^\[Adblock' "$WORK/yt-ads.txt" | sort -u > "$WORK/yt-body.txt"
# NEVER emit a rule that blocks googlevideo.com media delivery: that pattern is
# why songs used to die at ~40-50s (the adblock ate audio segments). Ad-delivery
# and analytics hosts stay blocked; the playback CDN is whitelisted by design.
grep -av 'googlevideo' "$WORK/yt-body.txt" > "$WORK/yt-body2.txt" || true
mv "$WORK/yt-body2.txt" "$WORK/yt-body.txt"
printf '[Adblock Plus 2.0]\n' > "$WORK/yt-ads.txt"
cat "$WORK/yt-body.txt" >> "$WORK/yt-ads.txt"
echo "== converting ($(wc -l < "$WORK/yt-ads.txt") filters)"
if [ ! -f "$WORK/abp2blocklist/abp2blocklist.js" ]; then
  git clone --depth 1 https://github.com/adblockplus/abp2blocklist.git "$WORK/abp2blocklist"
fi
node "$WORK/abp2blocklist/abp2blocklist.js" < "$WORK/yt-ads.txt" > Resources/adblock-youtube.json
python3 -c "import json; d=json.load(open('Resources/adblock-youtube.json')); print('rules:', len(d))"
ls -la Resources/adblock-youtube.json
