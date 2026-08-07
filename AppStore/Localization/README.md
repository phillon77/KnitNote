# KnitNote terminology glossary

`KnittingTerminology.csv` is the human-reviewed terminology source of truth for KnitNote 1.4.1 translators and String Catalog reviews. Each row expresses one semantic meaning across English, Traditional Chinese, Simplified Chinese, German, French, Japanese, Norwegian Bokmål, Swedish, Finnish, Danish, Korean, and modern Greek.

English defines a row's semantic intent. Simplified Chinese starts with a Traditional Chinese conversion only as a drafting aid, then is rewritten and reviewed for natural Mainland knitting usage; it must never be treated as character-for-character conversion.

The glossary is documentation and test input only. KnitNote continues to load runtime UI strings exclusively from its Apple String Catalogs. It does not translate, rewrite, or otherwise alter user-created or imported content.

When adding a row, use a stable semantic key, provide a non-empty value in every required language, and avoid duplicating a spelling for a different meaning. Keep the same term for the same meaning across all UI surfaces, then verify the related String Catalog keys during localization review.
