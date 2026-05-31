# Soundbox audio clips — manifest

`lib/pay-announce.js` builds the spoken amount by concatenating these clips.
Place files at: `audio/pay/<lang>/<token>.mp3`  (e.g. `audio/pay/en/five.mp3`).

Languages to ship: **en** and **hi** (folders `audio/pay/en/`, `audio/pay/hi/`).

## Required tokens (filenames, drop the `.mp3`)

**Ones / zero**
`zero one two three four five six seven eight nine`

**Teens**
`ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen`

**Tens**
`twenty thirty forty fifty sixty seventy eighty ninety`

**Scales**
`hundred thousand lakh crore`

**Words**
`rupees received`

That's **31 clips per language** (62 total for en + hi).

## Recording tips
- Keep each clip tight (trim leading/trailing silence) so concatenation sounds natural.
- Same speaker, same tone, ~ same volume across all clips.
- 22–44 kHz mono MP3 is fine; keep files small (PWA caches them).
- Hindi note: the Hindi token files keep the **same English filenames** (`five.mp3`)
  but contain the Hindi word audio (e.g. "पाँच"). The number logic is language-agnostic.

## Quick bootstrap
Run `generate_clips.py` (needs internet) to auto-generate a first pass with Google TTS,
then replace with your own voice later if you want. The announcer also degrades
gracefully: any missing clip is skipped, and a chime always plays.
