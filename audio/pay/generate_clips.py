#!/usr/bin/env python3
# generate_clips.py — bootstrap soundbox clips for ShopBill Pro v9
# Generates audio/pay/<lang>/<token>.mp3 for en + hi using Google TTS.
# Replace with your own recorded voice later if desired.
#
#   pip install gTTS
#   python3 generate_clips.py
#
import os
from gtts import gTTS  # type: ignore

OUT = os.path.dirname(os.path.abspath(__file__))

# token -> {lang: text}
WORDS = {
    "zero": {"en": "zero", "hi": "शून्य"},
    "one": {"en": "one", "hi": "एक"}, "two": {"en": "two", "hi": "दो"},
    "three": {"en": "three", "hi": "तीन"}, "four": {"en": "four", "hi": "चार"},
    "five": {"en": "five", "hi": "पाँच"}, "six": {"en": "six", "hi": "छह"},
    "seven": {"en": "seven", "hi": "सात"}, "eight": {"en": "eight", "hi": "आठ"},
    "nine": {"en": "nine", "hi": "नौ"}, "ten": {"en": "ten", "hi": "दस"},
    "eleven": {"en": "eleven", "hi": "ग्यारह"}, "twelve": {"en": "twelve", "hi": "बारह"},
    "thirteen": {"en": "thirteen", "hi": "तेरह"}, "fourteen": {"en": "fourteen", "hi": "चौदह"},
    "fifteen": {"en": "fifteen", "hi": "पंद्रह"}, "sixteen": {"en": "sixteen", "hi": "सोलह"},
    "seventeen": {"en": "seventeen", "hi": "सत्रह"}, "eighteen": {"en": "eighteen", "hi": "अठारह"},
    "nineteen": {"en": "nineteen", "hi": "उन्नीस"}, "twenty": {"en": "twenty", "hi": "बीस"},
    "thirty": {"en": "thirty", "hi": "तीस"}, "forty": {"en": "forty", "hi": "चालीस"},
    "fifty": {"en": "fifty", "hi": "पचास"}, "sixty": {"en": "sixty", "hi": "साठ"},
    "seventy": {"en": "seventy", "hi": "सत्तर"}, "eighty": {"en": "eighty", "hi": "अस्सी"},
    "ninety": {"en": "ninety", "hi": "नब्बे"}, "hundred": {"en": "hundred", "hi": "सौ"},
    "thousand": {"en": "thousand", "hi": "हज़ार"}, "lakh": {"en": "lakh", "hi": "लाख"},
    "crore": {"en": "crore", "hi": "करोड़"}, "rupees": {"en": "rupees", "hi": "रुपये"},
    "received": {"en": "received", "hi": "प्राप्त हुए"},
}

for lang in ("en", "hi"):
    d = os.path.join(OUT, lang)
    os.makedirs(d, exist_ok=True)
    for token, texts in WORDS.items():
        text = texts[lang]
        path = os.path.join(d, f"{token}.mp3")
        try:
            gTTS(text=text, lang=lang).save(path)
            print("ok ", path)
        except Exception as e:
            print("ERR", path, e)

print("Done. Verify a few clips, then deploy the audio/ folder with the app.")
